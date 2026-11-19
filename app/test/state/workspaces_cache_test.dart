// The five-minute display snapshot uses the same identity that carries the
// active Agent, so a switch never shows the other Agent's rows.

import 'package:dsh_app/state/drawer_view_state.dart' show DrawerViewController;
import 'package:dsh_app/state/hosts_state.dart' show HostRef;
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/state/read_list_identity.dart' show ReadListIdentity;
import 'package:dsh_app/state/workspaces_state.dart' show WorkspacePrefsController;
import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;
import 'package:flutter_test/flutter_test.dart';

void main() {
  final relay = HostRef.relay('h1');

  test('relay display keys isolate the Agent', () {
    expect(WorkspacePrefsController.keyFor(relay, agent: RemoteAgent.codex),
        isNot(WorkspacePrefsController.keyFor(relay, agent: RemoteAgent.agy)));
    expect(WorkspacePrefsController.keyFor(relay, agent: RemoteAgent.codex), isNot(WorkspacePrefsController.keyFor(relay)));
    expect(DrawerViewController.keyFor(relay, agent: RemoteAgent.codex),
        isNot(DrawerViewController.keyFor(relay, agent: RemoteAgent.agy)));

    final codex = ReadListIdentity.of(['relay', 'h1', RemoteAgent.codex.code]);
    final agy = ReadListIdentity.of(['relay', 'h1', RemoteAgent.agy.code]);
    expect(codex, isNot(agy));
    expect(readListKey(codex, ReadListKind.sessions, 'all'),
        isNot(readListKey(agy, ReadListKind.sessions, 'all')));
  });

  test('local and SSH hosts keep one view per Host', () {
    expect(WorkspacePrefsController.keyFor(HostRef.local, agent: RemoteAgent.codex), WorkspacePrefsController.keyFor(HostRef.local));
    expect(WorkspacePrefsController.keyFor(HostRef.ssh('s1'), agent: RemoteAgent.agy), WorkspacePrefsController.keyFor(HostRef.ssh('s1')));
    expect(DrawerViewController.keyFor(HostRef.local, agent: RemoteAgent.agy),
        DrawerViewController.keyFor(HostRef.local));
  });

  test('a display snapshot lives five minutes, then expires', () {
    var clock = DateTime(2026, 1, 1);
    final cache = ReadListCache(now: () => clock);
    addTearDown(cache.close);
    final identity = ReadListIdentity.of(['relay', 'h1', RemoteAgent.codex.code]);
    final key = readListKey(identity, ReadListKind.sessions, 'all');
    final source = Object();
    cache.stamp(source, identity, source);
    expect(
      cache.put(
        key,
        source,
        () => CachedSessions(sessions: const [], bots: const [], workspaceVersion: null, scoped: false),
      ),
      isTrue,
    );
    expect(cache.get<CachedSessions>(key)?.scoped, isFalse);
    clock = clock.add(const Duration(minutes: 4, seconds: 59));
    expect(cache.get<CachedSessions>(key)?.scoped, isFalse);
    clock = clock.add(const Duration(seconds: 2));
    expect(cache.get<CachedSessions>(key), isNull);
  });
}
