import 'dart:async';

import 'package:dsh_app/state/agent_selection_state.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/pending_send_store.dart';
import 'package:dsh_remote/dsh_remote.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

/// Text-only client whose prompt can refuse with a scripted error. No widget
/// tree is needed: the fake watch stream is fed by the test itself.
class _BusyFakeClient extends DshClient {
  _BusyFakeClient() : super(DshConnection(Uri.parse('http://127.0.0.1:9')));

  final events = StreamController<DshEvent>.broadcast();
  final prompts = <({String text, String? requestId, PromptMode mode})>[];
  Object? promptError;
  Object? cancelError;

  @override
  Stream<DshEvent> watch(String sessionId, {WatchOptions options = const WatchOptions()}) => events.stream;

  @override
  Future<void> cancel(String sessionId) async {
    if (cancelError case final error?) throw error;
  }

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
    prompts.add((text: text, requestId: requestId, mode: mode));
    if (promptError case final error?) throw error;
    return requestId ?? 'r';
  }
}

/// Mutable agent selection: switching it must retire a waiting Codex retry.
class _AgentController extends Notifier<RemoteAgent> {
  @override
  RemoteAgent build() => RemoteAgent.dsh;

  void select(RemoteAgent agent) => state = agent;
}

final _agentProvider = NotifierProvider<_AgentController, RemoteAgent>(_AgentController.new);

void main() {
  const busy = DshRemoteException('CODEX_THREAD_BUSY', 'another client owns this thread');

  late _BusyFakeClient client;
  late ProviderContainer container;

  ChatController chat() => container.read(chatProvider('s1').notifier);
  ChatState state() => container.read(chatProvider('s1'));

  Future<List<PendingSend>> durable() async {
    final outbox = await container.read(pendingSendOutboxProvider.future);
    return (outbox.store as MemoryPendingSendStore).all;
  }

  Future<void> baseline() async {
    SharedPreferences.setMockInitialValues({});
    client = _BusyFakeClient();
    container = ProviderContainer(
      overrides: [
        memoryPendingOutboxOverride(),
        activeAgentProvider.overrideWith((ref) => ref.watch(_agentProvider)),
        activeConnectionProvider.overrideWithValue(
          AsyncData<HostConnection?>(HostConnection(client: client, label: '本机', isLocal: true)),
        ),
      ],
    );
    container.listen(chatProvider('s1'), (_, _) {});
    client.events.add(
      SessionSnapshotEvent.fromJson('s1', {
        'header': {'id': 's1'},
        'cursor': -1,
        'records': <Object?>[],
        'projections': {'asOfSeq': -1, 'values': <String, Object?>{}},
      }),
    );
    await container.pump();
    expect(state().controlReady, isTrue);
  }

  /// Let the provider scheduler and the 32ms publish timer settle so a fake
  /// async test does not end with a pending timer.
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  tearDown(() async {
    container.dispose();
    await client.events.close();
  });

  testWidgets('busy keeps the waiting bubble and durable entry, then retries the same request', (tester) async {
    await baseline();
    client.promptError = busy;

    expect(await chat().send('你好'), isTrue);
    await tester.pump();
    expect(client.prompts, hasLength(1));
    expect(state().pending, hasLength(1));
    expect(state().pending.single.failed, isFalse);
    expect(state().error, isNull);
    expect(state().notice, contains('稍后自动重试'));
    expect((await durable()).single.text, '你好');

    // First backoff step: 2s. The bubble is still waiting, not "failed".
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(client.prompts, hasLength(2));
    expect(client.prompts.last.requestId, client.prompts.first.requestId);
    expect(state().pending, hasLength(1));

    // Once the other client is done the same request is accepted.
    client.promptError = null;
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(client.prompts, hasLength(3));
    expect(client.prompts.last.requestId, client.prompts.first.requestId);
    expect(state().pending.single.failed, isFalse);

    // Acceptance cancels the bounded retry loop.
    await tester.pump(const Duration(seconds: 60));
    expect(client.prompts, hasLength(3));
    await flush(tester);
  });

  testWidgets('a turn end retries at once instead of waiting out the backoff', (tester) async {
    await baseline();
    client.promptError = busy;
    expect(await chat().send('你好'), isTrue);

    client.promptError = null;
    client.events.add(const SessionStatusEvent('s1', false));
    client.events.add(
      TurnEndedEvent(
        0,
        DateTime.now(),
        const <String, Object?>{},
        turn: 1,
        reason: TurnEndReason.fromJson(const <String, Object?>{'kind': 'completed'}),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 96));
    await tester.pump();
    expect(client.prompts, hasLength(2));
    await flush(tester);
  });

  testWidgets('exhausted backoff offers a manual retry without dropping the outbox', (tester) async {
    await baseline();
    client.promptError = busy;
    expect(await chat().send('你好'), isTrue);

    for (final seconds in [2, 4, 8, 15, 30]) {
      await tester.pump(Duration(seconds: seconds));
      await tester.pump();
    }
    // One original plus five bounded retries (2/4/8/15/30s); the fifth refusal
    // gives up and switches to a manual retry.
    expect(client.prompts, hasLength(6));
    expect(state().pending.single.failed, isTrue);
    expect(state().notice, contains('手动重试'));
    expect((await durable()).single.text, '你好');

    // No further automatic attempts after exhaustion.
    await tester.pump(const Duration(seconds: 60));
    expect(client.prompts, hasLength(6));
    await flush(tester);
  });

  for (final (label, error, settleDropsOutbox) in <(String, Object, bool)>[
    ('transport loss', const DshTransportException('lost'), false),
    ('carrier loss', const DshCarrierLostException('gone'), false),
    ('upstream timeout', const DshRemoteException('CODEX_REQUEST_TIMEOUT', 'timed out'), true),
  ]) {
    testWidgets('$label is never auto-replayed', (tester) async {
      await baseline();
      client.promptError = error;

      expect(await chat().send('你好'), isFalse);
      await tester.pump();
      expect(state().pending, isEmpty);
      await tester.pump(const Duration(seconds: 60));
      expect(client.prompts, hasLength(1));
      if (settleDropsOutbox) {
        // A definite upstream refusal settles and drops the durable entry.
        expect(await durable(), isEmpty);
      } else {
        // Unknown outcome keeps the entry for an explicit later retry.
        expect(await durable(), hasLength(1));
      }
      await flush(tester);
    });
  }

  testWidgets('manual retry after exhaustion keeps the same request id', (tester) async {
    await baseline();
    client.promptError = busy;
    expect(await chat().send('你好'), isTrue);
    for (final seconds in [2, 4, 8, 15, 30]) {
      await tester.pump(Duration(seconds: seconds));
      await tester.pump();
    }
    final failed = state().pending.single;
    expect(failed.failed, isTrue);
    final originalId = client.prompts.first.requestId;

    client.promptError = null;
    expect(await chat().retryFailed(failed, '你好'), isTrue);
    await tester.pump();
    expect(client.prompts, hasLength(7));
    expect(client.prompts.last.requestId, originalId);

    await tester.pump(const Duration(seconds: 60));
    expect(client.prompts, hasLength(7));
    await flush(tester);
  });

  testWidgets('a cancel refused by the other Codex client names the owner', (tester) async {
    await baseline();
    client.events.add(const SessionStatusEvent('s1', true));
    await tester.pump(const Duration(milliseconds: 100));
    expect(state().running, isTrue);
    client.cancelError = busy;

    expect(await chat().cancel(), isEmpty);
    await tester.pump();
    expect(state().error, contains('另一端发起'));
    expect(state().error, isNot(contains('停止失败')));
    await flush(tester);
  });

  testWidgets('switching Agent cancels a waiting Codex retry', (tester) async {
    await baseline();
    client.promptError = busy;
    expect(await chat().send('你好'), isTrue);
    await tester.pump();

    container.read(_agentProvider.notifier).select(RemoteAgent.codex);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(client.prompts, hasLength(1));
    expect(state().pending, isEmpty);
    await flush(tester);
  });

  testWidgets('busy retry still respects the original delivery route guard', (tester) async {
    await baseline();
    var routeAllowed = true;
    client.promptError = busy;
    expect(await chat().send('你好', deliveryAllowed: () => routeAllowed), isTrue);

    routeAllowed = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    // The guard refuses before a second prompt leaves the device.
    expect(client.prompts, hasLength(1));
    expect(state().pending, isEmpty);
    expect(await durable(), isEmpty);
    await tester.pump(const Duration(seconds: 60));
    await flush(tester);
  });

  testWidgets('ordinary send refusals remain terminal', (tester) async {
    await baseline();
    client.promptError = const DshRemoteException('session/agent-busy', 'busy');

    expect(await chat().send('你好'), isFalse);
    await tester.pump();
    expect(client.prompts, hasLength(1));
    expect(state().error, contains('AI 正忙'));
    expect(state().pending, isEmpty);
    expect(await durable(), isEmpty);
    await flush(tester);
  });
}
