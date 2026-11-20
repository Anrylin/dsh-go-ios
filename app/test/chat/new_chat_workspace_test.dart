// The new-chat screen keeps a workspace entry point even with no selection,
// and the workspace id inferred from a bare cwd reaches `session/create`.

import 'package:dsh_app/state/connection_state.dart' show HostConnection, activeConnectionProvider;
import 'package:dsh_app/state/hosts_state.dart' show ActiveHostController, HostRef, activeHostProvider;
import 'package:dsh_app/state/sessions_state.dart' show sessionsProvider;
import 'package:dsh_app/state/workspaces_state.dart'
    show
        WorkspacePrefs,
        WorkspacePrefsController,
        WorkspacesController,
        WorkspacesState,
        WorkspacesStatus,
        createSessionInWorkspace,
        workspaceForNewSession,
        workspacePrefsProvider,
        workspacesProvider;
import 'package:dsh_app/ui/chat/empty_state.dart' show ChatEmptyState;
import 'package:dsh_client/dsh_client.dart' show DshClient, DshRemoteException, Workspace, WorkspaceErrors;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/composer_fakes.dart' show FakeRpcCarrier;
import 'support/harness.dart' show testApp;

final _workspaceForCwd = FutureProvider.family<String?, String?>(
  (ref, cwd) => workspaceForNewSession(ref, cwd: cwd),
);

class _FixedWorkspaces extends WorkspacesController {
  _FixedWorkspaces(this.value);
  final WorkspacesState value;

  @override
  WorkspacesState build() => value;
}

class _FixedHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.local;
}

class _FixedPrefs extends WorkspacePrefsController {
  _FixedPrefs(this.selected);
  final String? selected;

  @override
  WorkspacePrefs build() => WorkspacePrefs(loaded: true, selected: selected);

  @override
  Future<String?> selection() async => selected;
}

ProviderContainer _container({String? selected, List<Workspace> workspaces = const []}) {
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

const _shop = Workspace(workspaceId: 'shop-id', path: '/root/shop', title: 'shop', sessionIds: []);
const _nested = Workspace(workspaceId: 'nested-id', path: '/root/shop/app', title: 'app', sessionIds: []);

void main() {
  test('inferred workspace id is sent as session/create workspaceId', () async {
    final carrier = FakeRpcCarrier({'session/create': (_) => {'sessionId': 's1'}});
    final client = DshClient.withCarrier(carrier);
    final container = _container(workspaces: [_shop, _nested]);

    final id = await container.read(_workspaceForCwd('/root/shop/app/lib').future);
    await createSessionInWorkspace(client, id, cwd: '/root/shop/app/lib');

    final request = carrier.argsOf('session/create').single['request'] as Map<String, Object?>;
    expect(request['workspaceId'], 'nested-id');
    expect(request.containsKey('cwd'), isFalse);
  });

  test('sessions.create passes the same cwd to the resolver and the fallback', () async {
    var calls = 0;
    final carrier = FakeRpcCarrier({
      'session/create': (args) {
        final request = args['request'] as Map<String, Object?>;
        calls++;
        if (calls == 1) {
          // The inferred workspace was deleted between selection and create.
          expect(request['workspaceId'], 'nested-id');
          throw DshRemoteException(WorkspaceErrors.notFound, 'gone');
        }
        // The fallback carries exactly the cwd used for the folder match.
        expect(request.containsKey('workspaceId'), isFalse);
        expect(request['cwd'], '/root/shop/app');
        return {'sessionId': 's3'};
      },
    });
    final conn = HostConnection(
      client: DshClient.withCarrier(carrier),
      isLocal: false,
      workingDirectory: '/root/shop/app',
    );
    final container = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(_FixedHost.new),
        activeConnectionProvider.overrideWithValue(AsyncData(conn)),
        workspacePrefsProvider.overrideWith(() => _FixedPrefs(null)),
        workspacesProvider.overrideWith(
          () => _FixedWorkspaces(
            WorkspacesState(status: WorkspacesStatus.ready, workspaces: [_shop, _nested]),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(await container.read(sessionsProvider.notifier).create(), 's3');
    expect(calls, 2);
  });

  test('a removed workspace still falls back to a bare cwd', () async {    final carrier = FakeRpcCarrier({
      'session/create': (args) {
        final request = args['request'] as Map<String, Object?>;
        if (request.containsKey('workspaceId')) {
          throw DshRemoteException(WorkspaceErrors.notFound, 'gone');
        }
        return {'sessionId': 's2'};
      },
    });
    final client = DshClient.withCarrier(carrier);

    await createSessionInWorkspace(client, 'stale-id', cwd: '/tmp/fallback');

    expect(carrier.argsOf('session/create').length, 2);
    final request = carrier.argsOf('session/create').last['request'] as Map<String, Object?>;
    expect(request['cwd'], '/tmp/fallback');
    expect(request.containsKey('workspaceId'), isFalse);
  });

  testWidgets('with no selection the chip names the inferred default workspace', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ChatEmptyState(connected: true, onSuggestion: (_) {}, onWorkspace: () {}),
        ),
        overrides: [
          workspacePrefsProvider.overrideWith(() => _FixedPrefs(null)),
          workspacesProvider.overrideWith(
            () => _FixedWorkspaces(
              WorkspacesState(
                status: WorkspacesStatus.ready,
                workspaces: [
                  const Workspace(workspaceId: 'newest-id', path: '/newest', title: 'newest', sessionIds: []),
                  const Workspace(
                    workspaceId: 'default-id',
                    path: '/root/default',
                    title: 'default-workspace',
                    sessionIds: [],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    await tester.pump();

    expect(find.text('在「默认工作区」中'), findsOneWidget);
    expect(find.text('全部对话'), findsNothing);
  });

  testWidgets('the new-chat workspace chip is visible and tappable with no selection', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ChatEmptyState(
            connected: true,
            onSuggestion: (_) {},
            onWorkspace: () => taps++,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('全部对话'), findsOneWidget);
    await tester.tap(find.text('全部对话'));
    expect(taps, 1);
  });

  testWidgets('a selected workspace keeps its own chip label', (tester) async {
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: ChatEmptyState(
            connected: true,
            workspace: 'shop',
            onSuggestion: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('shop'), findsOneWidget);
    expect(find.text('全部对话'), findsNothing);
  });
}
