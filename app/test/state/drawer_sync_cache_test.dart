// A reconnect keeps the connection alive while the session list reloads under
// a new identity. The persisted last-confirmed view must keep the Drawer
// populated during that gap, not only when the connection is fully down.

import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/account_state.dart';
import 'package:dsh_app/state/connection_state.dart' show HostConnection;
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart' show ActiveHostController, HostRef, activeHostProvider;
import 'package:dsh_app/state/offline_session_cache.dart';
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/state/read_list_identity.dart'
    show ReadListIdentity, readListIdentityProvider, readListLiveConnectionProvider;
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart'
    show
        WorkspacePrefs,
        WorkspacePrefsController,
        WorkspacesController,
        WorkspacesState,
        WorkspacesStatus,
        workspacePrefsProvider,
        workspacesProvider;
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _FixedHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _FixedAccount extends AccountController {
  @override
  AccountState build() => const AccountState();
}

class _FixedPrefs extends WorkspacePrefsController {
  @override
  WorkspacePrefs build() => const WorkspacePrefs(loaded: true, selected: null);
}

class _FixedWorkspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState(status: WorkspacesStatus.ready);
}

class _ReloadingSessions extends SessionsController {
  final _never = Completer<List<SessionSummary>>();

  @override
  Future<List<SessionSummary>> build() => _never.future;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late HostConnection connection;
  final identityA = ReadListIdentity.of(['before-sync']);
  final identityB = ReadListIdentity.of(['after-sync']);

  setUp(() async {
    connection = HostConnection(client: DshClient(DshConnection(Uri.parse('http://127.0.0.1:9'))), isLocal: true);
    dir = await Directory.systemTemp.createTemp('dsh-drawer-sync-cache-');
    OfflineSessionCache.instance
      ..directory = dir
      ..clear();
    await OfflineSessionCache.instance.load();
    OfflineSessionCache.instance.remember(
      hostId: 'local|local',
      workspace: 'all',
      sessions: CachedSessions(
        sessions: [
          SessionSummary(
            sessionId: 's1',
            updatedAt: DateTime.fromMillisecondsSinceEpoch(1234),
            running: false,
            blank: false,
            agentAvailable: false,
            projections: const SessionProjections(-1, <String, Object?>{'title': 'Cached chat'}),
          ),
        ],
        bots: const [],
        workspaceVersion: null,
        scoped: false,
        workspaceLabel: null,
      ),
    );
  });

  tearDown(() async {
    await OfflineSessionCache.instance.clear();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  ProviderContainer containerFor(ReadListIdentity? identity) {
    final container = ProviderContainer(
      overrides: [
        sessionsProvider.overrideWith(_ReloadingSessions.new),
        readListLiveConnectionProvider.overrideWithValue(connection),
        readListIdentityProvider.overrideWithValue(identity),
        activeHostProvider.overrideWith(_FixedHost.new),
        accountProvider.overrideWith(_FixedAccount.new),
        workspacePrefsProvider.overrideWith(_FixedPrefs.new),
        workspacesProvider.overrideWith(_FixedWorkspaces.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('keeps the confirmed list while a reconnect reloads under a new identity', () {
    final before = containerFor(identityA).read(drawerScopeProvider);
    expect(before, isNotNull);
    expect(before!.sessions.map((s) => s.sessionId), contains('s1'));
    expect(before.readOnly, isTrue);

    final after = containerFor(identityB).read(drawerScopeProvider);
    expect(after, isNotNull);
    expect(after!.sessions.map((s) => s.sessionId), contains('s1'));
    expect(after.readOnly, isTrue);
    expect(after.status, ReadListStatus.updating);
  });

  test('keeps the confirmed list while the identity is not yet resolved', () {
    final scope = containerFor(null).read(drawerScopeProvider);
    expect(scope, isNotNull);
    expect(scope!.sessions.map((s) => s.sessionId), contains('s1'));
    expect(scope.readOnly, isTrue);
  });
}
