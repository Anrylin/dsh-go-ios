/// Virtual workspace/session catalog for AGY ACP sessions.
///
/// Native ids are bare conversation ids on the ACP wire; the virtual Harness
/// exposes them as `acp:<conversation_id>` so the existing DSH Session
/// controllers can open them without any new UI.
library;

import '../util/bytes.dart';
import 'agy_api.dart';
import 'agy_values.dart';

class AgySession {
  AgySession({
    required this.id,
    required this.nativeId,
    required this.cwd,
    this.title = 'Untitled Session',
    this.createdAt = 0,
    this.updatedAt = 0,
    this.running = false,
    this.blank = false,
    List<Object?>? events,
    JsonMap? selectedModel,
    String? permissionPreset,
  })  : events = events ?? <Object?>[],
        selectedModel = selectedModel ?? const <String, Object?>{},
        permissionPreset = permissionPreset;

  final String id;
  final String nativeId;
  final String cwd;
  String title;
  int createdAt;
  int updatedAt;
  bool running;
  bool blank;
  List<Object?> events;
  JsonMap selectedModel;
  String? permissionPreset;

  JsonMap get sessionView => <String, Object?>{
        'id': id,
        'title': title,
        'cwd': cwd,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'running': running,
        'blank': blank,
        'model': agyString(selectedModel['model']),
        if (selectedModel.isNotEmpty) 'modelSelection': selectedModel,
        if (permissionPreset != null) 'permissionPreset': permissionPreset,
      };
}

class AgyWorkspace {
  AgyWorkspace({
    required this.id,
    required this.path,
    required this.title,
    List<String>? sessionIds,
    this.createdAt = 0,
    this.updatedAt = 0,
  }) : sessionIds = sessionIds ?? <String>[];

  final String id;
  final String path;
  final String title;
  final List<String> sessionIds;
  int createdAt;
  int updatedAt;

  JsonMap get workspaceView {
    sessionIds.sort();
    return <String, Object?>{
      'workspaceId': id,
      'id': id,
      'path': path,
      'title': title,
      'sessionIds': List<String>.from(sessionIds),
      'sessionCount': sessionIds.length,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }
}

class AgyCatalog {
  AgyCatalog(this.workspaces, this.sessions);

  final List<AgyWorkspace> workspaces;
  final List<AgySession> sessions;

  final Map<String, AgySession> byId = <String, AgySession>{};

  void index() {
    byId.clear();
    for (final session in sessions) {
      byId[session.id] = session;
    }
  }
}

JsonMap agyWorkspaceView(String path, [String? title]) {
  final now = agyNowMs();
  return <String, Object?>{
    'workspaceId': agyWorkspaceId(path),
    'id': agyWorkspaceId(path),
    'path': path,
    'title': title ?? agyPathLeaf(path),
    'sessionIds': <Object?>[],
    'sessionCount': 0,
    'createdAt': now,
    'updatedAt': now,
  };
}

String agyPathLeaf(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty).toList();
  return parts.isEmpty ? path : parts.last;
}

int agyTimestamp(Object? value) {
  final milliseconds = agyInt(value);
  if (milliseconds != null) return milliseconds;
  final text = agyString(value);
  if (text == null || text.isEmpty) return 0;
  return DateTime.tryParse(text)?.millisecondsSinceEpoch ?? 0;
}

String? agySessionNativeId(Object? value) {
  final map = agyMap(value);
  final address = agyMap(map['address']);
  final candidates = <Object?>[
    map['sessionId'],
    map['conversationId'],
    map['id'],
    address['sessionId'],
    address['childSessionId'],
  ];
  for (final candidate in candidates) {
    final text = agyString(candidate);
    if (text != null && text.isNotEmpty) return agyNativeId(text);
  }
  return null;
}

/// Loads the workspace/session catalog from the Host. AGY discovery failures
/// degrade to an empty catalog (matching the official client's AGY branch).
Future<AgyCatalog> agyLoadCatalog(AgyClient client) async {
  final workspaceViews = await client.listWorkspaces();
  final workspaces = <AgyWorkspace>[];
  final sessions = <AgySession>[];
  final seenSessions = <String>{};
  final now = agyNowMs();

  for (final view in workspaceViews) {
    final path = agyString(view['path']) ?? agyString(view['cwd']);
    if (path == null || path.isEmpty) continue;
    final title = agyString(view['title']) ?? path;
    final workspace = AgyWorkspace(
      id: agyString(view['id']) ?? agyString(view['workspaceId']) ?? agyWorkspaceId(path),
      path: path,
      title: title,
      createdAt: agyTimestamp(view['createdAt']) == 0 ? now : agyTimestamp(view['createdAt']),
      updatedAt: agyTimestamp(view['updatedAt']) == 0 ? now : agyTimestamp(view['updatedAt']),
    );
    final listed = await client.listSessions(path, limit: 100);
    for (final value in listed) {
      final session = _sessionFromHost(value, path, workspace.id, now);
      if (session == null || !seenSessions.add(session.id)) continue;
      sessions.add(session);
      workspace.sessionIds.add(session.id);
    }
    workspaces.add(workspace);
  }

  if (workspaces.isEmpty) {
    final paths = <String>{};
    for (final view in workspaceViews) {
      final path = agyString(view['path']) ?? agyString(view['cwd']);
      if (path != null && path.isNotEmpty) paths.add(path);
    }
    for (final path in paths) {
      workspaces.add(AgyWorkspace(id: agyWorkspaceId(path), path: path, title: path, createdAt: now, updatedAt: now));
    }
  }

  final catalog = AgyCatalog(workspaces, sessions);
  catalog.index();
  return catalog;
}

AgySession? _sessionFromHost(Object? value, String path, String workspaceId, int now) {
  final nativeId = agySessionNativeId(value);
  if (nativeId == null) return null;
  final map = agyMap(value);
  final created = agyTimestamp(map['createdAt']);
  final updated = agyTimestamp(map['updatedAt']);
  final title = agyString(map['title']) ?? agyString(map['name']) ?? 'Untitled Session';
  return AgySession(
    id: agyVirtualId(nativeId),
    nativeId: nativeId,
    cwd: agyString(map['cwd']) ?? path,
    title: title,
    createdAt: created == 0 ? now : created,
    updatedAt: updated == 0 ? (created == 0 ? now : created) : updated,
    running: agyBool(map['running']),
    selectedModel: agyMap(map['modelSelection']),
    permissionPreset: agyString(map['permissionPreset']),
  );
}

AgySession agyRegisterSession(
  AgyCatalog catalog,
  AgyWorkspace workspace,
  String nativeId, {
  String? title,
  JsonMap? selectedModel,
  String? permissionPreset,
}) {
  final virtualId = agyVirtualId(nativeId);
  final existing = catalog.byId[virtualId];
  if (existing != null) {
    if (title != null) existing.title = title;
    return existing;
  }
  final now = agyNowMs();
  final session = AgySession(
    id: virtualId,
    nativeId: nativeId,
    cwd: workspace.path,
    title: title ?? 'Untitled Session',
    createdAt: now,
    updatedAt: now,
    selectedModel: selectedModel,
    permissionPreset: permissionPreset,
  );
  catalog.sessions.add(session);
  catalog.byId[virtualId] = session;
  if (!workspace.sessionIds.contains(virtualId)) workspace.sessionIds.add(virtualId);
  workspace.updatedAt = now;
  return session;
}
