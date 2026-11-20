/// Plugin-owned virtual Harness for Codex Remote, ported from the official
/// client bundle's `dist/codex/virtual-harness.js` (925 lines).
///
/// The bridge projects Codex `thread/*` and `turn/*` data at the existing DSH
/// carrier boundary. No new UI, no new slash commands, and no history-import
/// plugin are involved: native DSH Workspace/Session controllers keep using the
/// same endpoints, but receive Codex-shaped data.
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../agent/remote_agent.dart' show dshOnlyRemoteEndpoints;
import '../carrier/tunnel_carrier.dart';
import '../util/bytes.dart';
import 'codex_api.dart';
import 'codex_catalog.dart';
import 'codex_contract.dart';
import 'codex_events.dart';
import 'codex_history.dart';
import 'codex_history_cache.dart';
import 'codex_image_codec.dart';
import 'codex_live.dart';
import 'codex_permissions.dart';
import 'codex_values.dart';

/// Mirrors `harnessSessionGeneration()` in the official bundle: Hosts 0.1.5+
/// and 0.2.x use the v3 event schema; everything else stays on legacy.
String codexHarnessSessionGeneration(String? version) {
  if (version == null) return 'legacy';
  final match = RegExp(r'^(?:dsh-)?v?(\d+)\.(\d+)\.(\d+)(?:-|$)').firstMatch(version.trim());
  if (match == null) return 'legacy';
  final major = int.tryParse(match.group(1) ?? '') ?? -1;
  final minor = int.tryParse(match.group(2) ?? '') ?? -1;
  final patch = int.tryParse(match.group(3) ?? '') ?? -1;
  return major == 0 && ((minor == 1 && patch >= 5) || minor == 2) ? 'v3' : 'legacy';
}

/// The virtual Harness itself. It owns the Codex App Server API, the catalog
/// and model caches, the history cache and the stream/event projections.
class CodexVirtualHarness implements CodexLiveContext, CodexEventContext {
  CodexVirtualHarness({
    required this.hostCarrier,
    required this.remote,
    required this.hostDeviceId,
  }) : sessionGeneration = codexHarnessSessionGeneration(remote?.hostVersion ?? hostCarrier.hostVersion) {
    events = CodexEventCarrier(this);
    live = CodexLiveProjection(this);
  }

  /// The underlying carrier (the original `RemoteTunnelCarrier`).
  final DshCarrier hostCarrier;

  /// Capability advertised only when the Host has the Codex App Server plugin.
  static const String codexAppCapability = 'codex.appserver.v1';

  /// Kept for capability/session discovery and the `sessions` reconnect stream.
  final RemoteTunnelCarrier? remote;

  @override
  final String hostDeviceId;

  /// `v3` for recent Host versions, `legacy` for older ones. Refreshed on
  /// physical session reconnect (a new `harness.transport.describe`).
  @override
  String sessionGeneration;

  late final CodexEventCarrier events;
  late final CodexLiveProjection live;

  final CodexSessionHistoryCache historyCache = CodexSessionHistoryCache();

  CodexAppApi? _api;
  Future<CodexAppApi>? _apiFuture;

  @override
  bool closed = false;

  CodexCatalog? catalog;
  int _catalogLoadedAt = 0;
  Future<CodexCatalog>? _catalogFuture;

  CodexModelDirectory? modelDirectory;
  Future<CodexModelDirectory>? _modelFuture;

  int _lastProjectionSeq = 0;
  int _commandSeq = 0;

  @override
  String? selectedWorkspaceId;

  String? lastOpenedSessionId;

  /// Observes the exact payload a client sent to a virtual endpoint. Production
  /// leaves this unset; tests use it to prove what `SessionApi` actually put on
  /// the wire (virtual endpoints never reach `codex.app.call`).
  void Function(String endpoint, Map<String, Object?> payload)? onDispatch;

  @override
  final Map<String, Object?> pendingRequestIds = <String, Object?>{};

  @override
  final Map<String, Object?> pendingApprovals = <String, Object?>{};

  @override
  final Map<String, Object?> imageAttachments = <String, Object?>{};

  /// `sessionId -> selection` captured from history/model/fork/create.
  @override
  final Map<String, Object?> selectedModels = <String, Object?>{};

  final Map<String, String> _selectedPermissions = <String, String>{};

  final Map<String, JsonMap> pendingThreads = <String, JsonMap>{};
  final Set<String> blankThreads = <String>{};

  @override
  final Set<CodexValueQueue<Map<String, Object?>>> workspaceStreams = <CodexValueQueue<Map<String, Object?>>>{};

  @override
  final Set<CodexValueQueue<Map<String, Object?>>> controlStreams = <CodexValueQueue<Map<String, Object?>>>{};

  @override
  final Map<String, CodexValueQueue<Map<String, Object?>>> eventStreams = <String, CodexValueQueue<Map<String, Object?>>>{};

  /// Lazily created once per physical session. A reconnect disposes it.
  bool get hasCodexApp => remote?.session?.capabilities.contains(codexAppCapability) ?? false;

  Future<CodexAppApi> get api {
    final existing = _api;
    if (existing != null) return Future<CodexAppApi>.value(existing);
    return _apiFuture ??= _createApi();
  }

  Future<CodexAppApi> _createApi() async {
    final session = remote?.session;
    if (session == null || session.isClosed) {
      throw const CodexValueError('The CodeX Remote session is not connected.');
    }
    if (!session.capabilities.contains(codexAppCapability)) {
      throw const CodexValueError('The Host does not expose the CodeX App Server.', 'FEATURE_NOT_SUPPORTED');
    }
    // The bundled virtual Harness uses `new CodexRemoteClient(core)` with
    // historyPreview disabled, so no preview-only RPC is emitted here.
    final created = CodexAppApi(session.rpc, previewHistory: false);
    _api = created;
    _apiFuture = null;
    return created;
  }

  /// Called by the carrier whenever the tunnel opens a fresh Host session.
  void onSessionReconnected() {
    sessionGeneration = codexHarnessSessionGeneration(remote?.hostVersion ?? hostCarrier.hostVersion);
    final previous = _api;
    _api = null;
    _apiFuture = null;
    if (previous != null) unawaited(previous.dispose());
    catalog = null;
    _catalogFuture = null;
    modelDirectory = null;
    _modelFuture = null;
    historyCache.clear();
  }

  int get _nowMs => DateTime.now().millisecondsSinceEpoch;

  @override
  int nextProjectionSeq() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastProjectionSeq = now > _lastProjectionSeq ? now : _lastProjectionSeq + 1;
    return _lastProjectionSeq;
  }

  @override
  void publishProjection(String sessionId, String key, Object? value, int seq) =>
      events.publishProjection(sessionId, key, value, seq);

  @override
  void emitRemoteEvent(String type, List<Object?> payload) => events.emitRemoteEvent(type, payload);

  @override
  void emitApproval(Map<String, Object?> event) => events.emitApproval(event);

  @override
  void invalidateThreadHistory(String threadId) => historyCache.invalidateThread(threadId);

  @override
  Future<CodexStreamHandle> subscribe(String threadId, void Function(Map<String, Object?> frame) onFrame) async =>
      (await api).subscribe(threadId, onFrame);

  @override
  Future<void> respondApproval(String requestHandle, String decision) async {
    final client = await api;
    final codexDecision = switch (decision) {
      'accept' => CodexApprovalDecision.accept,
      'cancel' => CodexApprovalDecision.cancel,
      _ => CodexApprovalDecision.decline,
    };
    await client.respond(requestHandle, codexDecision);
  }

  /// Closes all virtual streams and forgets transient state. The physical
  /// carrier is closed by [CodexVirtualCarrier.close].
  Future<void> close() async {
    if (closed) return;
    closed = true;
    for (final stream in workspaceStreams) {
      stream.close();
    }
    for (final stream in controlStreams) {
      stream.close();
    }
    for (final stream in eventStreams.values) {
      stream.close();
    }
    workspaceStreams.clear();
    controlStreams.clear();
    eventStreams.clear();
    final follows = List<CodexLiveFollow>.from(live.follows);
    live.follows.clear();
    for (final follow in follows) {
      follow.queue.close();
      final stop = follow.close;
      if (stop != null) {
        try {
          await stop();
        } on Object {
          // Best-effort teardown.
        }
      }
    }
    pendingApprovals.clear();
    pendingRequestIds.clear();
    pendingThreads.clear();
    blankThreads.clear();
    selectedModels.clear();
    _selectedPermissions.clear();
    imageAttachments.clear();
    final client = _api;
    _api = null;
    _apiFuture = null;
    if (client != null) await client.dispose();
  }

  // --- Catalog / models ----------------------------------------------------

  Future<CodexCatalog> refreshCatalog({bool force = false}) {
    final now = _nowMs;
    final existing = catalog;
    if (!force && existing != null && now - _catalogLoadedAt < 2000) {
      return Future<CodexCatalog>.value(existing);
    }
    final pending = _catalogFuture;
    if (pending != null) return pending;
    final future = api.then((client) => codexLoadCatalog(client, pendingThreads: pendingThreads));
    _catalogFuture = future;
    unawaited(future.then(
      (value) {
        catalog = value;
        _catalogLoadedAt = _nowMs;
        _catalogFuture = null;
      },
      onError: (Object _) {
        if (identical(_catalogFuture, future)) _catalogFuture = null;
      },
    ));
    return future;
  }

  @override
  Future<CodexCatalog> currentCatalog() => refreshCatalog();

  Future<CodexModelDirectory> models() {
    final existing = modelDirectory;
    if (existing != null) return Future<CodexModelDirectory>.value(existing);
    final pending = _modelFuture;
    if (pending != null) return pending;
    final future = api.then(codexLoadModelDirectory);
    _modelFuture = future;
    unawaited(future.then(
      (value) {
        modelDirectory = value;
        _modelFuture = null;
      },
      onError: (Object _) {
        if (identical(_modelFuture, future)) _modelFuture = null;
      },
    ));
    return future;
  }

  @override
  Map<String, Object?> modelSelection(String sessionId, [CodexModelDirectory? directory]) {
    final selected = codexRecord(selectedModels[sessionId]);
    if (selected.isNotEmpty) return selected;
    final session = catalog?.sessions.firstWhere(
          (item) => item['id'] == sessionId,
          orElse: () => const <String, Object?>{},
        );
    final model = codexString(session?['model']);
    if (model != null) {
      final effort = codexString(session?['reasoningEffort']);
      return <String, Object?>{
        'provider': codexProvider,
        'model': model,
        if (effort != null) 'reasoningEffort': effort,
      };
    }
    return directory?.defaultSelection ?? codexModelSelection();
  }

  @override
  String? permissionSelection(String sessionId) => _selectedPermissions[sessionId];

  @override
  void setPermissionSelection(String sessionId, String? preset) {
    if (preset == null) {
      _selectedPermissions.remove(sessionId);
    } else {
      _selectedPermissions[sessionId] = preset;
    }
    publishProjection(sessionId, 'permissions', codexPermissionsProjection(preset), nextProjectionSeq());
  }

  @override
  String? sessionTitle(String sessionId) {
    final session = catalog?.sessions.firstWhere(
          (item) => item['id'] == sessionId,
          orElse: () => const <String, Object?>{},
        );
    if (session == null) return null;
    return codexDisplayTitle(session);
  }

  @override
  void updateThreadName(String threadId, String name) {
    final pending = pendingThreads[threadId];
    if (pending != null) {
      pendingThreads[threadId] = <String, Object?>{...pending, 'name': name};
    }
    final current = catalog;
    if (current == null) return;
    final threads = current.threads
        .map((thread) => codexString(thread['id']) == threadId ? <String, Object?>{...thread, 'name': name} : thread)
        .toList();
    final sessions = current.sessions.map((session) {
      if (session['nativeId'] != threadId) return session;
      final rest = Map<String, Object?>.from(session)..remove('title');
      if (name.trim().isEmpty) return rest;
      return <String, Object?>{...rest, 'title': name};
    }).toList();
    catalog = CodexCatalog(
      threads: threads,
      sessions: sessions,
      projects: current.projects,
      workspaces: current.workspaces,
      threadsComplete: current.threadsComplete,
      projectsComplete: current.projectsComplete,
    );
  }

  @override
  void rememberOpenedSession(String sessionId) {
    lastOpenedSessionId = sessionId;
  }

  Future<void> refreshAndPublishWorkspaces({bool force = false}) async {
    CodexCatalog? updated;
    try {
      updated = await refreshCatalog(force: force);
    } on Object {
      return;
    }
    publishWorkspaceBaseline(updated);
  }

  void publishWorkspaceBaseline(CodexCatalog value) {
    for (final stream in workspaceStreams) {
      for (final workspace in codexNativeVisibleWorkspaces(value, selectedWorkspaceId)) {
        stream.push(<String, Object?>{'type': 'upsert', 'workspace': codexNativeWorkspace(workspace)});
      }
      stream.push(<String, Object?>{
        'type': 'archived',
        'archivedSessionIds': value.sessions.where((session) => session['archived'] == true).map((session) => session['id']).toList(),
      });
    }
  }

  // --- History -------------------------------------------------------------

  Map<String, Object?> _boundedPage(Map<String, Object?> page) => <String, Object?>{
        ...page,
        'maxMessages': codexBoundedHistoryPageSize(codexOptionalPositiveInteger(page['maxMessages'])),
      };

  Future<Map<String, Object?>> readHistoryPage(String threadId, Map<String, Object?> page) async {
    final bounded = _boundedPage(page);
    final knownUpdatedAt = codexNormalizeTime(
      catalog?.sessions.firstWhere(
            (session) => session['id'] == '$codexSessionPrefix$threadId',
            orElse: () => const <String, Object?>{},
          )['updatedAt'],
    );
    final knownTime = knownUpdatedAt == 0 ? null : knownUpdatedAt;
    if (!blankThreads.contains(threadId)) {
      final cached = historyCache.getFreshPage(threadId, sessionGeneration, bounded, knownUpdatedAt: knownTime);
      if (cached != null) {
        applyHistoryMetadata(threadId, cached);
        return cached;
      }
    }
    return historyCache.runSingleFlightPage(
      threadId,
      sessionGeneration,
      bounded,
      () async {
        final client = await api;
        final readEpoch = historyCache.beginReadEpoch();
        Map<String, Object?> value;
        try {
          final request = <String, Object?>{
            'threadId': threadId,
            if (bounded['beforeSeq'] != null) 'beforeSeq': bounded['beforeSeq']!,
            if (bounded['throughSeq'] != null) 'throughSeq': bounded['throughSeq']!,
            if (bounded['maxMessages'] != null) 'maxMessages': bounded['maxMessages']!,
          };
          value = codexRecord(await client.request('dsh/sessionHistory', request));
        } on Object catch (error) {
          if (!codexIsLegacySessionHistoryUnsupported(error)) {
            final stale = historyCache.getStalePage(threadId, sessionGeneration, bounded);
            if (stale != null) return stale;
            rethrow;
          }
          JsonMap thread;
          try {
            final result = codexRecord(await client.request('thread/read', <String, Object?>{
              'threadId': threadId,
              'includeTurns': true,
            }));
            thread = codexRecord(result['thread']);
          } on Object catch (historyError) {
            final code = codexErrorCode(historyError);
            if (!blankThreads.contains(threadId) || code != 'CODEX_UPSTREAM_ERROR') {
              final stale = historyCache.getStalePage(threadId, sessionGeneration, bounded);
              if (stale != null) return stale;
              rethrow;
            }
            thread = <String, Object?>{'id': threadId, 'turns': <Object?>[]};
          }
          if (codexString(thread['id']) != threadId) {
            throw const CodexValueError('CodeX returned an invalid Thread history.');
          }
          final projected = codexProjectCodexNativeHistory(thread, '$codexSessionPrefix$threadId', sessionGeneration);
          value = codexPaginateCodexNativeHistory(projected, <String, Object?>{
            'beforeSeq': page['beforeSeq'],
            'throughSeq': page['throughSeq'],
            'maxMessages': bounded['maxMessages'],
          });
        }
        value = codexAdaptCodexHistoryPage(value, sessionGeneration);
        if (!codexIsCodexNativeHistoryPage(value, '$codexSessionPrefix$threadId')) {
          throw const CodexValueError('CodeX Remote returned an invalid History page.');
        }
        historyCache.setPage(
          threadId,
          sessionGeneration,
          bounded,
          value,
          knownUpdatedAt: knownTime,
          readEpoch: readEpoch,
        );
        applyHistoryMetadata(threadId, value);
        for (final entry in codexArray(value['records'])) {
          final record = codexRecord(entry);
          live.cacheImageBlocks(
            '$codexSessionPrefix$threadId',
            codexIsRecord(record['event']) ? codexRecord(record['event'])['data'] : null,
          );
        }
        return value;
      },
    );
  }

  void applyHistoryMetadata(String threadId, Map<String, Object?> page) {
    final selection = codexRecord(page['header']);
    final model = codexString(selection['model']);
    final effort = codexString(selection['reasoningEffort']);
    if (model != null) {
      selectedModels['$codexSessionPrefix$threadId'] = <String, Object?>{
        'provider': codexProvider,
        'model': model,
        if (effort != null) 'reasoningEffort': effort,
      };
    }
    final preset = codexPermissionPresetFromResponse(selection);
    setPermissionSelection(
      '$codexSessionPrefix$threadId',
      preset == 'workspace-write' || preset == 'danger-full-access' ? preset : null,
    );
  }

  // --- Endpoint helpers ----------------------------------------------------

  JsonMap _args(Map<String, Object?> payload) => codexCarrierArgs(payload);

  JsonMap _request(Map<String, Object?> payload) => codexRequestArg(_args(payload));

  Future<Object?> _handle(String endpoint, Map<String, Object?> payload) async {
    final args = _args(payload);
    final request = _request(payload);
    await api;
    switch (endpoint) {
      case r'$events/result':
        await events.answerRemoteEvent(args);
        return null;

      case 'workspace/list':
        final catalog = await refreshCatalog();
        return <String, Object?>{
          'items': codexNativeVisibleWorkspaces(catalog, selectedWorkspaceId).map(codexNativeWorkspace).toList(),
          'archivedSessionIds': catalog.sessions.where((session) => session['archived'] == true).map((session) => session['id']).toList(),
          'pinnedSessionIds': <Object?>[],
        };

      case 'workspace/create':
        return _createWorkspace(request);

      case 'workspace/rename':
        throw CodexValueError('CodeX virtual Workspace ${codexString(request['workspaceId']) ?? ''} cannot be renamed.', 'workspace-read-only');

      case 'workspace/delete':
        throw const CodexValueError('CodeX virtual Workspaces cannot be deleted.', 'workspace-read-only');

      case 'workspace/insertBefore':
        return <String, Object?>{
          'workspaceIds': codexNativeVisibleWorkspaces(await currentCatalog(), selectedWorkspaceId)
              .map((item) => item['workspaceId'])
              .toList(),
        };

      case 'workspace/insertSessionBefore':
        return _workspaceForSession(request);

      case 'workspace/archiveSession':
        return _archiveSession(request);

      case 'session/list':
        return <String, Object?>{'items': await _sessionSummaries()};

      case 'session/projections':
        return _sessionProjections(request);

      case 'session/search':
        return _searchSessions(request);

      case 'session/create':
        return _createSession(request);

      case 'session/fork':
        return _forkSession(request);

      case 'session/history':
        return _sessionHistory(request);

      case 'session/events':
      case 'session/page':
        return _sessionPage(request);

      case 'session/prompt':
        return _prompt(request);

      case 'session/cancel':
        return _cancel(request);

      case 'session/rename':
        return _renameSession(request);

      case 'session/updateQueue':
        throw const CodexValueError('CodeX does not expose a DSH inbox queue.', 'queue-item-not-found');

      case 'session/attachment':
        return _attachment(request);

      case 'session/modelCatalog':
        return codexModelCatalog(await models());

      case 'session/models': {
        final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
        codexNativeThreadId(sessionId);
        final directory = await models();
        return <String, Object?>{
          'current': modelSelection(sessionId, directory),
          'routable': true,
          'groups': directory.groups,
          'failures': <Object?>[],
        };
      }

      case 'session/selectModel':
        return _selectModel(request);

      case 'session/canOpenWorkspacePath':
        return selectedWorkspaceId != null;

      case 'session/openWorkspacePath':
        throw const CodexValueError('Opening Host paths is unavailable in CodeX mode.', 'bad-request');

      case 'host/describe':
        return _describeHost();

      case 'host/listDirectory':
      case 'directoryPicker/list':
        return _listDirectory(request);

      case 'skills/list':
        return <String, Object?>{'items': <Object?>[]};

      case 'commands/list':
        return _commandList(args);

      case 'commands/execute':
        return _executeCommand(args);

      default:
        throw CodexValueError('CodeX virtual Harness does not implement $endpoint.', 'method-not-found');
    }
  }

  /// Dispatches a virtual endpoint, delegating host-owned endpoints to the
  /// original carrier. The returned RpcResult is what the mux expects.
  Future<RpcResult> dispatch(String endpoint, Map<String, Object?> payload) async {
    onDispatch?.call(endpoint, payload);
    if (codexIsHostWorkspaceEndpoint(endpoint)) {
      return hostCarrier.call(endpoint, payload);
    }
    if (endpoint == 'job/kill') {
      return hostCarrier.call(endpoint, payload);
    }
    try {
      return RpcOk(await _handle(endpoint, <String, Object?>{'args': payload}));
    } on Object catch (error) {
      return codexFailFrom(error);
    }
  }

  /// Returns a virtual stream for the endpoint, or `null` when the original
  /// carrier must open it.
  Stream<Map<String, Object?>>? openStream(String endpoint, Map<String, Object?> payload) {
    if (!hasCodexApp || codexIsHostWorkspaceStreamEndpoint(endpoint)) return null;
    switch (endpoint) {
      case 'workspace/follow':
        return events.workspaceFollow();
      case 'session/control':
        return events.sessionControl();
      case 'session/follow':
        return live.sessionFollow(_request(payload));
      case r'$events':
        return events.remoteEvents();
      case 'job/list':
      case 'job/follow':
        return events.emptyJobStream(endpoint);
      default:
        return null;
    }
  }

  Future<Object?> _createWorkspace(JsonMap request) async {
    final path = codexString(request['path']);
    if (path == null || path.trim().isEmpty) {
      throw const CodexValueError('A CodeX working directory is required.', 'bad-request');
    }
    final catalog = await currentCatalog();
    final existing = catalog.workspaces.firstWhere(
      (item) => item['path'] == path,
      orElse: () => const <String, Object?>{},
    );
    if (existing.containsKey('workspaceId')) {
      return <String, Object?>{'workspace': codexNativeWorkspace(existing), 'created': false};
    }
    throw const CodexValueError('The selected directory is not visible to CodeX Remote.', 'workspace-not-found');
  }

  Future<Object?> _workspaceForSession(JsonMap request) async {
    final sessionId = codexString(request['sessionId']);
    final catalog = await currentCatalog();
    final workspace = catalog.workspaces.firstWhere(
      (item) => sessionId != null && codexArray(item['sessionIds']).contains(sessionId),
      orElse: () => const <String, Object?>{},
    );
    if (!workspace.containsKey('workspaceId')) {
      throw const CodexValueError('The CodeX virtual Workspace was not found.', 'workspace-not-found');
    }
    return <String, Object?>{'workspace': codexNativeWorkspace(workspace)};
  }

  Future<Object?> _archiveSession(JsonMap request) async {
    final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
    final threadId = codexNativeThreadId(sessionId);
    final client = await api;
    await client.request('thread/archive', <String, Object?>{'threadId': threadId});
    historyCache.removeThread(threadId);
    final catalog = await refreshCatalog(force: true);
    publishWorkspaceBaseline(catalog);
    return <String, Object?>{'archivedSessionIds': <Object?>[sessionId]};
  }

  Future<List<JsonMap>> _sessionSummaries() async {
    final catalog = await refreshCatalog();
    CodexModelDirectory? directory;
    try {
      directory = await models();
    } on Object {
      directory = null;
    }
    return catalog.sessions.map((session) {
      final nativeId = codexString(session['nativeId']) ?? '';
      final blank = blankThreads.contains(nativeId) || pendingThreads.containsKey(nativeId);
      return _sessionSummary(
        session,
        blank: blank,
        modelSelection: modelSelection(codexString(session['id']) ?? '', directory),
        lastPromptAt: session['updatedAt'],
      );
    }).toList();
  }

  JsonMap _sessionSummary(
    JsonMap session, {
    required bool blank,
    required Map<String, Object?> modelSelection,
    Object? lastPromptAt,
    int? asOfSeq,
  }) =>
      <String, Object?>{
        'sessionId': session['id'],
        'updatedAt': session['updatedAt'],
        'running': session['status'] == 'running' || session['status'] == 'waiting',
        'blank': blank,
        if (session['cwd'] != null) 'cwd': session['cwd'],
        'projections': <String, Object?>{
          'kind': 'sequenced',
          'asOfSeq': asOfSeq ?? 0,
          'values': <String, Object?>{
            'title': codexDisplayTitle(session),
            'sessionListMetadata': <String, Object?>{'blank': blank, 'lastPromptAt': lastPromptAt},
            'modelSelection': codexModelSelectionProjection(modelSelection),
            'permissions': codexPermissionsProjection(permissionSelection(codexString(session['id']) ?? '')),
            'imageLimits': codexImageLimitsProjection(),
          },
        },
      };

  Future<Object?> _searchSessions(JsonMap request) async {
    final query = codexRequiredString(request['query'], 'query').trim();
    if (query.isEmpty || query.length > 500 || query.contains('\u0000')) {
      throw const CodexValueError('The CodeX Session search query is invalid.', 'bad-request');
    }
    final catalog = await currentCatalog();
    final needle = query.toLowerCase();
    final matches = <JsonMap>[];
    for (final thread in catalog.threads) {
      final session = codexProjectThread(thread);
      if (session == null) continue;
      final candidates = <String>[
        if (codexString(session['title'])?.isNotEmpty == true) codexString(session['title'])!,
        if (codexString(session['preview'])?.isNotEmpty == true) codexString(session['preview'])!,
        if (codexString(session['cwd'])?.isNotEmpty == true) codexString(session['cwd'])!,
        if (codexString(session['nativeId'])?.isNotEmpty == true) codexString(session['nativeId'])!,
      ];
      final snippet = candidates.firstWhere(
        (value) => value.toLowerCase().contains(needle),
        orElse: () => '',
      );
      if (snippet.isEmpty) continue;
      matches.add(<String, Object?>{
        'sessionId': session['id'],
        'snippet': codexTruncateCodePoints(snippet, codexSessionSearchSnippetCodePoints),
      });
    }
    return <String, Object?>{
      'items': matches.take(codexSessionSearchResultLimit).toList(),
      'hasMore': matches.length > codexSessionSearchResultLimit,
    };
  }

  Future<Object?> _createSession(JsonMap request) async {
    final catalog = await currentCatalog();
    final workspaceId = codexString(request['workspaceId']) ?? selectedWorkspaceId;
    final workspace = workspaceId == null
        ? const <String, Object?>{}
        : catalog.workspaces.firstWhere(
            (item) => item['workspaceId'] == workspaceId,
            orElse: () => const <String, Object?>{},
          );
    final cwd = codexString(request['cwd']) ?? (workspace.containsKey('path') ? codexString(workspace['path']) : null);
    if (cwd == null) {
      throw const CodexValueError('The CodeX virtual Workspace was not found.', 'workspace-not-found');
    }
    final root = codexString(workspace['path']);
    if (root != null && !codexContainsPath(root, cwd)) {
      throw const CodexValueError('The selected directory is outside the current CodeX virtual Workspace.', 'workspace-not-found');
    }
    final directory = await models();
    final selection = directory.defaultSelection;
    const requestedPreset = codexDefaultPermission;
    final client = await api;
    final result = codexRecord(await client.request('thread/start', <String, Object?>{
      'cwd': cwd,
      'model': codexString(selection['model']) ?? '',
      'permissionPreset': requestedPreset,
    }));
    final preset = codexPermissionPresetFromResponse(result) ?? requestedPreset;
    final runtimeThread = codexRecord(result['thread']);
    final thread = <String, Object?>{
      ...runtimeThread,
      'cwd': cwd,
      'turns': codexArray(runtimeThread['turns']),
    };
    final projected = codexProjectThread(thread);
    if (projected == null) throw const CodexValueError('CodeX returned an invalid Thread.', 'internal');
    final nativeId = codexString(projected['nativeId']) ?? '';
    pendingThreads[nativeId] = thread;
    blankThreads.add(nativeId);
    selectedModels[codexString(projected['id']) ?? ''] = selection;
    setPermissionSelection(codexString(projected['id']) ?? '', preset);
    unawaited(refreshAndPublishWorkspaces(force: true));
    final seq = nextProjectionSeq();
    emitRemoteEvent('api-session/added', <Object?>[
      _sessionSummary(
        projected,
        blank: true,
        modelSelection: selection,
        lastPromptAt: null,
        asOfSeq: seq,
      ),
    ]);
    publishProjection(codexString(projected['id']) ?? '', 'title', codexDisplayTitle(projected), seq);
    return <String, Object?>{'sessionId': projected['id']};
  }

  Future<Object?> _forkSession(JsonMap request) async {
    final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
    final client = await api;
    final result = codexRecord(await client.request('thread/fork', <String, Object?>{
      'threadId': codexNativeThreadId(sessionId),
    }));
    final preset = codexPermissionPresetFromResponse(result);
    final projected = codexProjectThread(codexRecord(result['thread']));
    if (projected == null) throw const CodexValueError('CodeX returned an invalid forked Thread.', 'internal');
    final projectedId = codexString(projected['id']) ?? '';
    selectedModels[projectedId] = modelSelection(sessionId, await models());
    setPermissionSelection(projectedId, preset);
    await refreshAndPublishWorkspaces(force: true);
    final seq = nextProjectionSeq();
    publishProjection(projectedId, 'title', codexDisplayTitle(projected), seq);
    return <String, Object?>{'sessionId': projected['id']};
  }

  String? _activeTurnId(String threadId) {
    for (final follow in live.follows) {
      if (follow.threadId == threadId && follow.stepOpen) return follow.activeTurnId;
    }
    return null;
  }

  Future<Object?> _prompt(JsonMap request) async {
    final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
    final input = codexPromptInput(codexArray(request['content']));
    if (input == null) {
      throw const CodexValueError(
        'CodeX virtual Sessions accept text and pasted PNG, JPEG, WebP, or GIF images only.',
        'attachment-error',
      );
    }
    final threadId = codexNativeThreadId(sessionId);
    Map<String, Object?> selection = codexRecord(selectedModels[sessionId]);
    if (selection.isEmpty) {
      final session = catalog?.sessions.firstWhere(
            (item) => item['id'] == sessionId,
            orElse: () => const <String, Object?>{},
          ) ?? const <String, Object?>{};
      final model = codexString(session['model']);
      if (model != null) {
        final effort = codexString(session['reasoningEffort']);
        selection = <String, Object?>{
          'provider': codexProvider,
          'model': model,
          if (effort != null) 'reasoningEffort': effort,
        };
      }
    }
    if (selection.isEmpty) selection = modelSelection(sessionId, await models());
    final isFreshBlank = blankThreads.contains(threadId) || pendingThreads.containsKey(threadId);
    final client = await api;
    if (!isFreshBlank) {
      final resume = codexRecord(await client.request('thread/resume', <String, Object?>{
        'threadId': threadId,
        'model': codexString(selection['model']) ?? '',
      }));
      final preset = codexPermissionPresetFromResponse(resume);
      if (preset != null) setPermissionSelection(sessionId, preset);
    }
    pendingRequestIds[sessionId] = codexString(request['requestId']) ?? '';
    final steer = request['mode'] == 'steer';
    String? expectedTurnId;
    if (steer) {
      expectedTurnId = _activeTurnId(threadId);
      if (expectedTurnId == null) {
        throw const CodexValueError('The CodeX Thread has no active turn to steer.', 'steer-unavailable');
      }
    }
    final params = <String, Object?>{
      'threadId': threadId,
      'input': input,
      ...codexModelParams(selection),
      if (expectedTurnId != null) 'expectedTurnId': expectedTurnId,
    };
    await client.request(steer ? 'turn/steer' : 'turn/start', params);
    blankThreads.remove(threadId);
    historyCache.invalidateThread(threadId);
    unawaited(refreshAndPublishWorkspaces());
    return <String, Object?>{'accepted': true};
  }

  Future<Object?> _cancel(JsonMap request) async {
    final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
    final threadId = codexNativeThreadId(sessionId);
    final turnId = _activeTurnId(threadId);
    if (turnId != null) {
      final client = await api;
      await client.request('turn/interrupt', <String, Object?>{'threadId': threadId, 'turnId': turnId});
    }
    historyCache.invalidateThread(threadId);
    return <String, Object?>{'accepted': true};
  }

  Future<Object?> _renameSession(JsonMap request) async {
    final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
    final title = codexRequiredString(request['title'], 'title');
    final threadId = codexNativeThreadId(sessionId);
    final client = await api;
    await client.request('thread/name/set', <String, Object?>{'threadId': threadId, 'name': title});
    final seq = nextProjectionSeq();
    updateThreadName(threadId, title);
    publishProjection(sessionId, 'title', title, seq);
    await refreshAndPublishWorkspaces(force: true);
    return <String, Object?>{'title': title, 'seq': seq};
  }

  Future<Object?> _attachment(JsonMap request) async {
    final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
    final attachmentId = codexString(request['attachmentId']) ??
        codexString(codexRecord(request['attachment'])['attachmentId']);
    if (attachmentId == null) {
      throw const CodexValueError(
        'The CodeX image is not available in this virtual Session.',
        'attachment-error',
      );
    }
    if (!attachmentId.startsWith(codexImageAttachmentPrefix)) {
      throw const CodexValueError(
        'The CodeX image is not available in this virtual Session.',
        'attachment-error',
      );
    }
    codexNativeThreadId(sessionId);
    final cached = codexRecord(imageAttachments[attachmentId]);
    if (codexString(cached['sessionId']) == sessionId) {
      return <String, Object?>{'attachment': cached['attachment'], 'data': cached['data']};
    }
    await _hydrateImageAttachments(sessionId);
    final hydrated = codexRecord(imageAttachments[attachmentId]);
    if (codexString(hydrated['sessionId']) == sessionId) {
      return <String, Object?>{'attachment': hydrated['attachment'], 'data': hydrated['data']};
    }
    throw const CodexValueError(
      'The CodeX image is not available in this virtual Session.',
      'attachment-error',
    );
  }

  Future<void> _hydrateImageAttachments(String sessionId) async {
    final threadId = codexNativeThreadId(sessionId);
    final client = await api;
    final result = codexRecord(await client.request('thread/read', <String, Object?>{
      'threadId': threadId,
      'includeTurns': true,
    }));
    final thread = codexRecord(result['thread']);
    if (codexString(thread['id']) != threadId) {
      throw const CodexValueError('CodeX returned an invalid Thread history.');
    }
    final history = codexProjectCodexNativeHistory(thread, sessionId, sessionGeneration);
    for (final entry in codexArray(history['entries'])) {
      live.cacheImageBlocks(sessionId, codexRecord(codexRecord(entry)['event'])['data']);
    }
  }

  Future<Object?> _selectModel(JsonMap request) async {
    final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
    codexNativeThreadId(sessionId);
    final provider = codexRequiredString(request['provider'], 'provider');
    final model = codexRequiredString(request['model'], 'model');
    final effort = codexString(request['reasoningEffort']);
    final directory = await models();
    final available = directory.models[model];
    if (provider != codexProvider || available == null) {
      throw const CodexValueError('The selected CodeX model is unavailable on this Host.', 'model-unavailable');
    }
    final efforts = codexArray(codexRecord(available['reasoning'])['efforts'])
        .map((item) => codexString(codexRecord(item)['id']))
        .whereType<String>()
        .toList();
    if (effort != null && !efforts.contains(effort)) {
      throw const CodexValueError('The selected reasoning effort is unavailable for this CodeX model.', 'model-unavailable');
    }
    final selected = <String, Object?>{
      'provider': provider,
      'model': model,
      if (effort != null) 'reasoningEffort': effort,
    };
    selectedModels[sessionId] = selected;
    final seq = nextProjectionSeq();
    publishProjection(sessionId, 'modelSelection', codexModelSelectionProjection(selected), seq);
    return <String, Object?>{'selected': selected};
  }

  Future<Object?> _describeHost() async {
    final catalog = await currentCatalog();
    final workspace = catalog.workspaces.firstWhere(
      (item) => item['workspaceId'] == selectedWorkspaceId,
      orElse: () => const <String, Object?>{},
    );
    final path = codexString(workspace['path']) ?? '';
    CodexModelDirectory? directory;
    try {
      directory = await models();
    } on Object {
      directory = null;
    }
    final model = codexString(directory?.defaultSelection['model']);
    return <String, Object?>{
      'version': 'CodeX Remote',
      'cwd': path,
      'home': path,
      'provider': 'CodeX',
      if (model != null) 'model': model,
      'attachedSessions': catalog.sessions.length,
      'canOpenPath': workspace.containsKey('workspaceId'),
    };
  }

  Future<Object?> _listDirectory(JsonMap request) async {
    final catalog = await currentCatalog();
    final workspace = catalog.workspaces.firstWhere(
      (item) => item['workspaceId'] == selectedWorkspaceId,
      orElse: () => const <String, Object?>{},
    );
    final root = codexString(workspace['path']);
    if (root == null) {
      throw const CodexValueError('The CodeX virtual Workspace was not found.', 'workspace-not-found');
    }
    final path = codexString(request['path']) ?? root;
    if (!codexContainsPath(root, path)) {
      throw const CodexValueError('The selected directory is outside the current CodeX virtual Workspace.', 'workspace-not-found');
    }
    final client = await api;
    final listing = codexRecord(await client.request('dsh/directoryList', <String, Object?>{'path': path}));
    if (!codexIsDirectoryListing(listing)) {
      throw const CodexValueError('CodeX Remote returned an invalid directory listing.', 'internal');
    }
    final paths = <String>[
      codexString(listing['path']) ?? '',
      codexString(listing['home']) ?? '',
      ...codexArray(listing['crumbs']).map((item) => codexString(codexRecord(item)['path']) ?? ''),
      ...codexArray(listing['entries']).map((item) => codexString(codexRecord(item)['path']) ?? ''),
    ];
    if (paths.any((item) => !codexContainsPath(root, item))) {
      throw const CodexValueError('CodeX Remote returned a directory outside the current Workspace.', 'internal');
    }
    return listing;
  }

  List<JsonMap> _commandList(JsonMap args) {
    codexNativeThreadId(codexRequiredString(args['agentId'], 'agentId'));
    return <JsonMap>[
      <String, Object?>{
        'name': 'permission',
        'description': 'Switch the CodeX Remote sandbox mode and approval policy',
        'input': <String, Object?>{'hint': '<preset>'},
      },
    ];
  }

  /// The attachments a `commands/execute` request carried.
  ///
  /// The composer sends `submittedAttachments` (`SessionApi.executeCommand`),
  /// while this endpoint used to insist on `images` and throw before it even
  /// looked at the command name — which failed every slash command under CodeX,
  /// `/permission` included, with "The CodeX command image list is required."
  /// Accept both spellings; a request that carries neither simply has none.
  static List<Object?> _commandAttachments(JsonMap args) {
    for (final key in const ['submittedAttachments', 'images']) {
      final value = args[key];
      if (value is List) return value;
    }
    return const <Object?>[];
  }

  Future<JsonMap?> _executeCommand(JsonMap args) async {
    final sessionId = codexRequiredString(args['agentId'], 'agentId');
    final threadId = codexNativeThreadId(sessionId);
    final line = codexRequiredString(args['line'], 'command line').trim();
    final attachments = _commandAttachments(args);
    final match = RegExp(r'^\/permission(?:\s+([\s\S]*))?$').firstMatch(line);
    if (match == null) {
      // A real answer, not null: `null` reaches the app as a generic
      // "指令没有执行" with no code to word it from. Name the command and say
      // this harness has none of it, so the row can say so in the user's words.
      final name = RegExp(r'^\/(\S*)').firstMatch(line)?.group(1) ?? line;
      throw CodexValueError('The CodeX virtual Harness does not implement /$name.', 'FEATURE_NOT_SUPPORTED');
    }
    final commandId = 'codex-permission:${++_commandSeq}';
    if (attachments.isNotEmpty) {
      return <String, Object?>{
        'commandId': commandId,
        'result': <String, Object?>{'kind': 'error', 'text': 'CodeX Remote permission commands do not accept attachments.'},
      };
    }
    final requested = (match.group(1) ?? '').trim();
    if (requested.isEmpty) {
      await readHistoryPage(threadId, <String, Object?>{'maxMessages': 1});
      return <String, Object?>{
        'commandId': commandId,
        'result': <String, Object?>{
          'kind': 'success',
          'text': 'current preset ${permissionSelection(sessionId) ?? 'Host settings (not reported)'}',
        },
      };
    }
    if (!codexIsPermissionPreset(requested)) {
      return <String, Object?>{
        'commandId': commandId,
        'result': <String, Object?>{
          'kind': 'error',
          'text': 'unknown preset "$requested" (available: workspace-write, danger-full-access)',
        },
      };
    }
    final client = await api;
    final result = codexRecord(await client.request('thread/resume', <String, Object?>{
      'threadId': threadId,
      'permissionPreset': requested,
    }));
    final effective = codexPermissionPresetFromResponse(result);
    if (effective == null) throw const CodexValueError('The Host did not confirm the CodeX permission preset.');
    setPermissionSelection(sessionId, effective);
    if (effective != requested) throw const CodexValueError('The Host did not apply the requested CodeX permission preset.');
    return <String, Object?>{
      'commandId': commandId,
      'result': <String, Object?>{'kind': 'success', 'text': 'preset $effective'},
    };
  }

  Future<Object?> _sessionProjections(JsonMap request) async {
    final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
    final catalog = await currentCatalog();
    final session = catalog.sessions.firstWhere(
      (item) => item['id'] == sessionId,
      orElse: () => const <String, Object?>{},
    );
    if (session.isEmpty) return null;
    final threadId = codexNativeThreadId(sessionId);
    int cursor;
    final normalizedUpdatedAt = codexNormalizeTime(session['updatedAt']);
    final updatedAt = normalizedUpdatedAt == 0 ? null : normalizedUpdatedAt;
    final cached = historyCache.getFreshTailCursor(threadId, sessionGeneration, knownUpdatedAt: updatedAt);
    if (cached != null) {
      cursor = cached;
    } else {
      final page = await readHistoryPage(threadId, <String, Object?>{'maxMessages': 1});
      cursor = codexInteger(page['cursor']) ?? -1;
    }
    CodexModelDirectory? directory;
    try {
      directory = await models();
    } on Object {
      directory = null;
    }
    return _sessionSummary(
      session,
      blank: cursor < 0,
      modelSelection: modelSelection(sessionId, directory),
      lastPromptAt: session['updatedAt'],
      asOfSeq: cursor,
    )['projections'];
  }

  Future<Object?> _sessionPage(JsonMap request) async {
    final sessionId = codexSessionIdFromAddress(codexRecord(request['address']));
    final page = await readHistoryPage(codexNativeThreadId(sessionId), <String, Object?>{
      'beforeSeq': codexOptionalNonNegativeInteger(request['beforeSeq']),
      'throughSeq': codexOptionalInteger(request['throughSeq']),
      'maxMessages': codexOptionalPositiveInteger(request['maxMessages']),
    });
    return <String, Object?>{
      'records': page['records'],
      'hasMore': page['hasMore'],
      'cursor': page['cursor'],
    };
  }

  Future<Object?> _sessionHistory(JsonMap request) async {
    final sessionId = codexRequiredString(request['sessionId'], 'sessionId');
    final beforeSeq = codexOptionalNonNegativeInteger(request['beforeSeq']);
    final history = await readHistoryPage(codexNativeThreadId(sessionId), <String, Object?>{
      'beforeSeq': beforeSeq,
      'maxMessages': codexOptionalPositiveInteger(request['maxMessages']),
    });
    CodexModelDirectory? directory;
    try {
      directory = await models();
    } on Object {
      directory = null;
    }
    if (beforeSeq == null) {
      if (closed) throw const CodexValueError('The CodeX virtual Harness is closed.');
      rememberOpenedSession(sessionId);
    }
    final cursor = codexInteger(history['cursor']) ?? -1;
    return <String, Object?>{
      'events': codexArray(history['records']).map((entry) {
        final record = codexRecord(entry);
        return <String, Object?>{
          'event': record['event'],
          if (record['view'] != null) 'view': record['view']!,
        };
      }).toList(),
      'hasMore': history['hasMore'],
      if (beforeSeq == null)
        'projections': <String, Object?>{
          'asOfSeq': cursor,
          'values': <String, Object?>{
            'title': sessionTitle(sessionId),
            'sessionListMetadata': <String, Object?>{'blank': cursor < 0, 'lastPromptAt': null},
            'modelSelection': codexModelSelectionProjection(modelSelection(sessionId, directory)),
            'permissions': codexPermissionsProjection(permissionSelection(sessionId)),
            'imageLimits': codexImageLimitsProjection(),
          },
        },
    };
  }
}

/// A drop-in [DshCarrier] wrapper. It delegates every non-virtual endpoint to
/// the original carrier and serves the Codex virtual endpoints locally.
DshCarrier _codexPhysicalCarrier(DshCarrier inner) =>
    inner is DshCarrierWrapper ? (inner as DshCarrierWrapper).physicalCarrier : inner;

class CodexVirtualCarrier extends DshCarrier implements DshCarrierWrapper {
  CodexVirtualCarrier(this.inner, {String? hostDeviceId})
      : hostDeviceId = hostDeviceId ?? inner.hostVersion ?? 'codex-host',
        harness = CodexVirtualHarness(
          hostCarrier: inner,
          remote: _codexPhysicalCarrier(inner) is RemoteTunnelCarrier
              ? _codexPhysicalCarrier(inner) as RemoteTunnelCarrier
              : null,
          hostDeviceId: hostDeviceId ?? inner.hostVersion ?? 'codex-host',
        ) {
    final physical = _codexPhysicalCarrier(inner);
    final remoteCarrier = physical is RemoteTunnelCarrier ? physical : null;
    if (remoteCarrier != null) {
      _sessionSub = remoteCarrier.sessions.listen((_) {
        harness.onSessionReconnected();
      });
    }
  }

  final DshCarrier inner;
  final String hostDeviceId;
  final CodexVirtualHarness harness;

  StreamSubscription<RemoteHostSession>? _sessionSub;

  /// The physical carrier, used by `remoteCarrier`/`isRemote` extensions.
  @override
  DshCarrier get physicalCarrier => _codexPhysicalCarrier(inner);

  @override
  String get kind => 'codex+${inner.kind}';

  @override
  String? get hostVersion => inner.hostVersion;

  @override
  DshTracer? get tracer => inner.tracer;

  @override
  bool get supportsUplink => inner.supportsUplink;

  static const Set<String> _virtualEndpoints = <String>{
    r'$events',
    r'$events/result',
    'workspace/list',
    'workspace/create',
    'workspace/rename',
    'workspace/delete',
    'workspace/insertBefore',
    'workspace/insertSessionBefore',
    'workspace/archiveSession',
    'workspace/follow',
    'session/list',
    'session/projections',
    'session/search',
    'session/create',
    'session/fork',
    'session/history',
    'session/events',
    'session/page',
    'session/prompt',
    'session/control',
    'session/follow',
    'session/cancel',
    'session/rename',
    'session/updateQueue',
    'session/attachment',
    'session/modelCatalog',
    'session/models',
    'session/selectModel',
    'session/canOpenWorkspacePath',
    'session/openWorkspacePath',
    'host/describe',
    'host/listDirectory',
    'directoryPicker/list',
    'skills/list',
    'job/list',
    'job/follow',
    'job/kill',
    'commands/list',
    'commands/execute',
  };

  @override
  bool allowsEndpoint(String endpoint) {
    if (dshOnlyRemoteEndpoints.contains(endpoint)) return false;
    if (endpoint == 'job/kill') return inner.allowsEndpoint(endpoint);
    return (harness.hasCodexApp && _virtualEndpoints.contains(endpoint)) || inner.allowsEndpoint(endpoint);
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    // DSH-only writes never reach the physical Harness through a CodeX
    // connection, even if a stale UI or an older build asks for them.
    if (dshOnlyRemoteEndpoints.contains(endpoint)) {
      throw CodexValueError('CodeX does not support $endpoint.', 'FEATURE_NOT_SUPPORTED');
    }
    final payload = Map<String, Object?>.from(args);
    if (_virtualEndpoints.contains(endpoint) && harness.hasCodexApp) {
      return harness.dispatch(endpoint, payload);
    }
    return inner.call(endpoint, args, timeout: timeout);
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final physical = await inner.openLink(options);
    return _CodexVirtualLink(physical, harness);
  }

  @override
  Future<void> close() async {
    await _sessionSub?.cancel();
    _sessionSub = null;
    await harness.close();
    await inner.close();
  }
}

/// Forwards physical link frames verbatim, but answers virtual stream endpoints
/// from [CodexVirtualHarness] and translates their values into mux frames.
class _CodexVirtualLink implements DshMuxLink {
  _CodexVirtualLink(this.physical, this.harness);

  final DshMuxLink physical;
  final CodexVirtualHarness harness;

  final Set<String> _virtualStreams = <String>{};
  final Map<String, StreamSubscription<Map<String, Object?>>> _subscriptions = <String, StreamSubscription<Map<String, Object?>>>{};

  DshMuxFrameHandler? _onFrame;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
    physical.start(
      onFrame: (frame) {
        final streamId = codexString(frame['streamId']);
        if (streamId != null && _virtualStreams.contains(streamId)) return;
        onFrame(frame);
      },
      onLost: onLost,
    );
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    final stream = harness.openStream(endpoint, payload);
    if (stream == null) {
      physical.open(streamId, endpoint, payload);
      return;
    }
    _virtualStreams.add(streamId);
    void emitEnd() {
      if (_virtualStreams.remove(streamId)) {
        _subscriptions.remove(streamId);
        _onFrame?.call(<String, Object?>{'type': 'end', 'streamId': streamId});
      }
    }

    _subscriptions[streamId] = stream.listen(
      (value) {
        if (!_virtualStreams.contains(streamId)) return;
        _onFrame?.call(<String, Object?>{'type': 'item', 'streamId': streamId, 'value': value});
      },
      onError: (Object error) {
        if (!_virtualStreams.contains(streamId)) return;
        _onFrame?.call(<String, Object?>{
          'type': 'error',
          'streamId': streamId,
          'error': <String, Object?>{
            'code': codexErrorCode(error) ?? 'internal',
            'message': error.toString(),
            'details': <String, Object?>{},
          },
        });
        emitEnd();
      },
      onDone: emitEnd,
      cancelOnError: true,
    );
  }

  @override
  void sendItem(String streamId, Object? value) => physical.sendItem(streamId, value);

  @override
  void endUplink(String streamId) => physical.endUplink(streamId);

  @override
  void cancel(String streamId) {
    if (_virtualStreams.remove(streamId)) {
      unawaited(_subscriptions.remove(streamId)?.cancel());
      return;
    }
    physical.cancel(streamId);
  }

  @override
  Future<void> close(int code, String reason) async {
    for (final id in _virtualStreams.toList()) {
      _virtualStreams.remove(id);
      await _subscriptions.remove(id)?.cancel();
    }
    await physical.close(code, reason);
  }
}
