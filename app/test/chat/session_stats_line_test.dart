// The stats line keeps the last speed on screen after output stops, adds a
// tick once it is settled, and shows the finished-output average from the
// durable transcript. Text is localized through the ARB parts.

import 'package:dsh_app/l10n/l10n.dart' show AppLocale;
import 'package:dsh_app/state/chat_state.dart' show ChatState, chatProvider;
import 'package:dsh_app/state/run_pulse.dart' show RunPulse, runPulseProvider;
import 'package:dsh_app/state/token_usage.dart'
    show TokenUsage, TokenUsageController, tokenUsageProvider;
import 'package:dsh_app/ui/chat/widgets/session_stats_line.dart';
import 'package:dsh_client/dsh_client.dart' as dsh;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart' show FakeChatController, testTheme;

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  List<dsh.TurnTrace> turnsWithAverage() => [
        dsh.TurnTrace(
          turn: 1,
          startSeq: 0,
          start: t0,
          spans: [
            dsh.TraceSpan(
              kind: dsh.TraceKind.model,
              step: 1,
              seq: 1,
              start: t0,
              firstToken: t0.add(const Duration(seconds: 1)),
              end: t0.add(const Duration(seconds: 5)),
              usage: const dsh.TokenUsage(
                inputTokens: 100,
                outputTokens: 200,
                cacheReadTokens: 600,
              ),
            ),
          ],
        ),
      ];

  Widget app(List<dsh.TurnTrace> turns) => ProviderScope(
        overrides: [
          chatProvider.overrideWith2(
              (id) => FakeChatController(id, ChatState(loading: false, turns: turns))),
          tokenUsageProvider.overrideWith(NoUsageStore.new),
        ],
        child: MaterialApp(
          theme: testTheme(Brightness.light),
          home: const SizedBox(width: 800, child: SessionStatsLine(sessionId: 's')),
        ),
      );

  RunPulse pulseOf(WidgetTester tester) {
    final pulse = ProviderScope.containerOf(tester.element(find.byType(SessionStatsLine)))
        .read(runPulseProvider('s'));
    pulse.setSamplingEnabled(false);
    return pulse;
  }

  void feed(RunPulse pulse, DateTime now) {
    pulse.observe(dsh.AssistantChunkEvent(
      'a', 0,
      index: 0,
      time: now,
      chunk: dsh.TextDeltaChunk(0, '字' * 10),
    ));
    pulse.observe(dsh.AssistantChunkEvent(
      'a', 1,
      index: 1,
      time: now,
      chunk: const dsh.UsageChunk(
          dsh.TokenUsage(inputTokens: 1200, outputTokens: 340, cacheReadTokens: 600)),
    ));
  }

  setUp(() => AppLocale.use(AppLocale.zhCN));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  testWidgets('zh: cache · finished-output avg · retained rate, then the tick', (tester) async {
    await tester.pumpWidget(app(turnsWithAverage()));
    expect(find.textContaining('↑100 · ↓200 · 缓存 600 · Avg 50 tok/s'), findsOneWidget);
    expect(find.textContaining(AppLocale.l10n.statsRateSettled), findsNothing);

    final pulse = pulseOf(tester);
    feed(pulse, DateTime.now());
    await tester.pump();
    // Full order: input, output, cache, average, current/last rate.
    expect(
      find.textContaining('↑1.2k · ↓340 · 缓存 600 · Avg 50 tok/s · 12 tok/s'),
      findsOneWidget,
    );
    expect(find.textContaining(AppLocale.l10n.statsRateSettled), findsNothing);

    pulse.observe(const dsh.AssistantStreamEnded('a', 1, index: 2, committed: true));
    await tester.pump();
    // The tick is a TextSpan with a semantics label, so toPlainText() shows
    // the label instead of the glyph: assert the label and the settled state.
    expect(pulse.rateSettled, isTrue);
    expect(pulse.displayTps, greaterThan(0));
    expect(find.textContaining(AppLocale.l10n.statsRateSettled), findsOneWidget);
    expect(
      find.textContaining('↑1.2k · ↓340 · 缓存 600 · Avg 50 tok/s · 12 tok/s'),
      findsOneWidget,
    );
  });

  testWidgets('en: cache · finished-output avg · retained rate, then the tick', (tester) async {
    AppLocale.use(AppLocale.en);
    await tester.pumpWidget(app(turnsWithAverage()));
    expect(find.textContaining('↑100 · ↓200 · cache 600 · Avg 50 tok/s'), findsOneWidget);

    final pulse = pulseOf(tester);
    feed(pulse, DateTime.now());
    await tester.pump();
    expect(
      find.textContaining('↑1.2k · ↓340 · cache 600 · Avg 50 tok/s · 12 tok/s'),
      findsOneWidget,
    );
    expect(find.textContaining(AppLocale.l10n.statsRateSettled), findsNothing);

    pulse.observe(const dsh.AssistantStreamEnded('a', 1, index: 2, committed: true));
    await tester.pump();
    expect(pulse.rateSettled, isTrue);
    expect(find.textContaining(AppLocale.l10n.statsRateSettled), findsOneWidget);
  });

  testWidgets('hidden when there is nothing at all', (tester) async {
    await tester.pumpWidget(app(const []));
    expect(find.textContaining('tok/s'), findsNothing);
  });
}

/// Usage recording would otherwise hit SharedPreferences (no plugin in tests).
class NoUsageStore extends TokenUsageController {
  @override
  TokenUsage build() => TokenUsage.empty;

  @override
  Future<void> record(String sessionId, int input, int output) async {}
}
