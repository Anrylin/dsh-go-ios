import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/agent_selection_state.dart';
import 'package:dsh_app/state/android_features.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/pending_send_store.dart';
import 'package:dsh_app/state/sessions_state.dart' show currentSessionProvider;
import 'package:dsh_app/state/transcript_cache.dart';
import 'package:dsh_remote/dsh_remote.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../chat/support/harness.dart';

/// Mutable provider used to swap the published connection inside one test.
class _ConnectionController extends Notifier<AsyncValue<HostConnection?>> {
  _ConnectionController(this.initial);
  final AsyncValue<HostConnection?> initial;

  @override
  AsyncValue<HostConnection?> build() => initial;

  void set(AsyncValue<HostConnection?> next) => state = next;
}

final _connectionStateProvider = NotifierProvider<_ConnectionController, AsyncValue<HostConnection?>>(
  () => _ConnectionController(const AsyncData<HostConnection?>(null)),
);

final class _FakeCache extends TranscriptCache {
  _FakeCache() : super(directory: Directory.systemTemp);

  final windows = <String, CachedTranscript>{};

  @override
  Future<CachedTranscript?> load({required String hostId, required String sessionId, String? account}) async =>
      windows['$hostId|$sessionId'];

  @override
  Future<void> save(CachedTranscript window) async {
    windows['${window.hostId}|${window.sessionId}'] = window;
  }
}

class _FakeClient extends DshClient {
  _FakeClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();
  final prompts = <({String text, String? requestId})>[];

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;

  @override
  Future<String> prompt(
    String sessionId,
    String text, {
    List<PromptImage> images = const [],
    List<String> fileReceiptIds = const [],
    String? requestId,
    PromptMode mode = PromptMode.queue,
    String? timeZone,
  }) async {
    prompts.add((text: text, requestId: requestId));
    return requestId ?? 'r-$text';
  }
}

CachedTranscript _window(String agentCode, String text) => CachedTranscript(
  account: '',
  hostId: 'relay:h:$agentCode',
  sessionId: 's1',
  cursor: 1,
  title: '$agentCode title',
  items: [UserChatItem(seq: 1, time: DateTime(2026), text: text, images: const [], files: const [])],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ChatTranscript.clear resets every projection learned from an Agent', () {
    final transcript = ChatTranscript();
    transcript.seedItems([
      UserChatItem(seq: 1, time: DateTime(2026), text: 'old', images: const [], files: const []),
    ], title: 'old title');
    transcript.apply(const ConnectionStateEvent(DshConnectionState.connected));
    expect(transcript.items, isNotEmpty);
    expect(transcript.title, 'old title');
    expect(transcript.connectionState, DshConnectionState.connected);

    transcript.clear();

    expect(transcript.items, isEmpty);
    expect(transcript.title, isNull);
    expect(transcript.cursor, -1);
    expect(transcript.hasMoreHistory, isFalse);
    expect(transcript.connectionState, isNull);
    expect(transcript.pendingApprovals, isEmpty);
    expect(transcript.pendingQuestions, isEmpty);
    expect(transcript.turns, isEmpty);
    expect(transcript.todos, isNull);
    expect(transcript.goal, isNull);
  });

  test(
    'Agent switch shows the target cache, queues offline sends to its outbox and replays them on reconnect',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ActiveHostController.prefsKey: HostRef.relay('h').encode(),
      });
      final cache = _FakeCache()
        ..windows['relay:h:DSH|s1'] = _window('DSH', 'old DSH content')
        ..windows['relay:h:CodeX|s1'] = _window('CodeX', 'target CodeX content');
      final dshClient = _FakeClient();
      final codexClient = _FakeClient();
      final container = ProviderContainer(
        overrides: [
          memoryPendingOutboxOverride(),
          operatingSystemProvider.overrideWithValue('ios'),
          transcriptCacheProvider.overrideWith((ref) async => cache),
          activeConnectionProvider.overrideWith((ref) => ref.watch(_connectionStateProvider)),
        ],
      );
      addTearDown(() {
        container.dispose();
        dshClient.events.close();
        codexClient.events.close();
      });
      container.read(activeHostProvider.notifier).select(HostRef.relay('h'));
      container
          .read(_connectionStateProvider.notifier)
          .set(
            AsyncData<HostConnection?>(
              HostConnection(
                client: dshClient,
                kind: HostKind.relay,
                hostId: 'h',
                agent: RemoteAgent.dsh,
                isLocal: false,
              ),
            ),
          );
      container.listen(chatProvider('s1'), (_, _) {});
      await container.pump();
      await container.pump();

      ChatState state() => container.read(chatProvider('s1'));
      expect(state().items.whereType<UserChatItem>().single.text, 'old DSH content');

      // Same Host, different Agent: the old link is gone (null connection), the
      // controller is reused, and the target Agent's cached window must paint.
      await container.read(agentSelectionProvider.notifier).select('h', RemoteAgent.codex);
      container.read(_connectionStateProvider.notifier).set(const AsyncData<HostConnection?>(null));
      await container.pump();
      await container.pump();

      expect(state().items.whereType<UserChatItem>().single.text, 'target CodeX content');
      expect(state().syncing, isFalse);
      expect(state().streamLost, isFalse);

      // No client: the send is still accepted and stored under the new Agent.
      final ok = await container.read(chatProvider('s1').notifier).send('queued during switch');
      expect(ok, isTrue);
      expect(dshClient.prompts, isEmpty);
      expect(codexClient.prompts, isEmpty);
      final outbox = await container.read(pendingSendOutboxProvider.future);
      final key = PendingSendKey(account: localChatOwner, host: 'relay:h:CodeX', session: 's1');
      final entries = await outbox.store.load(key);
      expect(entries.single.text, 'queued during switch');
      final dshEntries = await outbox.store.load(
        PendingSendKey(account: localChatOwner, host: 'relay:h:DSH', session: 's1'),
      );
      expect(dshEntries, isEmpty);

      // The replacement link publishes a baseline and replays just that prompt.
      container
          .read(_connectionStateProvider.notifier)
          .set(
            AsyncData<HostConnection?>(
              HostConnection(
                client: codexClient,
                kind: HostKind.relay,
                hostId: 'h',
                agent: RemoteAgent.codex,
                isLocal: false,
              ),
            ),
          );
      await container.pump();
      await container.pump();
      codexClient.events.add(
        SessionSnapshotEvent.fromJson('s1', {
          'header': {'id': 's1'},
          'cursor': -1,
          'records': <Object?>[],
          'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
        }),
      );
      await container.pump();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await container.pump();

      expect(codexClient.prompts.map((p) => p.text), contains('queued during switch'));
      expect(codexClient.prompts.single.requestId, entries.single.requestId);
      expect(dshClient.prompts, isEmpty);
    },
  );

  test('forced offline send does not replay through a stale mux', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ActiveHostController.prefsKey: HostRef.relay('h').encode(),
    });
    final cache = _FakeCache();
    final client = _FakeClient();
    final container = ProviderContainer(
      overrides: [
        memoryPendingOutboxOverride(),
        operatingSystemProvider.overrideWithValue('ios'),
        transcriptCacheProvider.overrideWith((ref) async => cache),
        activeConnectionProvider.overrideWith((ref) => ref.watch(_connectionStateProvider)),
      ],
    );
    addTearDown(() {
      container.dispose();
      client.events.close();
    });
    container.read(activeHostProvider.notifier).select(HostRef.relay('h'));
    container.read(_connectionStateProvider.notifier).set(
      AsyncData<HostConnection?>(
        HostConnection(
          client: client,
          kind: HostKind.relay,
          hostId: 'h',
          agent: RemoteAgent.dsh,
          isLocal: false,
        ),
      ),
    );
    container.listen(chatProvider('s1'), (_, _) {});
    await container.pump();
    await container.pump();

    final ok = await container.read(chatProvider('s1').notifier).send('stale mux', queueOffline: true);
    expect(ok, isTrue);
    expect(client.prompts, isEmpty);

    final outbox = await container.read(pendingSendOutboxProvider.future);
    final entries = await outbox.store.load(
      PendingSendKey(account: localChatOwner, host: 'relay:h:DSH', session: 's1'),
    );
    expect(entries.single.text, 'stale mux');
  });

  test('offline send keeps its route check for the replay', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ActiveHostController.prefsKey: HostRef.relay('h').encode(),
    });
    final cache = _FakeCache();
    final client = _FakeClient();
    final container = ProviderContainer(
      overrides: [
        memoryPendingOutboxOverride(),
        operatingSystemProvider.overrideWithValue('ios'),
        transcriptCacheProvider.overrideWith((ref) async => cache),
        activeConnectionProvider.overrideWith((ref) => ref.watch(_connectionStateProvider)),
      ],
    );
    addTearDown(() {
      container.dispose();
      client.events.close();
    });
    container.read(activeHostProvider.notifier).select(HostRef.relay('h'));
    container.read(_connectionStateProvider.notifier).set(const AsyncData<HostConnection?>(null));
    container.listen(chatProvider('s1'), (_, _) {});
    await container.pump();
    await container.pump();

    var routeReady = true;
    final ok = await container
        .read(chatProvider('s1').notifier)
        .send('route may change', deliveryAllowed: () => routeReady);
    expect(ok, isTrue);
    routeReady = false;

    container
        .read(_connectionStateProvider.notifier)
        .set(
          AsyncData<HostConnection?>(
            HostConnection(client: client, kind: HostKind.relay, hostId: 'h', agent: RemoteAgent.dsh, isLocal: false),
          ),
        );
    await container.pump();
    await container.pump();
    client.events.add(
      SessionSnapshotEvent.fromJson('s1', {
        'header': {'id': 's1'},
        'cursor': -1,
        'records': <Object?>[],
        'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
      }),
    );
    await container.pump();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await container.pump();

    final settled = container.read(chatProvider('s1'));
    expect(client.prompts, isEmpty);
    // A refused route is a definite send failure: the draft stays visible as
    // an editable retry bubble and the person sees why it did not go out.
    expect(settled.error, isNotNull);
    expect(settled.pending, hasLength(1));
    expect(settled.pending.single.failed, isTrue);
    expect(settled.pending.single.text, 'route may change');
    final outbox = await container.read(pendingSendOutboxProvider.future);
    final entries = await outbox.store.load(
      PendingSendKey(account: localChatOwner, host: 'relay:h:DSH', session: 's1'),
    );
    expect(entries, isEmpty);
  });

  test('a second listen before sync does not lose a queued replay', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ActiveHostController.prefsKey: HostRef.relay('h').encode(),
    });
    final client = _FakeClient();
    final container = ProviderContainer(
      overrides: [
        memoryPendingOutboxOverride(),
        operatingSystemProvider.overrideWithValue('ios'),
        transcriptCacheProvider.overrideWith((ref) async => _FakeCache()),
        activeConnectionProvider.overrideWith((ref) => ref.watch(_connectionStateProvider)),
      ],
    );
    addTearDown(() {
      container.dispose();
      client.events.close();
    });
    container.read(activeHostProvider.notifier).select(HostRef.relay('h'));
    container.read(_connectionStateProvider.notifier).set(const AsyncData<HostConnection?>(null));
    container.listen(chatProvider('s1'), (_, _) {});
    await container.pump();
    await container.pump();

    expect(await container.read(chatProvider('s1').notifier).send('survives two listens'), isTrue);
    container
        .read(_connectionStateProvider.notifier)
        .set(
          AsyncData<HostConnection?>(
            HostConnection(client: client, kind: HostKind.relay, hostId: 'h', agent: RemoteAgent.dsh, isLocal: false),
          ),
        );
    await container.pump();
    await container.pump();
    // A fresh link retires the listener whose replay is still waiting for sync.
    container.read(_connectionStateProvider.notifier).set(const AsyncData<HostConnection?>(null));
    await container.pump();
    container
        .read(_connectionStateProvider.notifier)
        .set(
          AsyncData<HostConnection?>(
            HostConnection(client: client, kind: HostKind.relay, hostId: 'h', agent: RemoteAgent.dsh, isLocal: false),
          ),
        );
    await container.pump();
    await container.pump();
    client.events.add(
      SessionSnapshotEvent.fromJson('s1', {
        'header': {'id': 's1'},
        'cursor': -1,
        'records': <Object?>[],
        'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
      }),
    );
    await container.pump();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await container.pump();

    expect(client.prompts.map((p) => p.text), ['survives two listens']);
  });

  test('session/not-found is visible only for a painted conversation', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      ActiveHostController.prefsKey: HostRef.relay('h').encode(),
    });
    final cache = _FakeCache()..windows['relay:h:DSH|s1'] = _window('DSH', 'painted content');
    final client = _FakeClient();
    final container = ProviderContainer(
      overrides: [
        memoryPendingOutboxOverride(),
        operatingSystemProvider.overrideWithValue('ios'),
        transcriptCacheProvider.overrideWith((ref) async => cache),
        activeConnectionProvider.overrideWith((ref) => ref.watch(_connectionStateProvider)),
      ],
    );
    addTearDown(() {
      container.dispose();
      client.events.close();
    });
    container.read(activeHostProvider.notifier).select(HostRef.relay('h'));
    container.read(currentSessionProvider.notifier).select('s1');
    container
        .read(_connectionStateProvider.notifier)
        .set(
          AsyncData<HostConnection?>(
            HostConnection(client: client, kind: HostKind.relay, hostId: 'h', agent: RemoteAgent.dsh, isLocal: false),
          ),
        );
    container.listen(chatProvider('s1'), (_, _) {});
    await container.pump();
    await container.pump();

    client.events.addError(const DshRemoteException('session/not-found', 'gone'));
    await container.pump();
    await container.pump();

    final painted = container.read(chatProvider('s1'));
    // The cached window is already on screen: a silent jump to a new chat would
    // replace visible content with a blank composer.
    expect(painted.error, isNotNull);
    expect(painted.syncing, isFalse);
    expect(painted.streamLost, isFalse);
    expect(container.read(currentSessionProvider), 's1');
  });
}
