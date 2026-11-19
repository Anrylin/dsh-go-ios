/// Virtual `$events`, `workspace/follow`, `session/control` and `job/*` streams
/// for the Codex virtual Harness. Port of
/// `dist/codex/virtual-event-carrier.js` (88 lines).
library;

import 'codex_catalog.dart';
import 'codex_contract.dart';
import 'codex_values.dart';

abstract interface class CodexEventContext {
  String get hostDeviceId;
  String? get selectedWorkspaceId;
  Map<String, Object?> get pendingApprovals;
  Set<CodexValueQueue<Map<String, Object?>>> get workspaceStreams;
  Set<CodexValueQueue<Map<String, Object?>>> get controlStreams;
  Map<String, CodexValueQueue<Map<String, Object?>>> get eventStreams;

  Future<CodexCatalog> refreshCatalog();
  Future<CodexCatalog> currentCatalog();
  Future<void> respondApproval(String requestHandle, String decision);
}

class CodexEventCarrier {
  CodexEventCarrier(this.context);

  final CodexEventContext context;

  Stream<Map<String, Object?>> workspaceFollow() async* {
    final queue = CodexValueQueue<Map<String, Object?>>();
    context.workspaceStreams.add(queue);
    final catalog = await context.refreshCatalog();
    final archivedIds = catalog.sessions
        .where((session) => session['archived'] == true)
        .map((session) => codexString(session['id']) ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    queue.push(<String, Object?>{
      'type': 'baseline',
      'value': <String, Object?>{
        'items': codexNativeVisibleWorkspaces(catalog, context.selectedWorkspaceId).map(codexNativeWorkspace).toList(),
        'archivedSessionIds': archivedIds,
        'pinnedSessionIds': <Object?>[],
      },
    });
    yield* queue.iterate(() => context.workspaceStreams.remove(queue));
  }

  Stream<Map<String, Object?>> sessionControl() async* {
    final queue = CodexValueQueue<Map<String, Object?>>();
    context.controlStreams.add(queue);
    queue.push(<String, Object?>{
      'type': 'baseline',
      'value': <String, Object?>{'queues': <String, Object?>{}, 'jobs': <String, Object?>{}, 'projections': <String, Object?>{}},
    });
    yield* queue.iterate(() => context.controlStreams.remove(queue));
  }

  /// Background jobs belong to the Host Harness session, not a Codex virtual
  /// Workspace. An authoritative empty roster keeps the native Session header
  /// from tearing down on a terminal `method-not-found`.
  Stream<Map<String, Object?>> emptyJobStream(String endpoint) async* {
    final queue = CodexValueQueue<Map<String, Object?>>();
    if (endpoint == 'job/list') {
      queue.push(<String, Object?>{'type': 'rows', 'jobs': <Object?>[]});
    }
    yield* queue.iterate(queue.close);
  }

  Stream<Map<String, Object?>> remoteEvents() async* {
    final queue = CodexValueQueue<Map<String, Object?>>();
    final clientId = 'codex-events:${context.hostDeviceId}:${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    context.eventStreams[clientId] = queue;
    final catalog = await context.currentCatalog();
    final workspaces = catalog.workspaces;
    final home = workspaces.isEmpty ? '/' : (codexString(workspaces.first['path']) ?? '/');
    queue.push(<String, Object?>{
      'type': 'ready',
      'clientId': clientId,
      'host': <String, Object?>{'home': home},
    });
    yield* queue.iterate(() => context.eventStreams.remove(clientId));
  }

  void emitRemoteEvent(String event, List<Object?> args) {
    for (final queue in context.eventStreams.values) {
      queue.push(<String, Object?>{'type': 'emit', 'event': event, 'args': args});
    }
  }

  void emitApproval(Map<String, Object?> input) {
    for (final queue in context.eventStreams.values) {
      queue.push(<String, Object?>{
        'type': 'waterfall',
        'event': 'approval/request',
        'eventId': input['eventId'],
        'agentId': input['agentId'],
        'request': input['request'],
      });
    }
  }

  Future<void> answerRemoteEvent(Map<String, Object?> args) async {
    final eventId = codexString(args['eventId']);
    if (eventId == null) throw CodexValueError('The CodeX approval result is missing its event id.');
    final pending = context.pendingApprovals.remove(eventId);
    if (pending == null) return;
    final outcome = codexRecord(args['outcome']);
    final decision = outcome['kind'] == 'result' && outcome['value'] == 'allowed-once'
        ? 'accept'
        : outcome['kind'] == 'result' && outcome['value'] == 'cancelled'
            ? 'cancel'
            : 'decline';
    final requestHandle = codexString(codexRecord(pending)['requestHandle']);
    if (requestHandle == null) return;
    await context.respondApproval(requestHandle, decision);
  }

  void publishProjection(String sessionId, String key, Object? value, int seq) {
    // 0.2.2 sends per-event `changes`; keep the legacy key/value fields so
    // older official clients keep applying the same frame.
    for (final queue in context.controlStreams) {
      queue.push(<String, Object?>{
        'type': 'projection',
        'sessionId': sessionId,
        'seq': seq,
        'key': key,
        'value': value,
        'changes': <Object?>[<String, Object?>{'key': key, 'val': value}],
      });
    }
  }
}
