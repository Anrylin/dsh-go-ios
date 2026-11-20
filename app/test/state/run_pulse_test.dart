// The stats line must keep the last output's speed on screen after the model
// goes quiet; only the live consumer (whale tail) sees tokensPerSecond drop.
// A tick is only allowed for the active attempt after it really streamed.

import 'package:dsh_client/dsh_client.dart'
    show
        AssistantChunkEvent,
        AssistantStreamEnded,
        AssistantStreamStarted,
        SessionSnapshotEvent,
        TextDeltaChunk,
        TokenUsage,
        TraceKind,
        TraceSpan,
        TurnTrace;
import 'package:dsh_app/state/run_pulse.dart'
    show RunPulse, conversationTokensPerSecond;
import 'package:flutter_test/flutter_test.dart';

void main() {
  RunPulse newPulse(DateTime Function() clock) {
    final pulse = RunPulse(clock: clock);
    // Tests drive tickNow() themselves; no background timer in a plain test.
    pulse.setSamplingEnabled(false);
    addTearDown(pulse.dispose);
    return pulse;
  }

  void stream(RunPulse pulse, String attempt, DateTime at,
      {int count = 10, int revision = 0}) {
    for (var i = 0; i < count; i++) {
      pulse.observe(AssistantChunkEvent(
        attempt,
        revision,
        index: i,
        time: at,
        chunk: TextDeltaChunk(0, '字' * 10),
      ));
    }
  }

  test('stopping keeps displayTps but not tokensPerSecond; ✓ only after the end', () {
    var now = DateTime(2026, 1, 1, 12);
    final pulse = newPulse(() => now);

    stream(pulse, 'a', now);
    expect(pulse.tokensPerSecond, greaterThan(0));
    expect(pulse.displayTps, pulse.tokensPerSecond);
    expect(pulse.rateSettled, isFalse);

    pulse.observe(const AssistantStreamEnded('a', 0, index: 10, committed: true));
    expect(pulse.rateSettled, isTrue);
    expect(pulse.displayTps, greaterThan(0));

    now = now.add(const Duration(seconds: 2));
    pulse.tickNow();
    expect(pulse.tokensPerSecond, 0);
    expect(pulse.displayTps, greaterThan(0));
    expect(pulse.rateSettled, isTrue);

    // A new attempt starts: the shown speed is live again, so hide the tick.
    stream(pulse, 'b', now);
    expect(pulse.rateSettled, isFalse);
    expect(pulse.displayTps, greaterThan(0));
  });

  test('no stream-end still settles when the meter stalls', () {
    var now = DateTime(2026, 1, 1, 12);
    final pulse = newPulse(() => now);
    stream(pulse, 'a', now);
    expect(pulse.rateSettled, isFalse);

    now = now.add(const Duration(seconds: 2));
    pulse.tickNow();
    expect(pulse.tokensPerSecond, 0);
    expect(pulse.displayTps, greaterThan(0));
    expect(pulse.rateSettled, isTrue);
  });

  test('stale, duplicate and uncommitted ends cannot tick a new attempt', () {
    final now = DateTime(2026, 1, 1, 12);
    final pulse = newPulse(() => now);

    stream(pulse, 'a', now, revision: 1);
    pulse.observe(const AssistantStreamEnded('a', 1, index: 10, committed: true));
    expect(pulse.rateSettled, isTrue);

    pulse.observe(const AssistantStreamStarted('b', 2,
        turn: 2, step: 1, startedAfterSeq: 10));
    expect(pulse.rateSettled, isFalse);

    // Old attempt, stale revision, abandoned draft: none may tick attempt b.
    pulse.observe(const AssistantStreamEnded('a', 1, index: 10, committed: true));
    pulse.observe(const AssistantStreamEnded('b', 1, index: 0, committed: true));
    pulse.observe(const AssistantStreamEnded('b', 2, index: 0, committed: false));
    expect(pulse.rateSettled, isFalse);

    // b has produced no tokens yet: a committed-looking end is still not "its".
    pulse.observe(const AssistantStreamEnded('b', 2, index: 0, committed: true));
    expect(pulse.rateSettled, isFalse);

    stream(pulse, 'b', now, count: 2, revision: 2);
    pulse.observe(const AssistantStreamEnded('b', 2, index: 2, committed: true));
    expect(pulse.rateSettled, isTrue);
    // Duplicate end must not change the settled state.
    pulse.observe(const AssistantStreamEnded('b', 2, index: 2, committed: true));
    expect(pulse.rateSettled, isTrue);
  });

  test('turn start hides the tick until that turn actually streams', () {
    var now = DateTime(2026, 1, 1, 12);
    final pulse = newPulse(() => now);

    stream(pulse, 'a', now);
    pulse.observe(const AssistantStreamEnded('a', 0, index: 10, committed: true));
    expect(pulse.rateSettled, isTrue);

    pulse.observe(const AssistantStreamStarted('b', 1,
        turn: 2, step: 1, startedAfterSeq: 10));
    expect(pulse.rateSettled, isFalse);

    // Idle tick must not re-arm last turn's rate while b waits for first token.
    now = now.add(const Duration(seconds: 2));
    pulse.tickNow();
    expect(pulse.tokensPerSecond, 0);
    expect(pulse.displayTps, greaterThan(0));
    expect(pulse.rateSettled, isFalse);

    // First chunk of b re-arms; only then may its end show the tick.
    stream(pulse, 'b', now, count: 1, revision: 1);
    expect(pulse.rateSettled, isFalse);
    pulse.observe(const AssistantStreamEnded('b', 1, index: 1, committed: true));
    expect(pulse.rateSettled, isTrue);
  });

  test('snapshot and resync clear the tick', () {
    final now = DateTime(2026, 1, 1, 12);
    final pulse = newPulse(() => now);

    stream(pulse, 'a', now);
    pulse.observe(const AssistantStreamEnded('a', 0, index: 10, committed: true));
    expect(pulse.rateSettled, isTrue);

    pulse.observe(SessionSnapshotEvent.fromJson('s', {
      'cursor': 0,
      'records': <Object?>[],
    }));
    expect(pulse.rateSettled, isFalse);

    stream(pulse, 'b', now);
    pulse.observe(const AssistantStreamEnded('b', 0, index: 10, committed: true));
    expect(pulse.rateSettled, isTrue);

    pulse.observe(SessionSnapshotEvent.fromJson(
      's',
      {'cursor': 1, 'records': <Object?>[]},
      isResync: true,
    ));
    expect(pulse.rateSettled, isFalse);
  });

  test('conversation rate sums tokens and decoding time over closed model spans', () {
    final t = DateTime(2026, 1, 1, 12);
    final turns = [
      TurnTrace(
        turn: 1,
        startSeq: 0,
        start: t,
        spans: [
          TraceSpan(
            kind: TraceKind.model,
            step: 1,
            seq: 1,
            start: t,
            firstToken: t.add(const Duration(seconds: 1)),
            end: t.add(const Duration(seconds: 3)),
            usage: const TokenUsage(inputTokens: 100, outputTokens: 100),
          ),
          TraceSpan(
            kind: TraceKind.tool,
            step: 1,
            seq: 2,
            start: t.add(const Duration(seconds: 3)),
            end: t.add(const Duration(seconds: 8)),
            usage: const TokenUsage(inputTokens: 0, outputTokens: 999),
          ),
          TraceSpan(
            kind: TraceKind.model,
            step: 2,
            seq: 3,
            start: t.add(const Duration(seconds: 8)),
            firstToken: t.add(const Duration(seconds: 9)),
            end: t.add(const Duration(seconds: 10)),
            usage: const TokenUsage(inputTokens: 0, outputTokens: 300),
          ),
          // Still decoding: no honest denominator yet.
          TraceSpan(
            kind: TraceKind.model,
            step: 3,
            seq: 4,
            start: t.add(const Duration(seconds: 10)),
            firstToken: t.add(const Duration(seconds: 11)),
            usage: const TokenUsage(inputTokens: 0, outputTokens: 500),
          ),
        ],
      ),
    ];

    // 100 tok / 2s + 300 tok / 1s -> 400 tok / 3s.
    expect(conversationTokensPerSecond(turns), closeTo(400 / 3, 0.001));
    expect(conversationTokensPerSecond(const []), isNull);
  });

  test('short and zero decoding spans are skipped; turns aggregate', () {
    final t = DateTime(2026, 1, 1, 12);
    TraceSpan model(int step, int output, Duration decoding) => TraceSpan(
          kind: TraceKind.model,
          step: step,
          seq: step,
          start: t,
          firstToken: t.add(const Duration(seconds: 1)),
          end: t.add(const Duration(seconds: 1)).add(decoding),
          usage: TokenUsage(inputTokens: 0, outputTokens: output),
        );

    final onlyShort = [
      TurnTrace(
        turn: 1,
        startSeq: 0,
        start: t,
        spans: [
          model(1, 900, const Duration(milliseconds: 199)),
          model(2, 500, Duration.zero),
        ],
      ),
    ];
    expect(conversationTokensPerSecond(onlyShort), isNull);

    final turns = [
      TurnTrace(
        turn: 1,
        startSeq: 0,
        start: t,
        spans: [
          model(1, 100, const Duration(seconds: 2)),
          model(2, 900, const Duration(milliseconds: 199)),
        ],
      ),
      TurnTrace(
        turn: 2,
        startSeq: 10,
        start: t.add(const Duration(hours: 1)),
        spans: [
          model(1, 300, const Duration(seconds: 1)),
        ],
      ),
    ];
    // 199ms and zero-decoding spans are out; 100 tok/2s + 300 tok/1s.
    expect(conversationTokensPerSecond(turns), closeTo(400 / 3, 0.001));
  });
}
