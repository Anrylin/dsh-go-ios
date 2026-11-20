/// Catalog-assembly tests for `codex_catalog.dart`.
///
/// The Codex App Server is faked at the [CodexAppApi] boundary: only
/// `project/list` and `thread/list` are answered, with a page index encoded in
/// `nextCursor` so multi-page, repeated-id and cursor-cycle cases are exact.
/// No network, carrier or event channel is involved.
library;

import 'dart:typed_data';

import 'package:dsh_remote/dsh_remote.dart';
import 'package:test/test.dart';

const int _t0 = 1700000000000; // 2023-11-14T22:13:20.000Z
const int _t1 = 1700003600000; // one hour later

/// Minimal [CodexAppApi] surface: `request` is the only method the catalog
/// loader calls. Everything else fails loudly if the catalog ever grows a new
/// dependency, instead of silently reaching the network.
class _FakeCodexAppApi implements CodexAppApi {
  _FakeCodexAppApi({
    List<Map<String, Object?>>? projectPages,
    List<Map<String, Object?>>? threadPages,
  })  : projectPages = projectPages ?? const <Map<String, Object?>>[],
        threadPages = threadPages ?? const <Map<String, Object?>>[];

  final List<Map<String, Object?>> projectPages;
  final List<Map<String, Object?>> threadPages;

  /// When set, every `project/list` call throws this instead of answering.
  Object? projectError;

  int projectCalls = 0;
  int threadCalls = 0;

  @override
  bool previewHistory = false;

  @override
  Duration get callTimeout => const Duration(seconds: 1);

  @override
  Duration get transferCallTimeout => const Duration(seconds: 1);

  @override
  Future<Object?> request(String method, Map<String, Object?> params) async {
    switch (method) {
      case 'project/list':
        projectCalls += 1;
        final error = projectError;
        if (error != null) throw error;
        return _page(projectPages, params['cursor']);
      case 'thread/list':
        threadCalls += 1;
        return _page(threadPages, params['cursor']);
      default:
        throw UnimplementedError('catalog unexpectedly requested $method');
    }
  }

  Map<String, Object?> _page(List<Map<String, Object?>> pages, Object? cursor) {
    final index = cursor == null ? 0 : int.parse(cursor as String);
    if (index < 0 || index >= pages.length) {
      throw StateError('fake cursor $cursor has no page $index');
    }
    return pages[index];
  }

  @override
  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    bool transfer = false,
  }) =>
      throw UnimplementedError('call is unused by the catalog');

  @override
  Future<Object?> callTransferred(Uint8List encoded) =>
      throw UnimplementedError('callTransferred is unused by the catalog');

  @override
  Future<CodexStreamHandle> subscribe(
    String threadId,
    CodexFrameHandler onFrame, {
    void Function(CodexStreamCloseReason reason)? onClose,
  }) =>
      throw UnimplementedError('subscribe is unused by the catalog');

  @override
  Future<void> closeStream(String streamId) =>
      throw UnimplementedError('closeStream is unused by the catalog');

  @override
  Future<void> respond(String requestHandle, CodexApprovalDecision decision) =>
      throw UnimplementedError('respond is unused by the catalog');

  @override
  Future<void> dispose() async {}
}

Map<String, Object?> _page(
  List<Map<String, Object?>> data, {
  String? nextCursor,
}) =>
    <String, Object?>{
      'data': data,
      if (nextCursor != null) 'nextCursor': nextCursor,
    };

Map<String, Object?> _project(
  String id, {
  String? name,
  required List<String> roots,
  num? position,
  int createdAt = _t0,
  int updatedAt = _t1,
}) =>
    <String, Object?>{
      'id': id,
      if (name != null) 'name': name,
      'roots': <Object?>[
        for (final root in roots) <String, Object?>{'path': root},
      ],
      if (position != null) 'position': position,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };

Map<String, Object?> _thread(
  String id, {
  String? projectId,
  String? cwd,
  int createdAt = _t0,
  int updatedAt = _t1,
}) =>
    <String, Object?>{
      'id': id,
      if (projectId != null) 'projectId': projectId,
      if (cwd != null) 'cwd': cwd,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };

List<String> _sessionIds(Map<String, Object?> workspace) =>
    (workspace['sessionIds']! as List<Object?>).cast<String>();

Map<String, Object?> _singleWorkspaceAtPath(CodexCatalog catalog, String path) {
  final matches = catalog.workspaces.where((workspace) => workspace['path'] == path).toList();
  expect(matches, hasLength(1), reason: 'exactly one workspace at $path');
  return matches.single;
}

String _isoOf(int milliseconds) =>
    DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true).toIso8601String();

void main() {
  group('workspace derivation for unmatched threads', () {
    test('a listed project and a thread in an unrelated absolute cwd both appear', () async {
      final api = _FakeCodexAppApi(
        projectPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[_project('p1', name: 'App', roots: <String>['/repo/app'])], nextCursor: null),
        ],
        threadPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[_thread('t1', cwd: '/elsewhere/notes')]),
        ],
      );

      final catalog = await codexLoadCatalog(api);

      expect(catalog.workspaces, hasLength(2));
      final projectWorkspace = _singleWorkspaceAtPath(catalog, '/repo/app');
      expect(projectWorkspace['workspaceId'], codexProjectWorkspaceId('p1'));
      expect(projectWorkspace['sessionCount'], 0);

      final derived = _singleWorkspaceAtPath(catalog, '/elsewhere/notes');
      expect(codexStringOf(derived['workspaceId']), startsWith('codex-workspace:project:cwd-'));
      expect(derived['title'], 'notes');
      expect(derived['sessionCount'], 1);
      expect(_sessionIds(derived), <String>['codex:t1']);
      expect(derived['createdAt'], _isoOf(_t0));
      expect(derived['updatedAt'], _isoOf(_t1));

      // Derived rows are appended after real projects, never interleaved.
      expect(catalog.projects, hasLength(2));
      expect(catalog.projects.first['id'], 'p1');
      expect(codexStringOf(catalog.projects.last['id']), startsWith('cwd-'));
      expect(catalog.sessions.map((session) => session['id']), <Object?>['codex:t1']);
      expect(catalog.threads.map((thread) => thread['id']), <Object?>['t1']);
    });

    test('an explicit resolvable projectId wins over an unrelated cwd', () async {
      final api = _FakeCodexAppApi(
        projectPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[_project('p1', roots: <String>['/repo/app'])]),
        ],
        threadPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[
            _thread('t1', projectId: 'p1', cwd: '/elsewhere/notes'),
          ]),
        ],
      );

      final catalog = await codexLoadCatalog(api);

      // Explicit placement means no stray cwd workspace is invented.
      expect(catalog.workspaces, hasLength(1));
      final workspace = _singleWorkspaceAtPath(catalog, '/repo/app');
      expect(_sessionIds(workspace), <String>['codex:t1']);
      expect(workspace['sessionCount'], 1);
    });

    test('zero projects still derives every absolute cwd exactly as before', () async {
      final api = _FakeCodexAppApi(
        projectPages: <Map<String, Object?>>[_page(<Map<String, Object?>>[])],
        threadPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[
            _thread('t1', cwd: '/work/one'),
            _thread('t2', cwd: '/work/two', createdAt: _t0, updatedAt: _t1),
          ]),
        ],
      );

      final catalog = await codexLoadCatalog(api);

      expect(catalog.workspaces, hasLength(2));
      expect(catalog.projects, hasLength(2));
      expect(catalog.sessions, hasLength(2));
      expect(catalog.threads, hasLength(2));
      expect((catalog.workspaces.first['sessionIds']! as List<Object?>).length, 1);
      expect(
        catalog.workspaces.map((workspace) => workspace['path']).toSet(),
        <Object?>{'/work/one', '/work/two'},
      );
    });
  });

  group('multi-root, empty and duplicate-root projects', () {
    test('threads in any root attach to the project, zero-thread projects stay visible', () async {
      final api = _FakeCodexAppApi(
        projectPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[
            _project('p1', name: 'Multi', roots: <String>['/repo/a', '/repo/b'], position: 0),
            _project('p2', name: 'Empty', roots: <String>['/repo/empty'], position: 1),
          ]),
        ],
        threadPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[_thread('t1', cwd: '/repo/b/deep/file')]),
        ],
      );

      final catalog = await codexLoadCatalog(api);

      expect(catalog.workspaces, hasLength(2));
      final multi = _singleWorkspaceAtPath(catalog, '/repo/a');
      expect(multi['workspaceId'], codexProjectWorkspaceId('p1'));
      expect(multi['title'], 'Multi');
      expect(multi['sessionCount'], 1);
      expect(_sessionIds(multi), <String>['codex:t1']);
      expect(multi['createdAt'], _isoOf(_t0));
      expect(multi['updatedAt'], _isoOf(_t1));

      final empty = _singleWorkspaceAtPath(catalog, '/repo/empty');
      expect(empty['workspaceId'], codexProjectWorkspaceId('p2'));
      expect(empty['title'], 'Empty');
      expect(empty['sessionCount'], 0);
      expect(empty['sessionIds'], isEmpty);
      expect(empty['createdAt'], _isoOf(_t0));
      expect(empty['updatedAt'], _isoOf(_t1));
      expect(catalog.projects.map((project) => project['id']), <Object?>['p1', 'p2']);
    });

    test('two distinct projects sharing a root path are never merged', () async {
      final api = _FakeCodexAppApi(
        projectPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[
            _project('pA', name: 'A', roots: <String>['/shared'], position: 0),
            _project('pB', name: 'B', roots: <String>['/shared'], position: 1),
          ]),
        ],
        threadPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[_thread('t1', cwd: '/shared')]),
        ],
      );

      final catalog = await codexLoadCatalog(api);

      expect(catalog.workspaces, hasLength(2));
      expect(catalog.projects.map((project) => project['id']), <Object?>['pA', 'pB']);
      expect(
        catalog.workspaces.map((workspace) => workspace['workspaceId']).toSet(),
        <Object?>[codexProjectWorkspaceId('pA'), codexProjectWorkspaceId('pB')],
      );
      // The tie is broken deterministically by position: the first project
      // owns the session, the second stays listed with zero sessions.
      final byId = <Object?, Map<String, Object?>>{
        for (final workspace in catalog.workspaces) workspace['workspaceId']: workspace,
      };
      expect(byId[codexProjectWorkspaceId('pA')]!['path'], '/shared');
      expect(byId[codexProjectWorkspaceId('pA')]!['sessionCount'], 1);
      expect(_sessionIds(byId[codexProjectWorkspaceId('pA')]!), <String>['codex:t1']);
      expect(byId[codexProjectWorkspaceId('pB')]!['path'], '/shared');
      expect(byId[codexProjectWorkspaceId('pB')]!['sessionCount'], 0);
    });
  });

  group('pagination', () {
    test('repeated native ids across pages keep the first row and count once', () async {
      final api = _FakeCodexAppApi(
        projectPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[
            _project('p1', name: 'First', roots: <String>['/one'], position: 0),
            _project('p2', roots: <String>['/two'], position: 1),
          ], nextCursor: '1'),
          _page(<Map<String, Object?>>[
            _project('p1', name: 'Repeated', roots: <String>['/one'], position: 0),
            _project('p3', roots: <String>['/three'], position: 2),
          ]),
        ],
        threadPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[_thread('t1', cwd: '/one')], nextCursor: '1'),
          _page(<Map<String, Object?>>[_thread('t1', cwd: '/one'), _thread('t2', cwd: '/two')]),
        ],
      );

      final catalog = await codexLoadCatalog(api);

      expect(catalog.projects, hasLength(3));
      expect(catalog.projects.map((project) => project['id']), <Object?>['p1', 'p2', 'p3']);
      expect(catalog.projects.first['name'], 'First');

      expect(catalog.threads, hasLength(2));
      expect(catalog.sessions, hasLength(2));
      expect(catalog.sessions.where((session) => session['id'] == 'codex:t1'), hasLength(1));

      final one = _singleWorkspaceAtPath(catalog, '/one');
      expect(one['sessionCount'], 1);
      expect(_sessionIds(one), <String>['codex:t1']);
      expect(catalog.threadsComplete, isTrue);
      expect(catalog.projectsComplete, isTrue);
    });

    test('a repeating cursor stops pagination and clears completeness flags', () async {
      final api = _FakeCodexAppApi(
        projectPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[_project('p1', roots: <String>['/p'])], nextCursor: '0'),
        ],
        threadPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[_thread('t1', cwd: '/p')], nextCursor: '0'),
        ],
      );

      final catalog = await codexLoadCatalog(api);

      // Two calls per filter: the initial page, then the page reached by the
      // repeated cursor. Catalog loading now reads both archived=false and
      // archived=true, so thread/list is issued four times total.
      expect(api.projectCalls, 2);
      expect(api.threadCalls, 4);
      expect(catalog.projectsComplete, isFalse);
      expect(catalog.threadsComplete, isFalse);
      expect(catalog.workspaces, hasLength(1));
      expect(catalog.sessions, hasLength(1));
    });

    test('an unsupported project/list yields no native projects but still derives cwd', () async {
      final api = _FakeCodexAppApi(
        threadPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[_thread('t1', cwd: '/only/cwd')]),
        ],
      )..projectError = const CodexValueError('The requested Codex method is not available over Remote.');

      final catalog = await codexLoadCatalog(api);

      expect(catalog.projectsComplete, isTrue);
      expect(catalog.projects.single['id'], startsWith('cwd-'));
      expect(_singleWorkspaceAtPath(catalog, '/only/cwd')['sessionCount'], 1);
    });
  });

  group('unplaceable threads', () {
    test('are kept in sessions but never invented as workspaces', () async {
      final api = _FakeCodexAppApi(
        projectPages: <Map<String, Object?>>[_page(<Map<String, Object?>>[])],
        threadPages: <Map<String, Object?>>[
          _page(<Map<String, Object?>>[
            _thread('t-abs', cwd: '/absolute/dir'),
            _thread('t-rel', cwd: 'relative/dir'),
            _thread('t-tilde', cwd: '~'),
            _thread('t-dot', cwd: '.'),
            _thread('t-windows', cwd: r'C:\Users\ssujo\project'),
            _thread('t-none'),
          ]),
        ],
      );

      final catalog = await codexLoadCatalog(api);

      // Only the two absolute paths become workspaces.
      expect(catalog.workspaces, hasLength(2));
      expect(
        catalog.workspaces.map((workspace) => workspace['path']).toSet(),
        <Object?>{'/absolute/dir', r'C:\Users\ssujo\project'},
      );

      // All six threads survive in the all-conversations inventory.
      expect(catalog.sessions.map((session) => session['id']).toSet(), <Object?>{
        'codex:t-abs',
        'codex:t-rel',
        'codex:t-tilde',
        'codex:t-dot',
        'codex:t-windows',
        'codex:t-none',
      });
      expect(catalog.threads, hasLength(6));

      // Relative and missing paths are not attached to any workspace.
      final placed = catalog.workspaces
          .expand((workspace) => _sessionIds(workspace))
          .toSet();
      expect(placed, <String>{'codex:t-abs', 'codex:t-windows'});
    });
  });

  group('CodexCatalog completeness defaults', () {
    test('a hand-built catalog is complete unless told otherwise', () {
      const catalog = CodexCatalog(
        threads: <Map<String, Object?>>[],
        sessions: <Map<String, Object?>>[],
        projects: <Map<String, Object?>>[],
        workspaces: <Map<String, Object?>>[],
      );
      expect(catalog.threadsComplete, isTrue);
      expect(catalog.projectsComplete, isTrue);
    });
  });
}

String? codexStringOf(Object? value) => value is String ? value : null;
