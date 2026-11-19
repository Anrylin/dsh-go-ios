/// Event-carrier side of the AGY virtual Harness: workspace/session/control
/// streams plus approval waterfall events.
library;

import '../util/bytes.dart';
import 'agy_catalog.dart';
import 'agy_values.dart';

class AgyEventCarrier {
  final Set<AgyValueQueue<JsonMap>> _workspaceStreams = <AgyValueQueue<JsonMap>>{};
  final Set<AgyValueQueue<JsonMap>> _controlStreams = <AgyValueQueue<JsonMap>>{};
  final Map<String, AgyValueQueue<JsonMap>> _eventStreams = <String, AgyValueQueue<JsonMap>>{};
  final Map<String, String> _pendingApprovals = <String, String>{};
  String? _home;
  int _projectionSeq = 0;
  int _eventSeq = 0;

  bool get isEmpty => _workspaceStreams.isEmpty && _controlStreams.isEmpty && _eventStreams.isEmpty;

  void setSelectedWorkspace(String? home) {
    _home = home;
  }

  /// The workspace id (or legacy path) currently selected on the UI, as set by
  /// [setSelectedWorkspace]; `null` when no AGY workspace is selected.
  String? get selectedWorkspace => _home;

  int nextProjectionSeq() {
    _projectionSeq += 1;
    return _projectionSeq;
  }

  Stream<JsonMap> workspaceFollow(AgyCatalog catalog) {
    final queue = AgyValueQueue<JsonMap>();
    _workspaceStreams.add(queue);
    queue.push(<String, Object?>{
      'type': 'baseline',
      'value': <String, Object?>{
        'items': catalog.workspaces.map((workspace) => workspace.workspaceView).toList(),
        'archivedSessionIds': <Object?>[],
        'pinnedSessionIds': <Object?>[],
      },
    });
    return queue.iterate(() => _workspaceStreams.remove(queue));
  }

  Stream<JsonMap> sessionControl() {
    final queue = AgyValueQueue<JsonMap>();
    _controlStreams.add(queue);
    queue.push(<String, Object?>{
      'type': 'baseline',
      'value': const <String, Object?>{'projections': <Object?>[]},
    });
    return queue.iterate(() => _controlStreams.remove(queue));
  }

  Stream<JsonMap> emptyJobStream(String endpoint) {
    final queue = AgyValueQueue<JsonMap>();
    if (endpoint == 'job/list') {
      queue.push(<String, Object?>{'type': 'rows', 'jobs': <Object?>[]});
    }
    return queue.iterate(() {});
  }

  Stream<JsonMap> remoteEvents() {
    _eventSeq += 1;
    final clientId = 'cursor-events:${agyNowMs()}:$_eventSeq';
    final queue = AgyValueQueue<JsonMap>();
    _eventStreams[clientId] = queue;
    queue.push(<String, Object?>{
      'type': 'ready',
      'clientId': clientId,
      'host': <String, Object?>{'home': _home ?? '/'},
    });
    return queue.iterate(() => _eventStreams.remove(clientId));
  }

  void emitRemoteEvent(String event, Object? args) {
    for (final queue in _eventStreams.values.toList(growable: false)) {
      queue.push(<String, Object?>{
        'type': 'emit',
        'event': event,
        'args': args ?? <Object?>[],
      });
    }
  }

  /// Hosts a pending ACP approval and emits the existing DSH waterfall card.
  void emitApproval(
    String eventId,
    String requestHandle,
    JsonMap request, {
    String? agentId,
    String? sessionId,
  }) {
    _pendingApprovals[eventId] = requestHandle;
    for (final queue in _eventStreams.values.toList(growable: false)) {
      queue.push(<String, Object?>{
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': eventId,
        'agentId': agentId ?? agyBackend,
        'sessionId': sessionId,
        'request': request,
      });
    }
  }

  /// Resolves an approval card without leaking request handles to the UI.
  ({String handle, String decision})? resolveApproval(Object? eventId, Object? outcome) {
    final id = agyString(eventId);
    if (id == null) return null;
    final handle = _pendingApprovals.remove(id);
    if (handle == null) return null;
    final result = agyMap(outcome);
    if (agyString(result['kind']) == 'result') {
      final value = agyString(result['value']);
      if (value == 'allowed-once' || value == 'allowed_always') return (handle: handle, decision: 'allow-once');
      if (value == 'cancelled') return (handle: handle, decision: 'cancel');
    }
    return (handle: handle, decision: 'reject-once');
  }

  void publishProjection(String sessionId, String key, Object? value, [int? requestedSeq]) {
    final seq = requestedSeq ?? nextProjectionSeq();
    for (final queue in _controlStreams.toList(growable: false)) {
      queue.push(<String, Object?>{
        'type': 'projection',
        'sessionId': sessionId,
        'seq': seq,
        'key': key,
        'value': value,
        'asOfSeq': seq,
        'changes': <Object?>[<String, Object?>{'key': key, 'val': value}],
      });
    }
  }

  void publishWorkspaceBaseline(AgyCatalog catalog) {
    for (final queue in _workspaceStreams.toList(growable: false)) {
      for (final workspace in catalog.workspaces) {
        queue.push(<String, Object?>{'type': 'upsert', 'workspace': workspace.workspaceView});
      }
      queue.push(<String, Object?>{'type': 'archived', 'archivedSessionIds': <Object?>[]});
    }
  }

  void close() {
    for (final queue in _workspaceStreams.toList(growable: false)) queue.close();
    for (final queue in _controlStreams.toList(growable: false)) queue.close();
    for (final queue in _eventStreams.values.toList(growable: false)) queue.close();
    _workspaceStreams.clear();
    _controlStreams.clear();
    _eventStreams.clear();
    _pendingApprovals.clear();
  }
}
