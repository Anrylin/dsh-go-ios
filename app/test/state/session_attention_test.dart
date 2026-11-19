// Unread marks belong to one Agent's conversation space: switching Agents
// must not carry the other Agent's seen timestamps into the new drawer.

import 'package:dsh_app/state/hosts_state.dart' show HostRef;
import 'package:dsh_app/state/session_attention_state.dart' show DrawerSeenController;
import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('relay seen marks are scoped by Agent', () {
    final relay = HostRef.relay('h1');
    final codex = DrawerSeenController.keyFor(relay, agent: RemoteAgent.codex);
    final agy = DrawerSeenController.keyFor(relay, agent: RemoteAgent.agy);
    expect(codex, contains(RemoteAgent.codex.code));
    expect(agy, contains(RemoteAgent.agy.code));
    expect(codex, isNot(agy));
    expect(DrawerSeenController.keyFor(relay), isNot(codex));
    expect(DrawerSeenController.keyFor(relay), isNot(agy));
  });

  test('local and SSH hosts keep one seen space per Host', () {
    expect(DrawerSeenController.keyFor(HostRef.local, agent: RemoteAgent.codex),
        DrawerSeenController.keyFor(HostRef.local));
    expect(DrawerSeenController.keyFor(HostRef.ssh('s1'), agent: RemoteAgent.agy),
        DrawerSeenController.keyFor(HostRef.ssh('s1')));
  });
}
