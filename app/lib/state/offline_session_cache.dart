// Offline conversation list. The Drawer must never turn into an endless
// skeleton just because a tunnel is briefly unavailable: the last confirmed
// session list is kept in the App's private support directory and is painted
// read-only before (or instead of) a live read.

import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart' show SessionProjections, SessionSummary;
import 'package:path_provider/path_provider.dart';

import 'read_list_data.dart';

final class OfflineSessionsSnapshot {
  const OfflineSessionsSnapshot({
    required this.sessions,
    required this.bots,
    required this.workspaceVersion,
    required this.scoped,
    required this.workspaceLabel,
    required this.savedAt,
  });

  final List<SessionSummary> sessions;
  final List<SessionSummary> bots;
  final String? workspaceVersion;
  final bool scoped;
  final String? workspaceLabel;
  final DateTime savedAt;

  CachedSessions toCached() => CachedSessions(
        sessions: sessions,
        bots: bots,
        workspaceVersion: workspaceVersion,
        scoped: scoped,
        workspaceLabel: workspaceLabel,
      );
}

/// A tiny best-effort store: one JSON file, one in-memory map, no credentials
/// and no write commands. A failed read is a miss; a failed write is a no-op.
class OfflineSessionCache {
  OfflineSessionCache({this.directory});

  static final instance = OfflineSessionCache();

  Directory? directory;
  bool _loaded = false;
  final Map<String, OfflineSessionsSnapshot> _snapshots = {};
  Future<void>? _writing;

  /// Call once before the first frame, alongside the other on-device paths.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final resolved = directory ?? await _supportDirectory();
    directory = resolved;
    await _read(resolved);
  }

  static Future<Directory> _supportDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/offline-session-cache');

  OfflineSessionsSnapshot? read(String hostId, String workspace) => _snapshots[_key(hostId, workspace)];

  /// Remember a confirmed projection. The caller has already applied the
  /// display bounds in [CachedSessions], so this only serialises that result.
  void remember({
    required String hostId,
    required String workspace,
    required CachedSessions sessions,
    DateTime? now,
  }) {
    final key = _key(hostId, workspace);
    final snapshot = OfflineSessionsSnapshot(
      sessions: sessions.sessions,
      bots: sessions.bots,
      workspaceVersion: sessions.workspaceVersion,
      scoped: sessions.scoped,
      workspaceLabel: sessions.workspaceLabel,
      savedAt: now ?? DateTime.now(),
    );
    _snapshots[key] = snapshot;
    final target = directory;
    if (target == null) return;
    _writing = (_writing ?? Future<void>.value()).then((_) => _write(target));
  }

  Future<void> clear() async {
    _snapshots.clear();
    final target = directory;
    if (target == null) return;
    await _writing;
    try {
      if (await target.exists()) await target.delete(recursive: true);
    } catch (_) {
      // Nothing to drop.
    }
  }

  static String _key(String hostId, String workspace) =>
      '${hostId.length}:$hostId|${workspace.length}:$workspace';

  Future<void> _read(Directory directory) async {
    try {
      final file = File('${directory.path}/sessions.json');
      if (!await file.exists() || await file.length() > 4 * 1024 * 1024) return;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) return;
      for (final entry in decoded.entries) {
        final snapshot = _decode(entry.value);
        if (snapshot != null) _snapshots[entry.key] = snapshot;
      }
    } catch (_) {
      // A damaged file means no offline list, never a crash.
    }
  }

  Future<void> _write(Directory directory) async {
    File? temporary;
    try {
      await directory.create(recursive: true);
      final file = File('${directory.path}/sessions.json');
      temporary = File('${file.path}.tmp');
      final payload = <String, Object?>{
        for (final entry in _snapshots.entries) entry.key: _encode(entry.value),
      };
      final bytes = utf8.encode(jsonEncode(payload));
      if (bytes.length > 4 * 1024 * 1024) return;
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      // A cache write never fails the conversation it describes.
    } finally {
      try {
        if (temporary != null && await temporary.exists()) await temporary.delete();
      } catch (_) {}
    }
  }

  static Map<String, Object?> _encode(OfflineSessionsSnapshot snapshot) => {
        'workspaceVersion': snapshot.workspaceVersion,
        'scoped': snapshot.scoped,
        'workspaceLabel': snapshot.workspaceLabel,
        'savedAt': snapshot.savedAt.millisecondsSinceEpoch,
        'sessions': [for (final row in snapshot.sessions) _encodeRow(row)],
        'bots': [for (final row in snapshot.bots) _encodeRow(row)],
      };

  static Map<String, Object?> _encodeRow(SessionSummary row) => {
        'id': row.sessionId,
        'title': row.title,
        'updated': row.updatedAt.millisecondsSinceEpoch,
      };

  static OfflineSessionsSnapshot? _decode(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final savedAt = value['savedAt'];
    final ms = savedAt is int ? savedAt : 0;
    return OfflineSessionsSnapshot(
      sessions: _decodeRows(value['sessions']),
      bots: _decodeRows(value['bots']),
      workspaceVersion: value['workspaceVersion'] as String?,
      scoped: value['scoped'] == true,
      workspaceLabel: value['workspaceLabel'] as String?,
      savedAt: DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }

  static List<SessionSummary> _decodeRows(Object? value) {
    if (value is! List<Object?>) return const [];
    return List.unmodifiable([
      for (final item in value)
        if (item is Map<String, Object?>) _decodeRow(item),
    ]);
  }

  static SessionSummary _decodeRow(Map<String, Object?> value) {
    final id = value['id'] as String? ?? '';
    final title = value['title'] as String?;
    final ms = value['updated'] is int ? value['updated'] as int : 0;
    return SessionSummary(
      sessionId: id,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(ms),
      running: false,
      blank: false,
      agentAvailable: false,
      projections: SessionProjections(-1, <String, Object?>{'title': title}),
    );
  }
}
