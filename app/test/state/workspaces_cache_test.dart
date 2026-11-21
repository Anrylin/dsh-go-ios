// The five-minute display snapshot uses the same identity that carries the
// active Agent, so a switch never shows the other Agent's rows.
// Workspace selection also survives the pre-Agent relay key.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/agent_selection_state.dart' show AgentSelection, AgentSelectionController, agentSelectionProvider;
import 'package:dsh_app/state/drawer_view_state.dart' show DrawerViewController;
import 'package:dsh_app/state/hosts_state.dart' show ActiveHostController, HostRef, activeHostProvider;
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/state/read_list_identity.dart' show ReadListIdentity, readListLiveConnectionProvider;
import 'package:dsh_app/state/workspaces_state.dart'
    show
        WorkspacePrefs,
        WorkspacePrefsController,
        WorkspacesController,
        WorkspacesState,
        WorkspacesStatus,
        newChatBaselineTimeout,
        workspaceForNewSession,
        workspacePrefsProvider,
        workspacesProvider;
import 'package:dsh_client/dsh_client.dart' show Workspace;
import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _newSessionWorkspace = FutureProvider.family<String?, String?>(
  (ref, cwd) => workspaceForNewSession(ref, cwd: cwd),
);

class _FixedHost extends ActiveHostController {
  _FixedHost(this.host);
  final HostRef host;

  @override
  HostRef build() => host;
}

class _FixedWorkspaces extends WorkspacesController {
  _FixedWorkspaces(this.value);
  final WorkspacesState value;

  @override
  WorkspacesState build() => value;
}

class _PendingWorkspaces extends WorkspacesController {
  final Completer<void> _released = Completer<void>();

  @override
  Future<void> get baseline => _released.future;

  @override
  WorkspacesState build() => const WorkspacesState(status: WorkspacesStatus.loading);

  void publish(List<Workspace> workspaces) {
    state = WorkspacesState(status: WorkspacesStatus.ready, workspaces: workspaces);
    if (!_released.isCompleted) _released.complete();
  }
}

class _FixedAgents extends AgentSelectionController {
  _FixedAgents(this.hostId, this.agent);
  final String hostId;
  final RemoteAgent agent;

  @override
  AgentSelection build() => AgentSelection(defaultAgent: agent, byHost: {hostId: agent});
}

class _FixedPrefs extends WorkspacePrefsController {
  _FixedPrefs(this.selected);
  final String? selected;

  @override
  WorkspacePrefs build() => WorkspacePrefs(loaded: true, selected: selected);

  @override
  Future<String?> selection() async => selected;
}

Workspace _w(String id, String path) => Workspace(workspaceId: id, path: path, title: id, sessionIds: const []);

ProviderContainer _container(String? selected, List<Workspace> workspaces) {
  final container = ProviderContainer(
    overrides: [
      workspacePrefsProvider.overrideWith(() => _FixedPrefs(selected)),
      workspacesProvider.overrideWith(
        () => _FixedWorkspaces(WorkspacesState(status: WorkspacesStatus.ready, workspaces: workspaces)),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  final relay = HostRef.relay('h1');

  test('workspace state rebuilds after its previous baseline completed', () async {
    final container = ProviderContainer(
      overrides: [readListLiveConnectionProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);
    final controller = container.read(workspacesProvider.notifier);
    final first = controller.baseline;
    await first;

    container.invalidate(workspacesProvider);

    expect(container.read(workspacesProvider).workspaces, isEmpty);
    expect(controller.baseline, isNot(same(first)));
  });

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

  group('workspaceForNewSession', () {
    test('an explicit selection wins over cwd and registry order', () async {
      final container = _container('second', [_w('first', '/root/shop'), _w('second', '/elsewhere')]);
      expect(await container.read(_newSessionWorkspace('/root/shop/app').future), 'second');
    });

    test('without a selection, the longest cwd folder match wins', () async {
      final container = _container(null, [
        _w('root', '/root'),
        _w('shop', '/root/shop'),
        _w('app', '/root/shop/app'),
        _w('sibling', '/root/shop-app'),
      ]);
      expect(await container.read(_newSessionWorkspace('/root/shop/app/lib').future), 'app');
      expect(await container.read(_newSessionWorkspace('/root/shop/README.md').future), 'shop');
      expect(await container.read(_newSessionWorkspace('/root/shop-app/lib').future), 'sibling');
    });

    test('a selection the Host no longer has falls back to the cwd match', () async {
      final container = _container('removed', [_w('shop', '/root/shop'), _w('other', '/elsewhere')]);
      expect(await container.read(_newSessionWorkspace('/root/shop/app').future), 'shop');
    });

    test('an unmatched cwd falls back to the first workspace in the registry', () async {
      final container = _container(null, [_w('first', '/a'), _w('second', '/b')]);
      expect(await container.read(_newSessionWorkspace('/elsewhere').future), 'first');
      expect(await container.read(_newSessionWorkspace(null).future), 'first');
    });

    test('relay without cwd prefers default-workspace over the newest row', () async {
      final container = _container(null, [
        _w('newest', '/newest'),
        Workspace(workspaceId: 'default-id', path: '/root/default', title: 'default-workspace', sessionIds: const []),
      ]);
      expect(await container.read(_newSessionWorkspace(null).future), 'default-id');
    });

    test('a loading registry is awaited instead of resolving ungrouped', () async {
      final registry = _PendingWorkspaces();
      final container = ProviderContainer(
        overrides: [
          workspacePrefsProvider.overrideWith(() => _FixedPrefs(null)),
          workspacesProvider.overrideWith(() => registry),
        ],
      );
      addTearDown(container.dispose);

      var done = false;
      final resolved = container.read(_newSessionWorkspace(null).future).then((id) {
        done = true;
        return id;
      });
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);

      registry.publish([_w('first', '/a'), _w('second', '/b')]);
      expect(await resolved, 'first');
    });

    test('a registry that never publishes a baseline never resolves ungrouped', () async {
      final original = newChatBaselineTimeout;
      newChatBaselineTimeout = const Duration(milliseconds: 10);
      addTearDown(() => newChatBaselineTimeout = original);
      final container = ProviderContainer(
        overrides: [
          workspacePrefsProvider.overrideWith(() => _FixedPrefs(null)),
          workspacesProvider.overrideWith(_PendingWorkspaces.new),
        ],
      );
      addTearDown(container.dispose);

      await expectLater(container.read(_newSessionWorkspace(null).future), throwsStateError);
    });

    test('an empty registry leaves the cwd fallback to the caller', () async {
      final container = _container(null, const []);
      expect(await container.read(_newSessionWorkspace('/elsewhere').future), isNull);
    });
  });

  test('a relay inherits the pre-Agent workspace preference once', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      WorkspacePrefsController.legacyKeyFor(relay): jsonEncode(<String, Object?>{
        'selected': 'old-id',
        'pinned': const ['old-id'],
        'groups': const {},
        'recent': const [],
      }),
    });
    final container = ProviderContainer(overrides: [activeHostProvider.overrideWith(() => _FixedHost(relay))]);
    addTearDown(container.dispose);

    expect(await container.read(workspacePrefsProvider.notifier).selection(), 'old-id');
    final prefs = await SharedPreferences.getInstance();
    final agentKey = WorkspacePrefsController.keyFor(relay);
    expect(prefs.getString(agentKey), contains('old-id'));
    // Kept so another Agent opening this Host inherits the same old choice.
    expect(prefs.getString(WorkspacePrefsController.legacyKeyFor(relay)), isNotNull);
  });

  test('a per-Agent choice is not overwritten by the legacy key while loading', () async {
    final agentKey = WorkspacePrefsController.keyFor(relay, agent: RemoteAgent.agy);
    String entry(String selected) => jsonEncode(<String, Object?>{
      'selected': selected,
      'pinned': const [],
      'groups': const {},
      'recent': const [],
    });
    SharedPreferences.setMockInitialValues(<String, Object>{
      agentKey: entry('new-id'),
      WorkspacePrefsController.legacyKeyFor(relay): entry('old-id'),
    });
    final container = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(() => _FixedHost(relay)),
        agentSelectionProvider.overrideWith(() => _FixedAgents(relay.id, RemoteAgent.agy)),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(workspacePrefsProvider.notifier).selection(), 'new-id');
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(agentKey)!)['selected'], 'new-id');
  });
}
