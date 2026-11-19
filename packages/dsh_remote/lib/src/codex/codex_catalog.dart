/// Catalog discovery and projection for the Codex virtual Harness, a faithful
/// Dart port of `dist/codex/virtual-catalog.js` (327 lines) plus the
/// `projectCodexThread` / `deriveCodexCwdWorkspaces` helpers bundled in
/// `@dsh-remote/client-core` (`dist/index.js` L65528–65604).
///
/// Codex projects and threads are independent paged App Server reads. A
/// thread is placed in a Workspace by an explicit `projectId`, the longest
/// matching project root, or (falling back) a derived cwd workspace. Threads
/// with no usable absolute cwd stay out of `workspaces` but remain in
/// `sessions`, so the "all conversations" drawer never loses them.
///
/// Both list reads de-duplicate by native id, detect cursor cycles, and expose
/// completeness on [CodexCatalog] instead of silently truncating at the page
/// cap.
library;

import '../util/bytes.dart';
import 'codex_api.dart';
import 'codex_values.dart';

const String codexWorkspacePrefix = 'codex-workspace:';
const String codexProvider = 'codex';
const String _codexModel = 'codex';
const int _codexPageLimit = 100;
const int _maxCodexPages = 32;

String codexProjectWorkspaceId(String projectId) => '$codexWorkspacePrefix''project:$projectId';

class CodexCatalog {
  const CodexCatalog({
    required this.threads,
    required this.sessions,
    required this.projects,
    required this.workspaces,
    this.threadsComplete = true,
    this.projectsComplete = true,
  });

  /// Every native thread returned by `thread/list` (de-duplicated), including
  /// threads that could not be placed in a Workspace. The search projection
  /// reads this list directly.
  final List<JsonMap> threads;

  /// Every projectable Session, including threads that could not be placed in
  /// a Workspace. `session/list` serves this list as the drawer's
  /// "all conversations" inventory, so unplaceable threads are intentionally
  /// kept here instead of being dropped.
  final List<JsonMap> sessions;

  final List<JsonMap> projects;
  final List<JsonMap> workspaces;

  /// `false` when `thread/list` pagination stopped at the page cap or saw a
  /// cursor cycle; callers may show "list may be incomplete" and retry.
  final bool threadsComplete;

  /// `false` when `project/list` pagination stopped at the page cap or saw a
  /// cursor cycle. An unsupported `project/list` yields an empty (complete)
  /// project list, matching the previous behaviour.
  final bool projectsComplete;
}

class _CodexProject {
  const _CodexProject({
    required this.id,
    required this.name,
    required this.roots,
    required this.position,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final List<String> roots;
  final num position;
  final int createdAt;
  final int updatedAt;
}

Future<List<JsonMap>> codexDiscoverVirtualWorkspaces(CodexAppApi api) async =>
    (await codexLoadCatalog(api)).workspaces;

Future<CodexCatalog> codexLoadCatalog(
  CodexAppApi api, {
  Map<String, JsonMap>? pendingThreads,
}) async {
  final results = await Future.wait<Object?>([
    _loadCodexProjects(api),
    _loadCodexThreads(api),
  ]);
  final projectPage = results[0] as ({List<_CodexProject> projects, bool complete});
  final threadPage = results[1] as ({List<JsonMap> threads, bool complete});
  final projects = projectPage.projects;

  final threads = threadPage.threads;
  if (pendingThreads != null) {
    final listedIds = threads.map((thread) => codexString(thread['id'])).whereType<String>().toSet();
    final consumed = <String>[];
    pendingThreads.forEach((threadId, thread) {
      if (listedIds.contains(threadId)) {
        consumed.add(threadId);
      } else {
        threads.insert(0, thread);
      }
    });
    for (final id in consumed) {
      pendingThreads.remove(id);
    }
  }

  // `thread/list` may repeat a thread across pages and `pendingThreads` may
  // race a listing; the native id is the identity, first occurrence wins.
  final dedupedThreads = _dedupeCodexThreads(threads);

  // Real projects always come first. A derived cwd workspace is only built for
  // a thread that neither resolved an explicit `projectId` nor matched any
  // real project root, and only when its cwd is a usable absolute path.
  final realProjectIds = <String>{for (final project in projects) project.id};
  num derivedPosition = 0;
  if (projects.isNotEmpty) {
    num last = projects.first.position;
    for (final project in projects) {
      if (project.position > last) last = project.position;
    }
    derivedPosition = last + 1;
  }
  final unmatchedThreads = <JsonMap>[];
  for (final thread in dedupedThreads) {
    final explicitId = codexString(thread['projectId']);
    if (explicitId != null && realProjectIds.contains(explicitId)) continue;
    final session = codexProjectThread(thread);
    final cwd = session == null ? null : codexString(session['cwd']);
    if (cwd != null && _longestMatchingProject(cwd, projects) != null) continue;
    unmatchedThreads.add(thread);
  }
  final derivedProjects = _deriveCodexCwdWorkspaces(
    unmatchedThreads,
    reservedIds: realProjectIds,
    positionStart: derivedPosition,
  );
  final effectiveProjects = <_CodexProject>[...projects, ...derivedProjects];

  final projected = <({JsonMap thread, JsonMap session})>[];
  for (final thread in dedupedThreads) {
    final session = codexProjectThread(thread);
    if (session != null) projected.add((thread: thread, session: session));
  }

  final workspaces = effectiveProjects.map(_projectWorkspace).toList();
  final workspaceByProjectId = <String, JsonMap>{
    for (var i = 0; i < effectiveProjects.length; i++)
      effectiveProjects[i].id: workspaces[i],
  };

  // Project rows are seeded with their own timestamps, then widened to the
  // earliest session start / latest session update assigned to that Workspace.
  final createdTimes = <String, int>{};
  final updatedTimes = <String, int>{};
  for (var i = 0; i < effectiveProjects.length; i++) {
    final workspaceId = codexString(workspaces[i]['workspaceId']) ?? '';
    final createdAt = effectiveProjects[i].createdAt;
    final updatedAt = effectiveProjects[i].updatedAt > 0 ? effectiveProjects[i].updatedAt : createdAt;
    createdTimes[workspaceId] = createdAt;
    updatedTimes[workspaceId] = updatedAt;
  }

  for (final item in projected) {
    final workspace = _findProjectWorkspace(item.thread, item.session, effectiveProjects, workspaceByProjectId);
    if (workspace == null) continue;
    final sessionId = codexString(item.session['id']) ?? '';
    final ids = (workspace['sessionIds'] as List<Object?>).cast<String>();
    if (!ids.contains(sessionId)) {
      ids.add(sessionId);
      workspace['sessionCount'] = ids.length;
    }

    final workspaceId = codexString(workspace['workspaceId']) ?? '';
    final createdAt = _codexWorkspaceTime(item.session['createdAt']);
    final updatedAt = _codexWorkspaceTime(item.session['updatedAt']);
    if (createdAt > 0) {
      final current = createdTimes[workspaceId];
      if (current == null || current <= 0 || createdAt < current) createdTimes[workspaceId] = createdAt;
    }
    if (updatedAt > 0) {
      final current = updatedTimes[workspaceId];
      if (current == null || updatedAt > current) updatedTimes[workspaceId] = updatedAt;
    }
  }

  for (var i = 0; i < workspaces.length; i++) {
    final workspaceId = codexString(workspaces[i]['workspaceId']) ?? '';
    final createdAt = createdTimes[workspaceId] ?? 0;
    final updatedAt = updatedTimes[workspaceId] ?? 0;
    if (createdAt > 0) workspaces[i]['createdAt'] = codexIsoTime(createdAt);
    if (updatedAt > 0) workspaces[i]['updatedAt'] = codexIsoTime(updatedAt);
  }

  // Threads that cannot be placed stay out of `workspaces` but remain in
  // `sessions`, which `session/list` serves as the "all conversations" drawer.
  // This keeps every Host thread reachable instead of silently dropping it.
  return CodexCatalog(
    threads: dedupedThreads,
    sessions: projected.map((item) => item.session).toList(),
    projects: effectiveProjects
        .map((project) => <String, Object?>{
              'id': project.id,
              'name': project.name,
              'roots': project.roots.map((root) => <String, Object?>{'path': root}).toList(),
              'position': project.position,
              'createdAt': project.createdAt,
              'updatedAt': project.updatedAt,
            })
        .toList(),
    workspaces: workspaces,
    threadsComplete: threadPage.complete,
    projectsComplete: projectPage.complete,
  );
}

List<JsonMap> _dedupeCodexThreads(Iterable<JsonMap> values) {
  final seen = <String>{};
  final result = <JsonMap>[];
  for (final value in values) {
    final id = codexString(value['id']);
    if (id == null || !seen.add(id)) continue;
    result.add(value);
  }
  return result;
}

int _codexWorkspaceTime(Object? value) {
  if (value is String) {
    final parsed = DateTime.tryParse(value);
    return parsed == null ? 0 : parsed.millisecondsSinceEpoch;
  }
  return codexNormalizeTime(value);
}

Future<({List<JsonMap> threads, bool complete})> _loadCodexThreads(CodexAppApi api) async {
  final threads = <JsonMap>[];
  final seenIds = <String>{};
  final seenCursors = <String>{};
  String? cursor;
  var complete = false;
  for (var page = 0; page < _maxCodexPages; page++) {
    final result = codexRecord(await api.request('thread/list', <String, Object?>{
      'limit': _codexPageLimit,
      'sortKey': 'updated_at',
      'sortDirection': 'desc',
      'archived': false,
      if (cursor != null) 'cursor': cursor,
    }));
    for (final value in codexArray(result['data'])) {
      final thread = codexRecord(value);
      final id = codexString(thread['id']);
      if (id != null && seenIds.add(id)) threads.add(thread);
    }
    final next = _nextCursor(result['nextCursor']);
    if (next == null) {
      complete = true;
      break;
    }
    // A Host that repeats or cycles its cursor would otherwise burn every
    // page and report a deceptively complete list.
    if (!seenCursors.add(next)) break;
    cursor = next;
  }
  return (threads: threads, complete: complete);
}

Future<({List<_CodexProject> projects, bool complete})> _loadCodexProjects(CodexAppApi api) async {
  final projects = <_CodexProject>[];
  final seenIds = <String>{};
  final seenCursors = <String>{};
  String? cursor;
  var complete = false;
  try {
    for (var page = 0; page < _maxCodexPages; page++) {
      final result = codexRecord(await api.request('project/list', <String, Object?>{
        'limit': _codexPageLimit,
        if (cursor != null) 'cursor': cursor,
      }));
      for (final value in codexArray(result['data'])) {
        final project = _projectCodexProject(value, projects.length);
        if (project != null && seenIds.add(project.id)) projects.add(project);
      }
      final next = _nextCursor(result['nextCursor']);
      if (next == null) {
        complete = true;
        break;
      }
      if (!seenCursors.add(next)) break;
      cursor = next;
    }
  } on Object catch (error) {
    if (_isProjectListUnsupported(error)) {
      return (projects: const <_CodexProject>[], complete: true);
    }
    rethrow;
  }
  projects.sort((left, right) {
    final position = left.position.compareTo(right.position);
    if (position != 0) return position;
    final name = left.name.compareTo(right.name);
    return name != 0 ? name : left.id.compareTo(right.id);
  });
  return (projects: projects, complete: complete);
}

String? _nextCursor(Object? value) {
  final cursor = codexString(value);
  return cursor != null && cursor.isNotEmpty ? cursor : null;
}

class CodexModelDirectory {
  const CodexModelDirectory({
    required this.defaultSelection,
    required this.groups,
    required this.models,
  });

  final JsonMap defaultSelection;
  final List<Object?> groups;
  final Map<String, JsonMap> models;
}

Future<CodexModelDirectory> codexLoadModelDirectory(CodexAppApi api) async {
  final models = <String, JsonMap>{};
  String? defaultModelId;
  String? cursor;
  for (var page = 0; page < _maxCodexPages; page++) {
    final result = codexRecord(await api.request('model/list', <String, Object?>{
      'limit': _codexPageLimit,
      'includeHidden': false,
      if (cursor != null) 'cursor': cursor,
    }));
    for (final value in codexArray(result['data'])) {
      final source = codexRecord(value);
      if (source['hidden'] == true) continue;
      final id = codexString(source['model']) ?? codexString(source['id']);
      if (id == null || models.containsKey(id)) continue;
      final efforts = <JsonMap>[];
      for (final value in codexArray(source['supportedReasoningEfforts'])) {
        final effort = codexRecord(value);
        final effortId = codexString(effort['reasoningEffort']);
        if (effortId == null) continue;
        final description = codexString(effort['description']);
        efforts.add(<String, Object?>{
          'id': effortId,
          'name': _reasoningEffortName(effortId),
          if (description != null) 'description': description,
        });
      }
      final defaultEffort = codexString(source['defaultReasoningEffort']);
      final description = codexString(source['description']);
      final hasDefaultEffort = defaultEffort != null && efforts.any((effort) => effort['id'] == defaultEffort);
      models[id] = <String, Object?>{
        'id': id,
        'name': codexString(source['displayName']) ?? id,
        if (description != null) 'description': description,
        if (efforts.isNotEmpty)
          'reasoning': <String, Object?>{
            'efforts': efforts,
            if (hasDefaultEffort) 'defaultEffort': defaultEffort,
          },
      };
      if (source['isDefault'] == true) defaultModelId = id;
    }
    cursor = _nextCursor(result['nextCursor']);
    if (cursor == null) break;
  }
  JsonMap? defaultModel = defaultModelId == null ? null : models[defaultModelId];
  if (defaultModel == null) {
    for (final model in models.values) {
      defaultModel = model;
      break;
    }
  }
  if (defaultModel == null) throw CodexValueError('CodeX did not advertise any available models.');
  final defaultEffort = codexRecord(defaultModel['reasoning'])['defaultEffort'];
  return CodexModelDirectory(
    defaultSelection: <String, Object?>{
      'provider': codexProvider,
      'model': defaultModel['id'] ?? _codexModel,
      if (defaultEffort != null) 'reasoningEffort': defaultEffort,
    },
    groups: <Object?>[
      <String, Object?>{
        'id': codexProvider,
        'name': 'CodeX',
        'models': models.values.toList(),
      },
    ],
    models: models,
  );
}

JsonMap codexNativeWorkspace(JsonMap view) {
  final copy = Map<String, Object?>.from(view)..remove('sessionCount');
  return copy;
}

List<JsonMap> codexNativeVisibleWorkspaces(CodexCatalog catalog, String? selectedWorkspaceId) => catalog.workspaces
    .where((workspace) => (workspace['sessionIds'] as List).isNotEmpty || workspace['workspaceId'] == selectedWorkspaceId)
    .toList();

JsonMap _projectWorkspace(_CodexProject project) {
  final root = project.roots.first;
  final title = project.name.trim();
  return <String, Object?>{
    'workspaceId': codexProjectWorkspaceId(project.id),
    'path': root,
    'title': title.isEmpty ? codexBasename(root) : title,
    'sessionIds': <String>[],
    'sessionCount': 0,
    'createdAt': codexIsoTime(project.createdAt),
    'updatedAt': codexIsoTime(project.updatedAt > 0 ? project.updatedAt : project.createdAt),
  };
}

_CodexProject? _projectCodexProject(Object? value, int fallbackPosition) {
  final source = codexRecord(value);
  final id = codexString(source['id']);
  if (id == null) return null;
  final roots = <String>[];
  for (final root in codexArray(source['roots'])) {
    final path = codexString(codexRecord(root)['path']);
    if (path != null && path.isNotEmpty) roots.add(path);
  }
  if (roots.isEmpty) return null;
  return _CodexProject(
    id: id,
    name: codexString(source['name']) ?? codexBasename(roots.first),
    roots: roots,
    position: codexFiniteNumber(source['position']) ?? fallbackPosition,
    createdAt: codexNormalizeTime(source['createdAt']),
    updatedAt: codexNormalizeTime(source['updatedAt']),
  );
}

JsonMap? _findProjectWorkspace(
  JsonMap thread,
  JsonMap session,
  List<_CodexProject> projects,
  Map<String, JsonMap> workspaceByProjectId,
) {
  final explicitId = codexString(thread['projectId']);
  if (explicitId != null) {
    final explicit = workspaceByProjectId[explicitId];
    if (explicit != null) return explicit;
  }
  final cwd = codexString(session['cwd']);
  if (cwd == null) return null;
  final project = _longestMatchingProject(cwd, projects);
  return project == null ? null : workspaceByProjectId[project.id];
}

/// Longest root wins; ties keep the same deterministic order as project
/// sorting (position, then id) so two projects sharing a root stay stable.
_CodexProject? _longestMatchingProject(String cwd, List<_CodexProject> projects) {
  _CodexProject? best;
  String? bestRoot;
  for (final project in projects) {
    for (final root in project.roots) {
      if (!codexContainsPath(root, cwd)) continue;
      if (best == null || bestRoot == null || root.length > bestRoot.length) {
        best = project;
        bestRoot = root;
        continue;
      }
      if (root.length != bestRoot.length) continue;
      final position = project.position.compareTo(best.position);
      if (position < 0 || (position == 0 && project.id.compareTo(best.id) < 0)) {
        best = project;
        bestRoot = root;
      }
    }
  }
  return best;
}

bool codexContainsPath(String root, String candidate) {
  final normalizedRoot = _normalizePathForCompare(root);
  final normalizedCandidate = _normalizePathForCompare(candidate);
  return normalizedCandidate == normalizedRoot ||
      normalizedCandidate.startsWith('$normalizedRoot/') ||
      normalizedCandidate.startsWith('$normalizedRoot\\');
}

String _normalizePathForCompare(String path) {
  final normalized = path.replaceFirst(RegExp(r'[\\/]+$'), '');
  return normalized.isEmpty && path.isNotEmpty ? path : normalized;
}

/// Threads without a project list still get cwd-derived workspaces, exactly
/// like the official client's `deriveCodexCwdWorkspaces`. Relative paths (`~`,
/// `.`, `foo/bar`) never become a workspace.
///
/// [reservedIds] (the real project ids) are pre-seeded into the id allocator so
/// a derived row can never take the native id of a real project. [positionStart]
/// lets these rows sort after the real projects when both kinds are combined.
List<_CodexProject> _deriveCodexCwdWorkspaces(
  List<JsonMap> values, {
  Set<String>? reservedIds,
  num positionStart = 0,
}) {
  final byPath = <String, _CodexProject>{};
  final usedIds = <String>{...?reservedIds};
  for (final value in values) {
    final session = codexProjectThread(value);
    final cwd = session == null ? null : codexString(session['cwd']);
    if (cwd == null || cwd.isEmpty || !_isAbsoluteWorkspacePath(cwd)) continue;
    final key = _normalizePathForCompare(cwd);
    final createdAt = codexNormalizeTime(session!['createdAt']);
    final updatedAt = codexNormalizeTime(session['updatedAt']);
    final existing = byPath[key];
    if (existing != null) {
      final earliest = createdAt <= 0 ? updatedAt : (updatedAt <= 0 ? createdAt : createdAt < updatedAt ? createdAt : updatedAt);
      byPath[key] = _CodexProject(
        id: existing.id,
        name: existing.name,
        roots: existing.roots,
        position: existing.position,
        createdAt: existing.createdAt <= 0 ? earliest : (earliest <= 0 ? existing.createdAt : existing.createdAt < earliest ? existing.createdAt : earliest),
        updatedAt: updatedAt > existing.updatedAt ? updatedAt : existing.updatedAt,
      );
      continue;
    }
    final baseId = 'cwd-${_imageHashCodex(key)}';
    var id = baseId;
    for (var suffix = 2; usedIds.contains(id); suffix++) {
      id = '$baseId-$suffix';
    }
    usedIds.add(id);
    byPath[key] = _CodexProject(
      id: id,
      name: codexBasename(cwd),
      roots: <String>[cwd],
      position: positionStart + byPath.length,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
  return byPath.values.toList();
}

bool _isAbsoluteWorkspacePath(String path) =>
    path.startsWith('/') ||
    RegExp(r'^\\\\[^\\]+\\[^\\]+').hasMatch(path) ||
    RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);

String _imageHashCodex(String value) {
  int hash = 2166136261;
  for (final unit in value.codeUnits) {
    hash = (hash ^ unit) & 0xffffffff;
    hash = (hash * 16777619) & 0xffffffff;
  }
  return hash.toRadixString(36);
}

JsonMap codexModelSelection() => const <String, Object?>{'provider': codexProvider, 'model': _codexModel};

JsonMap codexModelSelectionProjection(JsonMap selection) =>
    <String, Object?>{'lastUsed': selection, 'next': selection};

JsonMap codexModelCatalog(CodexModelDirectory directory) => <String, Object?>{
      'default': directory.defaultSelection,
      'routableProviders': <Object?>[codexProvider],
      'groups': directory.groups,
      'failures': <Object?>[],
    };

JsonMap codexModelParams(JsonMap selection) => <String, Object?>{
      'model': selection['model'] ?? _codexModel,
      if (selection['reasoningEffort'] != null) 'effort': selection['reasoningEffort'],
    };

String _reasoningEffortName(String effort) => switch (effort) {
      'none' => 'None',
      'minimal' => 'Minimal',
      'low' => 'Low',
      'medium' => 'Medium',
      'high' => 'High',
      'xhigh' => 'Extra High',
      'max' => 'Max',
      'ultra' => 'Ultra',
      _ => effort,
    };

String? codexDisplayTitle(JsonMap session) {
  final value = session['title'] ?? session['preview'];
  final text = codexString(value);
  if (text == null || text.trim().isEmpty) return null;
  return text.length > 256 ? text.substring(0, 256) : text;
}

bool codexIsDirectoryListing(Object? value) {
  final listing = codexRecord(value);
  return codexString(listing['path']) != null &&
      codexString(listing['home']) != null &&
      listing['crumbs'] is List &&
      (listing['crumbs'] as List).every(_isDirectoryEntry) &&
      listing['entries'] is List &&
      (listing['entries'] as List).every(_isDirectoryEntry) &&
      listing['truncated'] is bool;
}

bool _isDirectoryEntry(Object? value) {
  final entry = codexRecord(value);
  return codexString(entry['name']) != null && codexString(entry['path']) != null && entry['hidden'] is bool;
}

bool _isProjectListUnsupported(Object? error) {
  final code = codexErrorCode(error);
  if (code == 'METHOD_NOT_ALLOWED' || code == 'METHOD_NOT_FOUND' || code == 'CODEX_UPSTREAM_ERROR') return true;
  if (error is CodexValueError) return error.message.contains('The requested Codex method is not available over Remote.');
  if (error is CodexAppException) {
    return error.message.contains('The requested Codex method is not available over Remote.');
  }
  return false;
}

/// DSH Session projection from a native Codex thread (client-core
/// `projectCodexThread`, L65528–65551), including the preview fallback from
/// the first user message in embedded `turns`.
JsonMap? codexProjectThread(Object? value) {
  final thread = codexRecord(value);
  final nativeId = codexString(thread['id']);
  if (nativeId == null) return null;
  final createdAt = codexNormalizeTime(thread['createdAt']);
  var updatedAt = codexNormalizeTime(thread['updatedAt']);
  if (updatedAt == 0) updatedAt = createdAt;
  final model = _projectCodexModel(thread);
  final explicitPreview = codexString(thread['preview']);
  final preview = explicitPreview != null && explicitPreview.trim().isNotEmpty
      ? explicitPreview
      : _firstUserPreview(thread['turns']);
  final status = codexRecord(thread['status']);
  final activeFlags = codexArray(status['activeFlags']);
  final statusType = codexString(status['type']);
  var projectedStatus = 'idle';
  if (statusType == 'systemError') {
    projectedStatus = 'failed';
  } else if (statusType == 'active') {
    projectedStatus = activeFlags.contains('waitingOnApproval') ? 'waiting' : 'running';
  }
  final sessionId = codexString(thread['sessionId']);
  final name = codexString(thread['name']);
  final cwd = codexString(thread['cwd']);
  return <String, Object?>{
    'id': '$codexSessionPrefix$nativeId',
    'backend': 'codex',
    'nativeId': nativeId,
    if (sessionId != null) 'sessionTreeId': sessionId,
    if (name != null && name.isNotEmpty) 'title': name,
    if (preview != null) 'preview': preview,
    if (cwd != null) 'cwd': cwd,
    if (model['model'] != null) 'model': model['model'],
    if (model['reasoningEffort'] != null) 'reasoningEffort': model['reasoningEffort'],
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'status': projectedStatus,
    if (thread['archived'] is bool) 'archived': thread['archived'],
    if (thread['isPinned'] is bool) 'pinned': thread['isPinned'],
  };
}

JsonMap _projectCodexModel(JsonMap thread) {
  final candidates = <Object?>[
    for (final turn in codexArray(thread['turns']).reversed) turn,
    thread,
  ];
  for (final candidate in candidates) {
    final record = codexRecord(candidate);
    if (record.isEmpty && candidate is! Map) continue;
    final rawModel = codexString(record['model']);
    final model = rawModel != null && rawModel.isNotEmpty
        ? rawModel
        : (codexString(record['modelId']) is String && (codexString(record['modelId']) ?? '').isNotEmpty
            ? codexString(record['modelId'])
            : null);
    if (model == null) continue;
    final rawEffort = codexString(record['reasoningEffort']);
    final effort = rawEffort != null && rawEffort.isNotEmpty
        ? rawEffort
        : (codexString(record['effort']) is String && (codexString(record['effort']) ?? '').isNotEmpty
            ? codexString(record['effort'])
            : null);
    return <String, Object?>{'model': model, if (effort != null) 'reasoningEffort': effort};
  }
  return const <String, Object?>{};
}

String? _firstUserPreview(Object? turns) {
  for (final turn in codexArray(turns)) {
    for (final item in codexArray(codexRecord(turn)['items'])) {
      final record = codexRecord(item);
      if (record['type'] != 'userMessage') continue;
      final text = codexString(record['text']) ?? codexString(codexRecord(record['content'])['text']);
      if (text == null) continue;
      final preview = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (preview.isEmpty) continue;
      return preview.length > 160 ? preview.substring(0, 160) : preview;
    }
  }
  return null;
}
