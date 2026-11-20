// Workspaces of the active host, mirroring the official sidebar
// (`dsh-client-ui-workspace` over `dsh-api-workspace-controller`):
//
// * the Host owns the registry: folders, titles, order, which conversations
//   belong where (`Workspace.sessionIds`) and the pinned conversations
//   (`workspace/follow`, a baseline then increments);
// * the phone keeps its own view of it per host (`WorkspacePrefs`): the
//   workspace the drawer shows, pinned workspaces, groups and the folders
//   picked recently. The Host has no pin or group for a workspace, so these
//   stay on this phone.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/l10n.dart';
import '../runtime/local_paths.dart' show LocalPaths;
import 'agent_selection_state.dart';
import 'connection_state.dart' show HostConnection, activeConnectionProvider;
import 'hosts_state.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';

// ── Host registry ────────────────────────────────────────────────────────────

enum WorkspacesStatus {
  /// No connection to a host.
  offline,

  /// Connected, waiting for the first baseline.
  loading,
  ready,

  /// The host refused `workspace/follow` before any baseline.
  failed,
}

/// What the active host reports about its workspaces.
class WorkspacesState {
  const WorkspacesState({
    this.status = WorkspacesStatus.offline,
    this.workspaces = const [],
    this.pinnedSessionIds = const [],
    this.archivedSessionIds = const [],
  });

  final WorkspacesStatus status;

  /// Registry order (newest first unless reordered elsewhere).
  final List<Workspace> workspaces;

  /// Pinned conversations, most recently pinned first.
  final List<String> pinnedSessionIds;
  final List<String> archivedSessionIds;

  bool get ready => status == WorkspacesStatus.ready;

  Workspace? byId(String? id) {
    if (id == null) return null;
    for (final w in workspaces) {
      if (w.workspaceId == id) return w;
    }
    return null;
  }

  WorkspacesState copyWith({
    WorkspacesStatus? status,
    List<Workspace>? workspaces,
    List<String>? pinnedSessionIds,
    List<String>? archivedSessionIds,
  }) => WorkspacesState(
    status: status ?? this.status,
    workspaces: workspaces ?? this.workspaces,
    pinnedSessionIds: pinnedSessionIds ?? this.pinnedSessionIds,
    archivedSessionIds: archivedSessionIds ?? this.archivedSessionIds,
  );
}

/// Follows `workspace/follow` on the active connection and runs the
/// registry mutations. Like the official client model: a newer row (by
/// `updatedAt`) wins over an older one, the stream's order wins over unary
/// replies, and a removed workspace never comes back from late data.
class WorkspacesController extends Notifier<WorkspacesState> {
  final Map<String, Workspace> _rows = {};
  List<String> _order = const [];
  final Set<String> _removed = {};
  DshClient? _client;
  ReadListIdentity? _identity;
  Completer<void>? _baseline;

  /// Completes when the first `workspace/follow` baseline arrives, or when
  /// the Host goes away / refuses the stream. New sessions wait on this:
  /// `build` starts empty, and reading that empty registry by race would
  /// create an ungrouped conversation. Bounded by callers.
  Future<void> get baseline => _baseline?.future ?? Future.value();

  /// Also used by test doubles that publish a baseline without the stream.
  @visibleForTesting
  void completeBaseline() {
    if (_baseline?.isCompleted == false) _baseline!.complete();
  }

  @override
  WorkspacesState build() {
    final r = ref;
    _baseline?.complete();
    _baseline = Completer<void>();
    _rows.clear();
    _order = const [];
    _removed.clear();
    final conn = r.watch(readListLiveConnectionProvider);
    _client = conn?.client;
    _identity = conn == null ? null : r.watch(readListIdentityProvider);
    if (conn == null) {
      completeBaseline();
      return const WorkspacesState();
    }
    final sub = conn.client.watchWorkspaces().listen(
      (update) {
        if (r.mounted) _onFrame(update);
      },
      onError: (Object _) {
        if (r.mounted && !state.ready) state = state.copyWith(status: WorkspacesStatus.failed);
        completeBaseline();
      },
    );
    ref.onDispose(() => unawaited(sub.cancel()));
    return const WorkspacesState(status: WorkspacesStatus.loading);
  }

  void _onFrame(WorkspaceUpdate update) {
    final full = update is WorkspaceBaseline ? update : workspaceReplaceFrame(update);
    if (full != null) {
      _rows
        ..clear()
        ..addEntries(full.workspaces.map((w) => MapEntry(w.workspaceId, w)));
      _order = [for (final w in full.workspaces) w.workspaceId];
      _emit(status: WorkspacesStatus.ready, pinned: full.pinnedSessionIds, archived: full.archivedSessionIds);
      // The registry is usable now: a new chat may pick a workspace from it.
      completeBaseline();
      return;
    }
    switch (update) {
      case WorkspaceUpsert(:final workspace):
        _upsert(workspace, fromStream: true);
      case WorkspaceRemoved(:final workspaceId):
        _drop(workspaceId);
      case WorkspaceOrder(:final workspaceIds):
        _order = List.of(workspaceIds);
      case WorkspacePinnedUpdate(:final pinnedSessionIds):
        return _emit(pinned: pinnedSessionIds);
      case WorkspaceArchivedUpdate(:final archivedSessionIds):
        return _emit(archived: archivedSessionIds);
      default:
        return;
    }
    _emit();
  }

  void _upsert(Workspace w, {bool fromStream = false}) {
    if (w.workspaceId.isEmpty || _removed.contains(w.workspaceId)) return;
    final old = _rows[w.workspaceId];
    if (old != null && !fromStream && _isOlder(w, old)) return;
    _rows[w.workspaceId] = w;
    // New registrations go to the front, like the Host's own order frame.
    if (!_order.contains(w.workspaceId)) _order = [w.workspaceId, ..._order];
  }

  static bool _isOlder(Workspace a, Workspace b) =>
      a.updatedAt != null && b.updatedAt != null && a.updatedAt!.isBefore(b.updatedAt!);

  void _drop(String id) {
    _removed.add(id);
    _rows.remove(id);
    _order = [
      for (final o in _order)
        if (o != id) o,
    ];
  }

  void _emit({WorkspacesStatus? status, List<String>? pinned, List<String>? archived}) {
    final ordered = [
      for (final id in _order) ?_rows[id],
      // Rows the order hasn't caught up with yet.
      for (final w in _rows.values)
        if (!_order.contains(w.workspaceId)) w,
    ];
    final next = state.copyWith(
      status: status,
      workspaces: ordered,
      pinnedSessionIds: pinned,
      archivedSessionIds: archived,
    );
    state = ref.read(readListCacheProvider).stamp(next, _identity, _requireClient);
  }

  DshClient get _requireClient => _client ?? (throw const DshTransportException('not connected'));

  /// Registers [path] (an existing absolute folder) or returns the workspace
  /// that already has it.
  Future<Workspace> add(String path) async {
    final r = ref;
    final result = await _requireClient.createWorkspace(path);
    if (!r.mounted) return result.workspace;
    _removed.remove(result.workspace.workspaceId);
    _upsert(result.workspace);
    _emit();
    return result.workspace;
  }

  Future<Workspace> rename(String workspaceId, String title) async {
    final r = ref;
    final w = await _requireClient.renameWorkspace(workspaceId, title);
    if (!r.mounted) return w;
    _upsert(w);
    _emit();
    return w;
  }

  /// Unregisters a workspace; its folder and conversations stay.
  Future<void> remove(String workspaceId) async {
    final r = ref;
    await _requireClient.deleteWorkspace(workspaceId);
    if (!r.mounted) return;
    _drop(workspaceId);
    _emit();
    await ref.read(workspacePrefsProvider.notifier).forget(workspaceId);
  }

  Future<void> pinSession(String sessionId) async {
    final r = ref;
    final pinned = await _requireClient.pinSession(sessionId);
    if (r.mounted) _emit(pinned: pinned);
  }

  Future<void> unpinSession(String sessionId) async {
    final r = ref;
    final pinned = await _requireClient.unpinSession(sessionId);
    if (r.mounted) _emit(pinned: pinned);
  }
}

final workspacesProvider = NotifierProvider<WorkspacesController, WorkspacesState>(WorkspacesController.new);

// ── This phone's view, per host ──────────────────────────────────────────────

class WorkspacePrefs {
  const WorkspacePrefs({
    this.loaded = false,
    this.selected,
    this.pinned = const [],
    this.groups = const {},
    this.recent = const [],
  });

  factory WorkspacePrefs.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    final groups = map['groups'];
    return WorkspacePrefs(
      loaded: true,
      selected: map['selected'] is String ? map['selected'] as String : null,
      pinned: _strings(map['pinned']),
      groups: {
        if (groups is Map)
          for (final MapEntry(:key, :value) in groups.entries)
            if (key is String && value is String && value.trim().isNotEmpty) key: value.trim(),
      },
      recent: _strings(map['recent']),
    );
  }

  static List<String> _strings(Object? v) => v is List ? v.whereType<String>().toList() : const [];

  final bool loaded;

  /// The workspace the drawer shows; null is 全部对话.
  final String? selected;

  /// Pinned workspace ids, most recently pinned first.
  final List<String> pinned;

  /// Workspace id → group name.
  final Map<String, String> groups;

  /// Folders picked recently, newest first.
  final List<String> recent;

  static const maxRecent = 4;

  Map<String, Object?> toJson() => {'selected': ?selected, 'pinned': pinned, 'groups': groups, 'recent': recent};

  WorkspacePrefs copyWith({
    String? Function()? selected,
    List<String>? pinned,
    Map<String, String>? groups,
    List<String>? recent,
  }) => WorkspacePrefs(
    loaded: loaded,
    selected: selected == null ? this.selected : selected(),
    pinned: pinned ?? this.pinned,
    groups: groups ?? this.groups,
    recent: recent ?? this.recent,
  );
}

/// [WorkspacePrefs] of the active host, in shared preferences.
class WorkspacePrefsController extends Notifier<WorkspacePrefs> {
  String _key = '';
  Future<void> _loading = Future.value();

  /// Preferences key of [host]'s view for [agent]. The Agent is part of the
  /// key: each Agent keeps its own selected workspace, pins and groups, so
  /// switching never shows a workspace the target Agent does not have (and
  /// switching back restores exactly what was there).
  static String keyFor(HostRef host, {RemoteAgent agent = RemoteAgent.dsh}) => host.kind == HostKind.relay
      ? 'workspaces.${host.kind.name}.${host.id}.${agent.code}'
      : 'workspaces.${host.kind.name}.${host.id}';

  /// The pre-Agent key (0b995b2 made relay keys Agent-specific). Kept so an
  /// existing relay choice is picked up once and copied to the Agent's key.
  static String legacyKeyFor(HostRef host) => 'workspaces.${host.kind.name}.${host.id}';

  @override
  WorkspacePrefs build() {
    final host = ref.watch(activeHostProvider);
    final agent = host.kind == HostKind.relay
        ? ref.watch(agentSelectionProvider.select((s) => s.forHost(host.id)))
        : RemoteAgent.dsh;
    final key = keyFor(host, agent: agent);
    _key = key;
    final legacyKey = key == legacyKeyFor(host) ? null : legacyKeyFor(host);
    _loading = _load(key, legacyKey);
    return const WorkspacePrefs();
  }

  /// The selected workspace id once the stored view has loaded.
  Future<String?> selection() async {
    await _loading;
    return state.selected;
  }

  Future<void> _load(String key, String? legacyKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var raw = prefs.getString(key);
      var migrated = false;
      if (raw == null && legacyKey != null) {
        final old = prefs.getString(legacyKey);
        if (old != null) {
          raw = old;
          migrated = true;
        }
      }
      final next = raw == null ? const WorkspacePrefs(loaded: true) : WorkspacePrefs.fromJson(jsonDecode(raw));
      // The provider may have been disposed while prefs loaded.
      if (!ref.mounted || _key != key || state.loaded) return;
      if (migrated) {
        // Copy (do not delete) so later Agents still inherit the old choice.
        // Write before publishing the state, and only if the user hasn't
        // picked a workspace in the meantime: otherwise the legacy value
        // would win on disk over their newer choice.
        if (prefs.getString(key) == null) await prefs.setString(key, raw!);
      }
      if (!ref.mounted || _key != key || state.loaded) return;
      state = next;
    } catch (_) {
      // No preferences backend (tests) or a damaged entry: start empty.
      if (ref.mounted && _key == key && !state.loaded) state = const WorkspacePrefs(loaded: true);
    }
  }

  Future<void> _save(WorkspacePrefs next) async {
    state = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(next.toJson()));
    } catch (_) {
      // Kept in memory for this run.
    }
  }

  /// Shows [workspaceId]'s conversations in the drawer (null: all) and starts
  /// new conversations there.
  Future<void> select(String? workspaceId) => _save(state.copyWith(selected: () => workspaceId));

  Future<void> setPinned(String workspaceId, bool pinned) => _save(
    state.copyWith(
      pinned: [
        if (pinned) workspaceId,
        for (final id in state.pinned)
          if (id != workspaceId) id,
      ],
    ),
  );

  /// Puts [workspaceId] in [group] (trimmed); null or blank ungroups it.
  Future<void> setGroup(String workspaceId, String? group) {
    final name = group?.trim() ?? '';
    final groups = Map.of(state.groups)..remove(workspaceId);
    if (name.isNotEmpty) groups[workspaceId] = name;
    return _save(state.copyWith(groups: groups));
  }

  /// Remembers a folder the user picked from.
  Future<void> remember(String folder) => _save(
    state.copyWith(
      recent: [
        folder,
        for (final p in state.recent)
          if (p != folder) p,
      ].take(WorkspacePrefs.maxRecent).toList(),
    ),
  );

  /// Drops everything about a removed workspace.
  Future<void> forget(String workspaceId) => _save(
    state.copyWith(
      selected: () => state.selected == workspaceId ? null : state.selected,
      pinned: [
        for (final id in state.pinned)
          if (id != workspaceId) id,
      ],
      groups: Map.of(state.groups)..remove(workspaceId),
    ),
  );
}

final workspacePrefsProvider = NotifierProvider<WorkspacePrefsController, WorkspacePrefs>(WorkspacePrefsController.new);

// ── Derived views ────────────────────────────────────────────────────────────

/// The workspace the drawer shows and new conversations start in; null for
/// 全部对话 (or while the selection isn't on the host's list).
final selectedWorkspaceProvider = Provider<Workspace?>((ref) {
  final selected = ref.watch(workspacePrefsProvider.select((p) => p.selected));
  if (selected == null) return null;
  return ref.watch(workspacesProvider).byId(selected);
});

/// Id of [selectedWorkspaceProvider], for `session/create`.
final selectedWorkspaceIdProvider = Provider<String?>((ref) => ref.watch(selectedWorkspaceProvider)?.workspaceId);

/// Whether the drawer should wait before listing: a workspace is selected but
/// the host's registry hasn't arrived yet (avoids flashing every conversation).
final workspaceFilterPendingProvider = Provider<bool>((ref) {
  final prefs = ref.watch(workspacePrefsProvider);
  final status = ref.watch(workspacesProvider.select((s) => s.status));
  if (!prefs.loaded) return status != WorkspacesStatus.offline;
  return prefs.selected != null && status == WorkspacesStatus.loading;
});

enum WorkspaceSectionKind { pinned, group, rest }

/// One block of the workspace list: 置顶, a group, or the rest.
class WorkspaceSection {
  const WorkspaceSection(this.kind, this.title, this.items);

  final WorkspaceSectionKind kind;

  /// Null for the untitled block when there are no pins or groups.
  final String? title;
  final List<Workspace> items;
}

/// Pinned first, then each group (in the order its first member appears),
/// then the rest — the host's order inside each block.
List<WorkspaceSection> workspaceSections(List<Workspace> workspaces, WorkspacePrefs prefs) {
  final pinnedIds = prefs.pinned.toSet();
  final pinned = [
    for (final w in workspaces)
      if (pinnedIds.contains(w.workspaceId)) w,
  ];
  final groups = <String, List<Workspace>>{};
  final rest = <Workspace>[];
  for (final w in workspaces) {
    if (pinnedIds.contains(w.workspaceId)) continue;
    final group = prefs.groups[w.workspaceId];
    if (group == null) {
      rest.add(w);
    } else {
      groups.putIfAbsent(group, () => []).add(w);
    }
  }
  final titled = pinned.isNotEmpty || groups.isNotEmpty;
  return [
    if (pinned.isNotEmpty) WorkspaceSection(WorkspaceSectionKind.pinned, appL10n.commonPin, pinned),
    for (final MapEntry(:key, :value) in groups.entries) WorkspaceSection(WorkspaceSectionKind.group, key, value),
    if (rest.isNotEmpty) WorkspaceSection(WorkspaceSectionKind.rest, titled ? appL10n.commonOther : null, rest),
  ];
}

final workspaceSectionsProvider = Provider<List<WorkspaceSection>>((ref) {
  return workspaceSections(ref.watch(workspacesProvider).workspaces, ref.watch(workspacePrefsProvider));
});

/// Group names in use, in list order.
final workspaceGroupsProvider = Provider<List<String>>((ref) {
  final prefs = ref.watch(workspacePrefsProvider);
  final names = <String>{};
  for (final w in ref.watch(workspacesProvider).workspaces) {
    if (prefs.groups[w.workspaceId] case final g?) names.add(g);
  }
  return names.toList();
});

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Title the official client shows for the first-use workspace it creates
/// (`DEFAULT_WORKSPACE_DIRECTORY`), in Chinese.
String get defaultWorkspaceTitle => appL10n.stateDefaultWorkspace;

/// A workspace's display title: the stored title, the localized default for
/// the first-use workspace, else the folder's name.
String workspaceTitle(Workspace w) {
  final title = w.title.trim();
  if (title == 'default-workspace') return defaultWorkspaceTitle;
  if (title.isNotEmpty) return title;
  final parts = w.path.split('/').where((p) => p.isNotEmpty);
  return parts.isEmpty ? w.path : parts.last;
}

/// Conversations of [w] among [visible] (the drawer's list: no archived,
/// blank or subagent conversations).
int workspaceConversationCount(Workspace w, Iterable<String> visible) {
  final members = w.sessionIds.toSet();
  return visible.where(members.contains).length;
}

/// Normalizes a Host folder for comparison: both separators are accepted and
/// only the root keeps its trailing slash.
String _folderKey(String path) {
  var value = path.trim().replaceAll('\\', '/');
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/// The innermost workspace whose folder is [cwd] or contains it. Ties cannot
/// happen after normalization, but the longest folder wins so a nested
/// workspace beats its parent.
Workspace? workspaceForFolder(Iterable<Workspace> workspaces, String? cwd) {
  final folder = cwd == null ? '' : _folderKey(cwd);
  if (folder.isEmpty) return null;
  Workspace? best;
  var bestLength = -1;
  for (final w in workspaces) {
    final candidate = _folderKey(w.path);
    if (candidate.isEmpty || candidate.length <= bestLength) continue;
    final prefix = candidate.endsWith('/') ? candidate : '$candidate/';
    if (folder == candidate || folder.startsWith(prefix)) {
      best = w;
      bestLength = candidate.length;
    }
  }
  return best;
}

/// cwd a conversation created now would use. Shared with the chip so its
/// label names the same folder the resolver uses.
String? newChatCwd(HostConnection? conn) => conn == null
    ? null
    : conn.isLocal
        ? LocalPaths.workspace
        : conn.workingDirectory;

/// The workspace a new conversation would start in, from the registry, the
/// drawer's [selected] id and [cwd]. A live selection wins, then the longest
/// folder match, then the Host's first-use `default-workspace` (relay has no
/// cwd, so without that every chat would land in the newest workspace), then
/// the registry's first entry.
Workspace? newChatWorkspaceFor(WorkspacesState registry, String? selected, String? cwd) {
  if (selected != null) {
    final known = registry.byId(selected);
    if (known != null) return known;
    // Still loading: the stored choice is all there is to go on. The caller
    // keeps the raw id until the Host publishes its list.
    if (!registry.ready) return null;
    // Removed from the Host since: infer below instead of starting ungrouped.
  }
  final match = workspaceForFolder(registry.workspaces, cwd);
  if (match != null) return match;
  for (final w in registry.workspaces) {
    if (w.title == 'default-workspace') return w;
  }
  return registry.workspaces.isEmpty ? null : registry.workspaces.first;
}

/// How long a new conversation waits for the registry baseline before giving
/// up rather than silently creating an ungrouped session.
@visibleForTesting
Duration newChatBaselineTimeout = const Duration(seconds: 6);

/// The workspace id for a new conversation. Null only when there is nothing
/// to infer from (no selection, no registry); an ungrouped session is correct
/// only then.
Future<String?> workspaceForNewSession(Ref ref, {String? cwd}) async {
  final selected = await ref.read(workspacePrefsProvider.notifier).selection();
  if (selected != null) {
    final known = ref.read(workspacesProvider).byId(selected);
    // A live choice already is a workspaceId: no need to wait for the list.
    if (known != null) return known.workspaceId;
  }
  // A fresh connect (or an Agent switch) rebuilds the registry as `loading`
  // with no rows. Reading that snapshot is the "未分组" race.
  await ref.read(workspacesProvider.notifier).baseline.timeout(newChatBaselineTimeout, onTimeout: () {});
  final registry = ref.read(workspacesProvider);
  if (registry.status == WorkspacesStatus.loading) {
    // Still no baseline: `session/create` without a workspaceId would put
    // the conversation in a folder nobody can see in the drawer.
    throw StateError('workspace registry is still loading');
  }
  if (selected != null && !registry.ready) return selected;
  return newChatWorkspaceFor(registry, selected, cwd)?.workspaceId;
}

/// Title for the new-chat chip when nothing is selected: the workspace the
/// next conversation will actually start in, so the label cannot disagree
/// with `session/create`.
final newChatWorkspaceTitleProvider = Provider<String?>((ref) {
  final registry = ref.watch(workspacesProvider);
  final selected = ref.watch(workspacePrefsProvider.select((p) => p.selected));
  final conn = ref.watch(activeConnectionProvider).value;
  if (!registry.ready) return null;
  final target = newChatWorkspaceFor(registry, selected, newChatCwd(conn));
  return target == null ? null : workspaceTitle(target);
});

/// Creates a conversation in [workspaceId] when the caller picked one
/// (selected or inferred), else in [cwd] (null lets the host pick). Falls
/// back to [cwd] if the workspace was removed in the meantime.
Future<SessionCreated> createSessionInWorkspace(DshClient client, String? workspaceId, {String? cwd}) async {
  if (workspaceId == null) return client.createSession(cwd: cwd);
  try {
    return await client.createSession(workspaceId: workspaceId);
  } on DshRemoteException catch (e) {
    if (e.code != WorkspaceErrors.notFound) rethrow;
    return client.createSession(cwd: cwd);
  }
}
