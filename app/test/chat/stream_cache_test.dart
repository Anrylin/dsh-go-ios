import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/agent_selection_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/transcript_cache.dart';
import 'package:dsh_remote/dsh_remote.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

const _session = 'stream-cache';

final class _FakeCache extends TranscriptCache {
  _FakeCache() : super(directory: Directory.systemTemp);

  final windows = <String, CachedTranscript>{};
  final drafts = <String, CachedDraft>{};
  var windowWrites = 0;
  var draftWrites = 0;
  var draftRejected = 0;
  var draftClears = 0;

  @override
  Future<CachedTranscript?> load({required String hostId, required String sessionId, String? account}) async =>
      windows['$hostId|$sessionId'];

  @override
  Future<void> save(CachedTranscript window) async {
    windowWrites++;
    windows['${window.hostId}|${window.sessionId}'] = window;
  }

  @override
  Future<CachedDraft?> loadDraft({required String hostId, required String sessionId, String? account}) async =>
      drafts['$hostId|$sessionId'];

  @override
  Future<void> saveDraft(CachedDraft draft) async {
    draftWrites++;
    // Mirror the real codec: a draft that cannot round-trip is never stored.
    if (draft.toJson() == null) {
      draftRejected++;
      return;
    }
    drafts['${draft.hostId}|${draft.sessionId}'] = draft;
  }

  @override
  Future<void> clearDraft({
    required String hostId,
    required String sessionId,
    String? account,
  }) async {
    draftClears++;
    drafts.remove('$hostId|$sessionId');
  }
}

final class _Client extends DshClient {
  _Client() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;

  @override
  Future<void> close() async {
    await events.close();
    await super.close();
  }
}

SessionSnapshotEvent _snapshot(String text, {int cursor = 1}) => SessionSnapshotEvent.fromJson(_session, {
  'cursor': cursor,
  'records': [
    {
      'event': {
        'seq': 1,
        'time': 1792700000000,
        'type': 'user/message',
        'data': {
          'id': 'message',
          'role': 'user',
          'content': [
            {'type': 'text', 'text': text},
          ],
          'source': {'kind': 'user'},
        },
      },
    },
  ],
  'hasMore': false,
  'projections': {
    'asOfSeq': cursor,
    'values': <String, Object?>{},
  },
});

ProviderContainer _container(_Client client, _FakeCache cache) => ProviderContainer(
  overrides: [
    memoryPendingOutboxOverride(),
    transcriptCacheProvider.overrideWith((ref) async => cache),
    activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: true))),
  ],
);

Future<void> _pump(WidgetTester tester, [Duration duration = const Duration(milliseconds: 40)]) async {
  await tester.pump(duration);
  await tester.pump();
}

AssistantChatItem? _liveReply(ChatState state) {
  for (final item in state.items) {
    if (item is AssistantChatItem && item.streaming) return item;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('deltas write a bounded number of drafts and dispose keeps the last text', (tester) async {
    final client = _Client();
    final cache = _FakeCache();
    final container = _container(client, cache);
    addTearDown(container.dispose);
    addTearDown(client.events.close);
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester);

    client.events.add(_snapshot('question'));
    await _pump(tester);
    expect(cache.windowWrites, greaterThan(0));
    expect(cache.drafts, isEmpty, reason: 'a settled turn has no sidecar');

    client.events.add(const SessionStatusEvent(_session, true));
    client.events.add(AssistantStreamStarted('attempt', 0, turn: 1, step: 1, startedAfterSeq: 1));
    await _pump(tester);
    expect(cache.drafts, isNotEmpty, reason: 'a stream start is written at once');

    for (var i = 1; i <= 40; i++) {
      client.events.add(
        AssistantChunkEvent('attempt', 0, index: i, time: DateTime(2026), chunk: TextDeltaChunk(i, 'x')),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    await _pump(tester);
    expect(cache.draftWrites, lessThan(8), reason: '40 deltas must not write 40 files');
    expect(cache.drafts, isNotEmpty);
    final stored = cache.drafts.values.single;
    expect(stored.revision, greaterThan(0));

    // Let the throttle elapse: the tail of the stream still reaches the disk.
    await _pump(tester, const Duration(milliseconds: 800));
    expect(_liveReply(container.read(chatProvider(_session)))?.text.length, 40);

    // A controller released mid-turn still owes the last few tokens.
    final beforeDispose = cache.draftWrites;
    container.dispose();
    await _pump(tester);
    expect(cache.draftWrites, greaterThan(beforeDispose));
    final flushed = cache.drafts.values.single.items.whereType<AssistantChatItem>().single;
    expect(flushed.text, 'x' * 40, reason: 'the last chunk must reach the disk, not just a write count');
  });

  testWidgets('a fresh controller paints the in-flight reply from the sidecar', (tester) async {
    final client = _Client();
    final cache = _FakeCache();
    var container = _container(client, cache);
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester);

    client.events.add(_snapshot('question'));
    await _pump(tester);
    client.events.add(const SessionStatusEvent(_session, true));
    client.events.add(AssistantStreamStarted('attempt', 0, turn: 1, step: 1, startedAfterSeq: 1));
    await _pump(tester);
    for (var i = 0; i < 3; i++) {
      client.events.add(
        AssistantChunkEvent('attempt', 0, index: i, time: DateTime(2026), chunk: TextDeltaChunk(i, '速')),
      );
    }
    await _pump(tester, const Duration(milliseconds: 800));
    expect(cache.drafts, isNotEmpty);
    container.dispose();

    // Cold start: no client events at all, only the cache.
    final fresh = _Client();
    container = _container(fresh, cache);
    addTearDown(container.dispose);
    addTearDown(fresh.events.close);
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester, const Duration(milliseconds: 100));
    final seeded = _liveReply(container.read(chatProvider(_session)));
    expect(seeded, isNotNull);
    expect(seeded!.text, '速速速');
  });

  testWidgets('a restored draft is cleared by the authoritative snapshot and never ghosts on restart', (tester) async {
    final cache = _FakeCache()
      ..drafts['local:local|$_session'] = CachedDraft(
        account: '',
        hostId: 'local:local',
        sessionId: _session,
        cursor: 1,
        revision: 2,
        items: [
          AssistantChatItem(id: 'restored', text: '未说完', reasoning: '', streaming: true),
        ],
      );
    final client = _Client();
    var container = _container(client, cache);
    addTearDown(container.dispose);
    addTearDown(client.events.close);
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester, const Duration(milliseconds: 100));
    expect(_liveReply(container.read(chatProvider(_session)))?.text, '未说完');

    client.events.add(_snapshot('question', cursor: 2));
    client.events.add(const SessionStatusEvent(_session, false));
    await _pump(tester, const Duration(milliseconds: 100));
    expect(cache.drafts, isEmpty, reason: 'the Host snapshot must retire the restored sidecar');
    expect(cache.draftClears, greaterThan(0));
    container.dispose();

    final freshClient = _Client();
    container = _container(freshClient, cache);
    addTearDown(container.dispose);
    addTearDown(freshClient.events.close);
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester, const Duration(milliseconds: 100));
    expect(
      _liveReply(container.read(chatProvider(_session))),
      isNull,
      reason: 'a settled reply must not come back after a restart',
    );
  });

  testWidgets('a pre-snapshot revision bump never rewrites the restored sidecar', (tester) async {
    const key = 'local:local';
    final cache = _FakeCache()
      ..drafts['$key|$_session'] = CachedDraft(
        account: '',
        hostId: key,
        sessionId: _session,
        cursor: 1,
        revision: 2,
        items: [
          UserChatItem(
            seq: 1,
            time: DateTime.fromMillisecondsSinceEpoch(1),
            text: 'question',
            images: const [],
            files: const [],
          ),
          AssistantChatItem(id: 'restored', text: '未说完', reasoning: '', streaming: true),
        ],
      );
    final client = _Client();
    var container = _container(client, cache);
    addTearDown(container.dispose);
    addTearDown(client.events.close);
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester, const Duration(milliseconds: 100));
    expect(_liveReply(container.read(chatProvider(_session)))?.text, '未说完');

    // A stream marker invalidates the signature while the Host cursor is still
    // -1. The old code wrote `cursor: -1` beside `seq: 1`, which the draft codec
    // rejects wholesale on the next start.
    client.events.add(AssistantStreamStarted('attempt', 0, turn: 1, step: 1, startedAfterSeq: 1));
    await _pump(tester, const Duration(milliseconds: 100));
    expect(cache.draftWrites, 0, reason: 'no sidecar write before the first snapshot');
    expect(cache.draftRejected, 0);
    expect(
      (cache.drafts['$key|$_session']!.items.last as AssistantChatItem).text,
      '未说完',
      reason: 'the restored draft must stay byte-for-byte intact',
    );

    container.dispose();
    await _pump(tester);
    expect(cache.draftWrites, 0, reason: 'dispose must not write a cursor-less sidecar either');

    final freshClient = _Client();
    container = _container(freshClient, cache);
    addTearDown(container.dispose);
    addTearDown(freshClient.events.close);
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester, const Duration(milliseconds: 100));
    expect(_liveReply(container.read(chatProvider(_session)))?.text, '未说完', reason: 'recovery must not lose the draft');
  });

  testWidgets('the authoritative snapshot drops the sidecar', (tester) async {
    final client = _Client();
    final cache = _FakeCache();
    final container = _container(client, cache);
    addTearDown(container.dispose);
    addTearDown(client.events.close);
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester);

    client.events.add(_snapshot('question'));
    await _pump(tester);
    client.events.add(const SessionStatusEvent(_session, true));
    client.events.add(AssistantStreamStarted('attempt', 0, turn: 1, step: 1, startedAfterSeq: 1));
    await _pump(tester);
    expect(cache.drafts, isNotEmpty);

    client.events.add(_snapshot('question', cursor: 2));
    client.events.add(const SessionStatusEvent(_session, false));
    await _pump(tester, const Duration(milliseconds: 100));
    expect(cache.drafts, isEmpty, reason: 'the Host snapshot is now the source of truth');
    expect(cache.draftClears, greaterThan(0));
  });

  testWidgets('an Agent switch seeds the target draft, not the retired one', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ActiveHostController.prefsKey: HostRef.relay('h').encode(),
    });
    final cache = _FakeCache()
      ..drafts['relay:h:DSH|$_session'] = CachedDraft(
        account: '',
        hostId: 'relay:h:DSH',
        sessionId: _session,
        cursor: 1,
        revision: 2,
        items: [
          AssistantChatItem(id: 'old', text: 'DSH draft', reasoning: '', streaming: true),
        ],
      )
      ..drafts['relay:h:CodeX|$_session'] = CachedDraft(
        account: '',
        hostId: 'relay:h:CodeX',
        sessionId: _session,
        cursor: 1,
        revision: 2,
        items: [
          AssistantChatItem(id: 'new', text: 'CodeX draft', reasoning: '', streaming: true),
        ],
      );
    final client = _Client();
    final container = ProviderContainer(
      overrides: [
        memoryPendingOutboxOverride(),
        transcriptCacheProvider.overrideWith((ref) async => cache),
        activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(null)),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(client.events.close);
    container.read(activeHostProvider.notifier).select(HostRef.relay('h'));
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester, const Duration(milliseconds: 100));
    expect(_liveReply(container.read(chatProvider(_session)))?.text, 'DSH draft');

    await container.read(agentSelectionProvider.notifier).select('h', RemoteAgent.codex);
    await _pump(tester, const Duration(milliseconds: 100));
    expect(_liveReply(container.read(chatProvider(_session)))?.text, 'CodeX draft');
  });

  testWidgets('switching Agent retires the live sidecar of the old Agent', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ActiveHostController.prefsKey: HostRef.relay('h').encode(),
    });
    final client = _Client();
    final cache = _FakeCache();
    final container = ProviderContainer(
      overrides: [
        memoryPendingOutboxOverride(),
        transcriptCacheProvider.overrideWith((ref) async => cache),
        activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(client: client, isLocal: false))),
      ],
    );
    addTearDown(container.dispose);
    addTearDown(client.events.close);
    container.read(activeHostProvider.notifier).select(HostRef.relay('h'));
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester, const Duration(milliseconds: 100));

    client.events.add(_snapshot('question'));
    await _pump(tester);
    client.events.add(const SessionStatusEvent(_session, true));
    client.events.add(AssistantStreamStarted('attempt', 0, turn: 1, step: 1, startedAfterSeq: 1));
    await _pump(tester);
    expect(cache.drafts, isNotEmpty, reason: 'the old Agent has a live sidecar');
    final oldKey = cache.drafts.keys.single;

    await container.read(agentSelectionProvider.notifier).select('h', RemoteAgent.codex);
    await _pump(tester, const Duration(milliseconds: 100));
    expect(cache.drafts.containsKey(oldKey), isFalse, reason: 'the retired Agent draft must not survive the switch');
  });

  testWidgets('switching Agent retires a restored sidecar too', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ActiveHostController.prefsKey: HostRef.relay('h').encode(),
    });
    const oldKey = 'relay:h:DSH';
    final cache = _FakeCache()
      ..drafts['$oldKey|$_session'] = CachedDraft(
        account: '',
        hostId: oldKey,
        sessionId: _session,
        cursor: 1,
        revision: 2,
        items: [
          AssistantChatItem(id: 'restored', text: '旧 Agent 草稿', reasoning: '', streaming: true),
        ],
      );
    final container = ProviderContainer(
      overrides: [
        memoryPendingOutboxOverride(),
        transcriptCacheProvider.overrideWith((ref) async => cache),
        activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(null)),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeHostProvider.notifier).select(HostRef.relay('h'));
    container.listen(chatProvider(_session), (_, _) {});
    await _pump(tester, const Duration(milliseconds: 100));
    expect(_liveReply(container.read(chatProvider(_session)))?.text, '旧 Agent 草稿');

    await container.read(agentSelectionProvider.notifier).select('h', RemoteAgent.codex);
    await _pump(tester, const Duration(milliseconds: 100));
    expect(cache.drafts.containsKey('$oldKey|$_session'), isFalse);
  });
}
