// A loaded conversation on a target Host stays sendable while the link is
// down: the prompt enters that Agent's offline queue and is replayed on
// reconnect. A brand-new chat still needs a client to be created.

import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/agent_selection_state.dart' show activeAgentProvider;
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart' show ActiveHostController, HostRef, activeHostProvider;
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

class _UnconnectedSshHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.ssh('not-connected-yet');
}

void main() {
  testWidgets('disconnected but loaded chat keeps an optimistic send key', (tester) async {
    final harness = ChatHarness(
      session: 's',
      connected: false,
      states: const {
        's': ChatState(loading: false, title: '已有对话'),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    const message = '断连也要能发';
    await tester.enterText(find.byType(EditableText), message);
    await pumpFrames(tester);

    final sendKey = find.bySemanticsLabel(appL10n.commonSend);
    expect(sendKey, findsOneWidget);
    expect(tester.widget<Semantics>(sendKey).properties.enabled, isTrue);

    await tester.tap(sendKey);
    await pumpFrames(tester);

    expect(harness.controllers['s']!.sent, [message]);
    expect(harness.controllers['s']!.queuedOffline, [isTrue]);
    expect(find.text(appL10n.chatConnectToSend), findsNothing);
  });

  testWidgets('a definite connection failure does not disable a loaded chat', (tester) async {
    final harness = ChatHarness(
      session: 's',
      connectionOverride: activeConnectionProvider.overrideWithValue(
        AsyncError<HostConnection?>(StateError('link down'), StackTrace.current),
      ),
      states: const {
        's': ChatState(loading: false, title: '已有对话'),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.enterText(find.byType(EditableText), '失败中也先收着');
    await pumpFrames(tester);

    final sendKey = find.bySemanticsLabel(appL10n.commonSend);
    expect(sendKey, findsOneWidget);
    expect(tester.widget<Semantics>(sendKey).properties.enabled, isTrue);

    await tester.tap(sendKey);
    await pumpFrames(tester);
    expect(harness.controllers['s']!.sent, ['失败中也先收着']);
    expect(harness.controllers['s']!.queuedOffline, [isTrue]);
  });

  testWidgets('a stale client for another Agent queues locally instead of waiting', (tester) async {
    final harness = ChatHarness(
      session: 's',
      connected: true,
      extra: [activeAgentProvider.overrideWithValue(RemoteAgent.codex)],
      states: const {
        's': ChatState(loading: false, title: '已有对话'),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.enterText(find.byType(EditableText), '发给新 Agent 的排队消息');
    await pumpFrames(tester);

    final sendKey = find.bySemanticsLabel(appL10n.commonSend);
    expect(tester.widget<Semantics>(sendKey).properties.enabled, isTrue);

    await tester.tap(sendKey);
    await pumpFrames(tester);

    final controller = harness.controllers['s']!;
    expect(controller.sent, ['发给新 Agent 的排队消息']);
    expect(controller.queuedOffline, [isTrue]);
  });

  testWidgets('a connection to a different Host is not treated as live', (tester) async {
    final harness = ChatHarness(
      session: 's',
      connected: true,
      extra: [activeHostProvider.overrideWith(_UnconnectedSshHost.new)],
      states: const {
        's': ChatState(loading: false, title: '已有对话'),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.enterText(find.byType(EditableText), '发给未连接 SSH 主机');
    await pumpFrames(tester);

    final sendKey = find.bySemanticsLabel(appL10n.commonSend);
    expect(tester.widget<Semantics>(sendKey).properties.enabled, isTrue);

    await tester.tap(sendKey);
    await pumpFrames(tester);

    expect(harness.controllers['s']!.sent, ['发给未连接 SSH 主机']);
    expect(harness.controllers['s']!.queuedOffline, [isTrue]);
  });

  testWidgets('two taps in one frame cannot queue the same prompt twice', (tester) async {
    final harness = ChatHarness(
      session: 's',
      connected: false,
      states: const {
        's': ChatState(loading: false, title: '已有对话'),
      },
    );
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final gate = Completer<bool>();
    harness.controllers['s']!.sendResult = gate.future;
    await tester.enterText(find.byType(EditableText), '只发一次');
    await pumpFrames(tester);

    final sendKey = find.bySemanticsLabel(appL10n.commonSend);
    await tester.tap(sendKey);
    // No pump in between: this is the second tap of a double tap, before the
    // first send has handed the draft off.
    await tester.tap(sendKey);
    await pumpFrames(tester);

    final controller = harness.controllers['s']!;
    expect(controller.sent, ['只发一次']);
    expect(controller.queuedOffline, [isTrue]);
    gate.complete(true);
    await pumpFrames(tester);
  });

  testWidgets('without a target session the disconnected composer stays disabled', (tester) async {
    final harness = ChatHarness(connected: false);
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
    await tester.pumpAndSettle(const Duration(seconds: 1));

    await tester.enterText(find.byType(EditableText), '新对话还不能发');
    await pumpFrames(tester);

    final sendKey = find.bySemanticsLabel(appL10n.commonSend);
    expect(sendKey, findsOneWidget);
    expect(tester.widget<Semantics>(sendKey).properties.enabled, isFalse);

    await tester.tap(sendKey);
    await pumpFrames(tester);
    expect(harness.controllers, isEmpty);
  });
}
