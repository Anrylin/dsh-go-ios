// A picked image must leave the caret in the composer; a cancelled picker
// must not raise the keyboard.
// Also covers the Agent-switch silent window: only the active Host is muted,
// real failures stay visible, and notice/error banners survive.

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/agent_selection_state.dart' show activeAgentProvider, agentSelectionProvider;
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/remote/host_status.dart';
import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

/// A test-only override: the Agent switch hint stays on.
class _AlwaysSilent extends AgentSwitchReconnectController {
  @override
  bool build() => true;
}

class _MutableConnection extends Notifier<AsyncValue<HostConnection?>> {
  @override
  AsyncValue<HostConnection?> build() => const AsyncData(null);

  void set(AsyncValue<HostConnection?> next) => state = next;
}

final _connectionStateProvider = NotifierProvider<_MutableConnection, AsyncValue<HostConnection?>>(
  _MutableConnection.new,
);

/// An image picker that stays open until the test hands back its result.
class _DeferredPicker extends FakePicker {
  final _picked = Completer<List<DraftAttachment>>();

  @override
  Future<List<DraftAttachment>> pickImages({required int limit}) {
    calls.add('images:$limit');
    return _picked.future;
  }

  void deliver(List<DraftAttachment> images) => _picked.complete(images);
}

/// Active Host for the non-active-Host test.
HostRef _testActive = HostRef.local;

class _FixedActiveHost extends ActiveHostController {
  @override
  HostRef build() => _testActive;
}

class _StatusProbe extends ConsumerWidget {
  const _StatusProbe(this.host);

  final HostRef host;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Text(watchHostStatus(ref, host).label);
}

void main() {
  setUpAll(loadTestFonts);

  Future<void> mountChat(WidgetTester tester, FakePicker picker, {List<Override> extra = const []}) async {
    usePhoneView(tester);
    final harness = ChatHarness(session: 's', picker: picker, extra: extra);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: harness.overrides,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  Future<void> openGallery(WidgetTester tester) async {
    await tester.tap(find.byType(AttachButton));
    await pumpFrames(tester);
    await tester.tap(find.text('相册'));
    await pumpFrames(tester);
  }

  testWidgets('picking an image returns focus to the composer input', (tester) async {
    final picker = FakePicker()..images = [DraftAttachment.sniff('cat.png', tinyPng)];
    await mountChat(tester, picker);

    expect(find.byType(AttachButton), findsOneWidget);
    expect(picker.calls, isEmpty);
    await openGallery(tester);

    expect(picker.calls, contains('images:9'));

    final input = find.byType(EditableText);
    expect(input, findsOneWidget);
    final editable = tester.widget<EditableText>(input);
    expect(
      FocusManager.instance.primaryFocus,
      same(editable.focusNode),
      reason: 'the caret must be back in the input so typing lands immediately',
    );
    await tester.enterText(input, '配图');
    expect(editable.controller.text, '配图');
  });

  testWidgets('a cancelled picker does not steal focus', (tester) async {
    final picker = FakePicker(); // images empty: the system picker was dismissed.
    await mountChat(tester, picker);

    FocusManager.instance.primaryFocus?.unfocus();
    await pumpFrames(tester);

    await openGallery(tester);

    expect(picker.calls, contains('images:9'));
    final input = find.byType(EditableText);
    if (input.evaluate().isNotEmpty) {
      final editable = tester.widget<EditableText>(input.first);
      expect(FocusManager.instance.primaryFocus, isNot(same(editable.focusNode)));
    }
    expect(find.text('配图'), findsNothing);
  });

  testWidgets('a pick kept open until the target client arrives is not dropped', (tester) async {
    final picker = _DeferredPicker();
    final harness = ChatHarness(
      session: 's',
      connected: false,
      picker: picker,
      extra: [agentSwitchReconnectProvider.overrideWith(_AlwaysSilent.new)],
    );
    await tester.pumpWidget(
      testApp(
        ProviderScope(
          overrides: [
            activeConnectionProvider.overrideWith((ref) => ref.watch(_connectionStateProvider)),
          ],
          child: const ChatScreen(),
        ),
        overrides: harness.overrides,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.tap(find.byType(AttachButton));
    await pumpFrames(tester);
    await tester.tap(find.text('相册'));
    await pumpFrames(tester);
    expect(picker.calls, contains('images:9'));

    // The Agent-switch target connects while the system picker is still open.
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
    container.read(_connectionStateProvider.notifier).set(AsyncData<HostConnection?>(fakeConnection));
    await pumpFrames(tester);

    picker.deliver([DraftAttachment.sniff('cat.png', tinyPng)]);
    await pumpFrames(tester);

    final tray = find.byType(ComposerTray);
    expect(tray, findsOneWidget);
    expect(tester.widget<ComposerTray>(tray).items, hasLength(1));
  });

  // ── Agent-switch silent window regressions ─────────────────────────────────

  test('silentConnect masks connecting only, never reconnecting or failed', () {
    final connecting = HostStatusView.ofLink(
      const HostLinkStatus(HostLinkPhase.connecting),
      silentConnect: true,
    );
    expect(connecting.label, appL10n.remoteConnected);

    final reconnecting = HostStatusView.ofLink(
      const HostLinkStatus(HostLinkPhase.reconnecting),
      silentConnect: true,
    );
    expect(reconnecting.label, appL10n.remoteReconnecting);

    final failed = HostStatusView.ofLink(
      const HostLinkStatus(HostLinkPhase.failed),
      silentConnect: true,
    );
    expect(failed.label, appL10n.commonConnectionFailed);
  });

  testWidgets('a non-active Host connecting is not silenced during an Agent switch', (tester) async {
    final active = HostRef.ssh('active');
    final other = HostRef.ssh('other');
    _testActive = active;
    await tester.pumpWidget(
      testApp(
        const _StatusProbe(HostRef.ssh('other')),
        overrides: [
          agentSwitchReconnectProvider.overrideWith(_AlwaysSilent.new),
          activeHostProvider.overrideWith(_FixedActiveHost.new),
          hostLinkStatusProvider(other).overrideWithValue(
            const AsyncData(HostLinkStatus(HostLinkPhase.connecting)),
          ),
          activeConnectionProvider.overrideWithValue(const AsyncData(null)),
        ],
      ),
    );
    await pumpFrames(tester);
    expect(find.text(appL10n.remoteConnecting), findsOneWidget);
  });

  testWidgets('hasError ends the silent window and keeps the error banner visible', (tester) async {
    const sentinel = '连接错误-回归';
    final harness = ChatHarness(
      session: 's',
      states: {'s': ChatState(loading: false, error: sentinel)},
      extra: [agentSwitchReconnectProvider.overrideWith(_AlwaysSilent.new)],
    );
    await tester.pumpWidget(
      testApp(
        ProviderScope(
          overrides: [
            activeConnectionProvider.overrideWithValue(
              AsyncError<HostConnection?>(StateError('boom'), StackTrace.current),
            ),
          ],
          child: const ChatScreen(),
        ),
        overrides: harness.overrides,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text(sentinel), findsOneWidget);
  });

  testWidgets('an error during an Agent switch ends the silent window, and retry shows connecting', (tester) async {
    _testActive = HostRef.relay('relay');
    addTearDown(() => _testActive = HostRef.local);
    final conn = _MutableConnection();
    final harness = ChatHarness(
      session: 's',
      connected: false,
      extra: [
        _connectionStateProvider.overrideWith(() => conn),
        activeHostProvider.overrideWith(_FixedActiveHost.new),
      ],
    );
    await tester.pumpWidget(
      testApp(
        ProviderScope(
          overrides: [activeConnectionProvider.overrideWith((ref) => ref.watch(_connectionStateProvider))],
          child: const ChatScreen(),
        ),
        overrides: harness.overrides,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));

    conn.set(AsyncData<HostConnection?>(
      HostConnection(
        client: fakeConnection.client,
        isLocal: false,
        kind: HostKind.relay,
        hostId: 'relay',
        agent: RemoteAgent.dsh,
      ),
    ));
    await pumpFrames(tester);

    // Switch the Agent for the same Host, exactly as a user selecting a
    // different Agent in settings would. This is what triggers
    // agentSwitchReconnectProvider in production.
    container.read(agentSelectionProvider.notifier).select('relay', RemoteAgent.codex);
    await pumpFrames(tester);
    expect(container.read(activeAgentProvider), RemoteAgent.codex);
    expect(container.read(agentSwitchReconnectProvider), isTrue);

    // The target connection fails. That must clear the silent window instead
    // of remaining "已连接" while the next retry is merely loading.
    conn.set(AsyncError<HostConnection?>(StateError('boom'), StackTrace.current));
    await pumpFrames(tester);
    expect(container.read(agentSwitchReconnectProvider), isFalse);

    conn.set(const AsyncLoading<HostConnection?>());
    await pumpFrames(tester);
    expect(container.read(agentSwitchReconnectProvider), isFalse);
    expect(find.text(appL10n.chatConnecting), findsOneWidget);
  });

  testWidgets('a notice is not swallowed by the silent window', (tester) async {
    const sentinel = '通知-回归';
    final harness = ChatHarness(
      session: 's',
      states: {'s': ChatState(loading: false, notice: sentinel)},
      extra: [agentSwitchReconnectProvider.overrideWith(_AlwaysSilent.new)],
    );
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: harness.overrides,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text(sentinel), findsOneWidget);
  });

  testWidgets('typing during an Agent switch still sends to the target Agent', (tester) async {
    // 旧 client 已退、新 client 还没连上:只有切换静默窗口让它可输入可发送。
    final harness = ChatHarness(
      session: 's',
      connected: false,
      extra: [agentSwitchReconnectProvider.overrideWith(_AlwaysSilent.new)],
    );
    await tester.pumpWidget(
      testApp(const ChatScreen(), overrides: harness.overrides),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    const message = '切换中也要能发';
    await tester.enterText(find.byType(EditableText), message);
    await pumpFrames(tester);

    final sendKey = find.bySemanticsLabel(appL10n.commonSend);
    expect(sendKey, findsOneWidget);
    await tester.tap(sendKey);
    await pumpFrames(tester);

    expect(harness.controllers['s']!.sent, [message]);
    expect(find.text(appL10n.chatConnecting), findsNothing);
    expect(find.text(appL10n.chatConnectToSend), findsNothing);
  });

  testWidgets('without a target session the silent window stays disconnected', (tester) async {
    final harness = ChatHarness(
      connected: false,
      extra: [agentSwitchReconnectProvider.overrideWith(_AlwaysSilent.new)],
    );
    await tester.pumpWidget(
      testApp(const ChatScreen(), overrides: harness.overrides),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));

    expect(find.text(appL10n.chatConnectToSend), findsOneWidget);
    expect(harness.controllers, isEmpty);
  });
}
