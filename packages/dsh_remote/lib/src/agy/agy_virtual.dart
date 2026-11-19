/// Plugin-owned virtual Harness for Antigravity ACP Remote.
///
/// It projects AGY ACP sessions at the existing DSH carrier boundary, so the
/// native Workspace/Session Chat UI needs no new page, button or slash command.
library;

import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

import '../agent/remote_agent.dart' show dshOnlyRemoteEndpoints;
import '../carrier/tunnel_carrier.dart';
import '../util/bytes.dart';
import 'agy_api.dart';
import 'agy_catalog.dart';
import 'agy_contract.dart';
import 'agy_events.dart';
import 'agy_history.dart';
import 'agy_image_codec.dart';
import 'agy_live.dart';
import 'agy_values.dart';

/// The virtual Harness owns the ACP client, catalog, event carriers and live
/// turn projection. The physical carrier stays untouched for host-only calls.
class AgyVirtualHarness implements AgyLiveContext {
  AgyVirtualHarness({
    required this.hostCarrier,
    required this.remote,
    required this.hostDeviceId,
    AgyCapabilities? capabilities,
  })  : explicitCapabilities = capabilities,
        catalog = AgyCatalog(const <AgyWorkspace>[], const <AgySession>[]) {
    events = AgyEventCarrier();
    live = AgyLiveProjection(this);
  }

  final DshCarrier hostCarrier;
  final RemoteTunnelCarrier? remote;
  final String hostDeviceId;
  final AgyCapabilities? explicitCapabilities;

  /// The physical carrier below the virtual layer: unprefixed DSH traffic and
  /// host endpoints resolve here.
  DshCarrier get physicalCarrier => _agyPhysicalCarrier(hostCarrier);

  late final AgyEventCarrier events;
  late final AgyLiveProjection live;

  AgyCatalog catalog;

  AgyTransport? _transport;
  Future<AgyTransport>? _transportFuture;
  Future<AgyCatalog>? _catalogFuture;
  final Set<String> _hydrated = <String>{};
  final Map<String, Future<void>> _hydrating = <String, Future<void>>{};
  final Set<String> _preboundSessions = <String>{};
  final List<JsonMap> _failures = <JsonMap>[];
  int _lastProjectionSeq = 0;

  /// Discovery/capability/prebind failures surfaced to the native UI instead
  /// of an empty model list. Bounded so a flapping Host cannot grow forever.
  List<JsonMap> get failures => List<JsonMap>.unmodifiable(_failures);

  void _recordFailure(String phase, Object? error) {
    final entry = error is Map<String, Object?>
        ? <String, Object?>{...error, 'phase': phase}
        : agyFailureEntry(error, phase: phase);
    final duplicate = _failures.any((item) =>
        item['code'] == entry['code'] && item['message'] == entry['message'] && item['phase'] == entry['phase']);
    if (duplicate) return;
    _failures.add(entry);
    if (_failures.length > 20) _failures.removeAt(0);
  }

  void _clearFailures(String phase) => _failures.removeWhere((item) => item['phase'] == phase);

  /// Merges the Host's own catalog failures with the discovery diagnostics
  /// collected on this connection, de-duplicated by code/message/phase.
  List<Object?> _catalogFailures(JsonMap projected) {
    final seen = <String>{};
    return <Object?>[...agyList(projected['failures']), ...failures].where((item) {
      final entry = agyMap(item);
      final key = '${agyString(entry['code'])}|${agyString(entry['message'])}|${agyString(entry['phase'])}';
      return seen.add(key);
    }).toList(growable: false);
  }

  @override
  bool closed = false;

  /// Mirrors the Web client's capability check: both the generic ACP domain
  /// and the Antigravity backend must be advertised by the Host.
  bool get hasAgy {
    final probed = explicitCapabilities;
    if (probed != null) return probed.available;
    final session = remote?.session;
    if (session == null) return false;
    return session.capabilities.contains(acpCapability) && session.capabilities.contains(agyCapability);
  }

  Future<AgyTransport> get transport {
    final existing = _transport;
    if (existing != null) return Future<AgyTransport>.value(existing);
    return _transportFuture ??= _createTransport();
  }

  Future<AgyTransport> _createTransport() async {
    final session = remote?.session;
    if (session == null || session.isClosed) {
      throw const ClientModeError('FEATURE_NOT_SUPPORTED', 'The remote Host exposes no supported Harness transport.');
    }
    final capabilities = explicitCapabilities ??
        (await AgyCapabilities.probeWithRetry(session.rpc)).requireConsistentSessionFormats();
    for (final diagnostic in capabilities.diagnostics) {
      _recordFailure('capabilities', diagnostic);
    }
    if (!capabilities.available) {
      final details = capabilities.diagnostics.map((item) => agyString(item['message']) ?? '').join('; ');
      throw ClientModeError(
        'FEATURE_NOT_SUPPORTED',
        'The remote Host exposes no supported Harness transport.${details.isEmpty ? '' : ' Diagnostics: $details'}',
      );
    }
    final created = AgyTransport(session.rpc, capabilities);
    _transport = created;
    _transportFuture = null;
    return created;
  }

  Future<AgyClient> get client async => AgyClient(await transport);

  /// The Host only trusts a cwd recorded by `dsh/sessionList`; both
  /// `dsh/selectModel` and `session/prompt` reject a `cwd` field in their
  /// strict schemas. Bind and load once per ACP session per tunnel, then let
  /// the real model/prompt call surface its own error if it still fails.
  Future<void> _prebindSession(AgyClient api, AgySession session, {bool force = false}) async {
    if (!force && _preboundSessions.contains(session.nativeId)) return;
    try {
      await agyShortRetry(() async {
        await api.prebindSession(session.nativeId, session.cwd);
        await api.loadSession(session.nativeId);
      });
      _preboundSessions.add(session.nativeId);
      _clearFailures('prebind');
    } on Object catch (error) {
      // Best effort: the session may already be active on the Host. The real
      // call below reports its own diagnostic if it is not.
      _recordFailure('prebind', error);
    }
  }

  /// Called by the carrier whenever the tunnel opens a fresh Host session.
  void onSessionReconnected() {
    final previous = _transport;
    _transport = null;
    _transportFuture = null;
    catalog = AgyCatalog(const <AgyWorkspace>[], const <AgySession>[]);
    _catalogFuture = null;
    _hydrated.clear();
    _hydrating.clear();
    _preboundSessions.clear();
    _failures.clear();
    live.invalidateAll();
    if (previous != null) unawaited(previous.close());
  }

  @override
  int nextProjectionSeq() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastProjectionSeq = now > _lastProjectionSeq ? now : _lastProjectionSeq + 1;
    return _lastProjectionSeq;
  }

  Future<AgyCatalog> currentCatalog() => _catalogFuture ?? Future<AgyCatalog>.value(catalog);

  Future<AgyCatalog> refreshCatalog({bool force = false}) {
    if (!force) {
      final current = _catalogFuture;
      if (current != null) return current;
    }
    final future = _refreshCatalog();
    _catalogFuture = future;
    return future.whenComplete(() {
      if (identical(_catalogFuture, future)) _catalogFuture = null;
    });
  }

  Future<AgyCatalog> _refreshCatalog() async {
    try {
      final loaded = await agyLoadCatalog(await client);
      catalog = loaded;
      final home = loaded.workspaces.isEmpty ? null : loaded.workspaces.first.path;
      events.setSelectedWorkspace(home);
      events.publishWorkspaceBaseline(loaded);
      _clearFailures('catalog');
      return loaded;
    } on Object catch (error) {
      // Never hide discovery failures in an empty catalog: keep the last
      // good catalog for the UI and surface the diagnostic in `failures`.
      _recordFailure('catalog', error);
      return catalog;
    }
  }

  @override
  AgySession? sessionById(String sessionId) => catalog.byId[agyVirtualId(sessionId)];

  @override
  Future<void> hydrate(AgySession session) {
    if (_hydrated.contains(session.id)) return Future<void>.value();
    final pending = _hydrating[session.id];
    if (pending != null) return pending;
    final future = _hydrate(session);
    _hydrating[session.id] = future;
    return future.whenComplete(() => _hydrating.remove(session.id));
  }

  Future<void> _hydrate(AgySession session) async {
    final raw = await (await client).history(session.nativeId);
    session.events = agyNormalizeHistoryEvents(raw, session);
    _hydrated.add(session.id);
  }

  Future<JsonMap> readHistoryPage(AgySession session, [JsonMap request = const <String, Object?>{}]) async {
    await hydrate(session);
    return agyProjectHistory(<String, Object?>{'events': session.events}, session, request);
  }

  @override
  Future<AgyStreamHandle> openSessionStream(
    String nativeSessionId, {
    required void Function(JsonMap frame) onFrame,
    required void Function(String reason) onClosed,
  }) async =>
      (await client).openSessionStream(nativeSessionId, onFrame: onFrame, onClosed: onClosed);

  @override
  void invalidateHistory(String sessionId) => _hydrated.remove(agyVirtualId(sessionId));

  @override
  void updateTitle(String sessionId, String title) {
    final session = sessionById(sessionId);
    if (session == null) return;
    session.title = title;
    final seq = nextProjectionSeq();
    publishProjection(session.id, 'title', title, seq);
    publishProjection(session.id, 'sessionListMetadata', <String, Object?>{
      'blank': session.blank,
      'lastPromptAt': session.updatedAt == 0 ? null : session.updatedAt,
    }, seq);
  }

  @override
  void setModelSelection(String sessionId, JsonMap selected) {
    final session = sessionById(sessionId);
    if (session == null) return;
    session.selectedModel = selected;
    publishProjection(session.id, 'modelSelection', agyModelSelectionProjection(selected), nextProjectionSeq());
    invalidateHistory(session.id);
  }

  @override
  void setPermissionPreset(String sessionId, String preset) {
    final session = sessionById(sessionId);
    if (session == null) return;
    session.permissionPreset = preset;
    publishProjection(session.id, 'permissions', agyPermissionsProjection(preset), nextProjectionSeq());
  }

  @override
  void publishProjection(String sessionId, String key, Object? value, int seq) =>
      events.publishProjection(sessionId, key, value, seq);

  @override
  void emitRemoteEvent(String type, List<Object?> payload) => events.emitRemoteEvent(type, payload);

  @override
  void emitApproval(String eventId, String requestHandle, JsonMap request, {String? sessionId}) =>
      events.emitApproval(eventId, requestHandle, request, sessionId: sessionId);

  /// Dispatches a virtual endpoint. Host-owned workspace/tool calls are sent
  /// straight to the physical carrier.
  Future<RpcResult> dispatch(String endpoint, Map<String, Object?> payload) async {
    if (_hostCallEndpoints.contains(endpoint)) return physicalCarrier.call(endpoint, payload);
    if (_physicalEndpoints.contains(endpoint)) return physicalCarrier.call(endpoint, payload);
    try {
      return RpcOk(await _handle(endpoint, <String, Object?>{'args': payload}));
    } on Object catch (error) {
      return agyFailFrom(error);
    }
  }

  /// Returns a virtual stream for an endpoint, or `null` when the physical
  /// carrier must open it.
  Stream<JsonMap>? openStream(String endpoint, Map<String, Object?> payload) {
    if (!hasAgy || _hostStreamEndpoints.contains(endpoint)) return null;
    final request = agyRequestArg(agyCarrierArgs(payload));
    switch (endpoint) {
      case 'workspace/follow':
        return events.workspaceFollow(catalog);
      case 'session/control':
        return events.sessionControl();
      case 'session/follow':
        return live.sessionFollow(request);
      case r'$events':
        return events.remoteEvents();
      case 'job/list':
      case 'job/follow':
        return events.emptyJobStream(endpoint);
      default:
        return null;
    }
  }

  /// Closes all virtual streams and the synthetic ACP transport. The physical
  /// carrier is closed by [AgyVirtualCarrier.close].
  Future<void> close() async {
    if (closed) return;
    closed = true;
    live.close();
    events.close();
    final transport = _transport;
    _transport = null;
    _transportFuture = null;
    if (transport != null) await transport.close();
    _hydrated.clear();
    _hydrating.clear();
  }

  Future<Object?> _handle(String endpoint, JsonMap envelope) async {
    final args = agyCarrierArgs(envelope);
    final request = agyRequestArg(args);

    switch (endpoint) {
      case r'$events/result':
        final resolution = events.resolveApproval(
          request['eventId'] ?? args['eventId'],
          request['result'] ?? request['outcome'],
        );
        if (resolution != null) await (await client).respond(resolution.handle, resolution.decision);
        return null;

      case 'workspace/list':
        final loaded = await refreshCatalog();
        return <String, Object?>{
          'items': loaded.workspaces.map((workspace) => workspace.workspaceView).toList(),
          'archivedSessionIds': const <Object?>[],
          'pinnedSessionIds': const <Object?>[],
          'failures': failures,
        };

      case 'workspace/create':
        final path = agyString(request['path']) ?? agyString(request['cwd']);
        if (path == null || path.isEmpty) {
          throw const AgyFailure('bad-request', 'An AGY working directory is required.');
        }
        final loaded = await refreshCatalog();
        final existing = loaded.workspaces.where((item) => item.path == path).toList();
        if (existing.isEmpty) {
          throw const AgyFailure('workspace-not-found', 'The selected directory is not visible to Antigravity Remote.');
        }
        return <String, Object?>{'workspace': existing.first.workspaceView, 'created': false};

      case 'workspace/rename':
        throw const AgyFailure('workspace-read-only', 'Antigravity virtual Workspaces cannot be renamed.');

      case 'workspace/delete':
        throw const AgyFailure('workspace-read-only', 'Antigravity virtual Workspaces cannot be deleted.');

      case 'workspace/insertBefore':
        return <String, Object?>{
          'workspaceIds': (await refreshCatalog()).workspaces.map((item) => item.id).toList(),
        };

      case 'workspace/insertSessionBefore':
        final sessionId = agyExtractSessionId(request);
        final loaded = await refreshCatalog();
        final workspace = loaded.workspaces.firstWhere(
          (item) => item.sessionIds.contains(sessionId),
          orElse: () => throw const AgyFailure('workspace-not-found', 'The AGY virtual Workspace was not found.'),
        );
        return <String, Object?>{'workspace': workspace.workspaceView};

      case 'workspace/archiveSession':
        throw const AgyFailure('FEATURE_NOT_SUPPORTED', 'Antigravity Remote does not expose session archive.');

      case 'session/list':
        final loaded = await refreshCatalog();
        return <String, Object?>{
          'items': loaded.sessions
              .map((session) => agySessionSummary(session.sessionView)
                ..['blank'] = session.blank
                ..['projections'] = <String, Object?>{
                  'kind': 'sequenced',
                  'asOfSeq': 0,
                  'values': agyProjections(session),
                })
              .toList(),
          'archivedSessionIds': const <Object?>[],
          'pinnedSessionIds': const <Object?>[],
          'failures': failures,
        };

      case 'session/projections':
        return _sessionProjections(request);

      case 'session/search':
        return <String, Object?>{'items': const <Object?>[], 'hasMore': false};

      case 'session/create':
        return _createSession(request);

      case 'session/history':
      case 'session/events':
      case 'session/page':
        final session = _requireSession(request);
        return readHistoryPage(session, <String, Object?>{
          if (agyInt(request['beforeSeq']) case final int beforeSeq?) 'beforeSeq': beforeSeq,
          if (agyInt(request['throughSeq']) case final int throughSeq?) 'throughSeq': throughSeq,
          if (agyPositiveInt(request['maxMessages']) case final int maxMessages?) 'maxMessages': maxMessages,
        });

      case 'session/prompt':
        return _prompt(request);

      case 'session/cancel':
        return _cancel(request);

      case 'session/rename':
        final session = _requireSession(request);
        final title = agyString(request['title']);
        if (title != null && title.trim().isNotEmpty) {
          updateTitle(session.id, title.trim());
        }
        return <String, Object?>{'session': session.sessionView};

      case 'session/updateQueue':
        throw const AgyFailure('queue-item-not-found', 'Antigravity has no DSH steer queue.');

      case 'session/attachment':
        throw const AgyFailure('attachment-error', 'The Antigravity image is not available in this virtual Session.');

      case 'session/canOpenWorkspacePath':
        return false;

      case 'session/modelCatalog':
        return _modelCatalog(request);

      case 'session/models':
        return _models(request);

      case 'session/selectModel':
        return _selectModel(request);

      case 'session/selectPermission':
        return _selectPermission(request);

      case 'host/describe':
        return _describeHost();

      case 'host/listDirectory':
      case 'directoryPicker/list':
        final path = agyString(request['path']) ?? '/';
        return (await client).listDirectory(path);

      case 'skills/list':
        return <String, Object?>{'items': const <Object?>[]};

      case 'commands/list':
        return <String, Object?>{'items': const <Object?>[]};

      default:
        throw AgyFailure('method-not-found', 'AGY virtual Harness does not implement $endpoint.');
    }
  }

  AgySession _requireSession(JsonMap request) {
    final sessionId = agyExtractSessionId(request);
    final session = catalog.byId[sessionId];
    if (session == null) {
      throw AgyFailure('session-not-found', 'The AGY ACP session $sessionId is not registered.');
    }
    return session;
  }

  Future<Object?> _createSession(JsonMap request) async {
    final loaded = await refreshCatalog();
    var cwd = agyString(request['cwd']) ?? agyString(request['path']);
    AgyWorkspace? workspace;
    if (cwd != null) {
      for (final item in loaded.workspaces) {
        if (item.path == cwd) {
          workspace = item;
          break;
        }
      }
    }
    workspace ??= loaded.workspaces.isEmpty ? null : loaded.workspaces.first;
    cwd ??= workspace?.path;
    if (cwd == null || cwd.isEmpty) {
      throw const AgyFailure('workspace-not-found', 'No Antigravity working directory is available.');
    }

    for (final session in loaded.sessions) {
      if (session.blank && !session.running && session.cwd == cwd) {
        return <String, Object?>{
          'sessionId': session.id,
          'workspaceId': workspace?.id ?? agyWorkspaceId(cwd),
          'created': false,
        };
      }
    }

    final nativeId = await (await client).createSession(cwd);
    // A freshly created ACP session is already active and cwd-bound on the
    // Host; do not issue a redundant session/load before its first prompt.
    _preboundSessions.add(nativeId);
    final session = agyRegisterSession(
      loaded,
      workspace ?? AgyWorkspace(id: agyWorkspaceId(cwd), path: cwd, title: agyPathLeaf(cwd)),
      nativeId,
      title: 'Untitled Session',
    );
    session.blank = true;
    events.publishWorkspaceBaseline(loaded);
    return <String, Object?>{
      'sessionId': session.id,
      'workspaceId': workspace?.id ?? agyWorkspaceId(cwd),
      'created': true,
    };
  }

  Future<Object?> _prompt(JsonMap request) async {
    final session = _requireSession(request);
    final images = agyValidatePromptImages(request['content']);
    if (images == null) {
      throw const AgyFailure(
        'attachment-error',
        'AGY virtual Sessions accept text and pasted PNG, JPEG, WebP, or GIF images only.',
      );
    }
    final text = agyExtractPromptText(request['content']);
    if (text.isEmpty && images.isEmpty) {
      throw const AgyFailure('bad-request', 'An AGY prompt must contain text or images.');
    }
    // `session/prompt` has no `cwd` field and Antigravity gets no Host-side
    // preparation: bind the trusted directory and load the session first so
    // an inactive/discovered session behaves like an active one.
    final api = await client;
    await _prebindSession(api, session);

    final liveFollow = await live.ensureFollow(session);
    live.beginPrompt(session, text);
    session.blank = false;
    session.updatedAt = DateTime.now().millisecondsSinceEpoch;
    session.running = true;
    try {
      await agyShortRetry(() => api.prompt(session.nativeId, text, images), attempts: 2);
    } on Object catch (error) {
      if (!agyIsTransientError(error)) {
        live.abortTurn(session.id, kind: 'error');
        session.running = false;
        rethrow;
      }
      // The Host may still consider the session inactive. Force a fresh
      // sessionList binding + session/load and make one last attempt while the
      // live turn is open, then surface the real error if that also fails.
      _recordFailure('prompt', error);
      await _prebindSession(api, session, force: true);
      try {
        await api.prompt(session.nativeId, text, images);
      } on Object catch (retryError) {
        _recordFailure('prompt', retryError);
        live.abortTurn(session.id, kind: 'error');
        session.running = false;
        rethrow;
      }
    }
    _clearFailures('prompt');
    invalidateHistory(session.id);
    unawaited(refreshCatalog(force: true));
    return <String, Object?>{'accepted': true, 'streamId': liveFollow.nativeId};
  }

  Future<Object?> _cancel(JsonMap request) async {
    final session = _requireSession(request);
    session.running = false;
    live.abortTurn(session.id);
    await (await client).cancel(session.nativeId);
    invalidateHistory(session.id);
    return <String, Object?>{'accepted': true};
  }

  Future<Object?> _sessionProjections(JsonMap request) async {
    final session = _requireSession(request);
    final page = await readHistoryPage(session, const <String, Object?>{'maxMessages': 1});
    final cursor = agyInt(page['cursor']) ?? -1;
    return agySessionSummary(session.sessionView)
      ..['blank'] = cursor < 0
      ..['projections'] = <String, Object?>{
        'kind': 'sequenced',
        'asOfSeq': cursor,
        'values': agyProjections(session),
      };
  }

  /// Fetches the raw `dsh/sessionModels` payload for one session. Failures are
  /// values, never swallowed into an empty catalog: the native model picker
  /// shows them through the catalog `failures` list.
  Future<AgyFetchResult> _fetchModels(AgySession session) async {
    if (!(explicitCapabilities?.models ?? false) && !(await transport).capabilities.models) {
      const failure = AgyFailure('FEATURE_NOT_SUPPORTED', 'The Host does not expose an AGY model catalog.');
      _recordFailure('models', failure);
      return const AgyFetchResult.failure(failure);
    }
    try {
      final api = await client;
      await _prebindSession(api, session);
      final raw = agyMap(await agyShortRetry(() => api.models(session.nativeId)));
      if (raw.isEmpty) {
        return const AgyFetchResult.failure(
          AgyFailure('EMPTY_MODEL_CATALOG', 'The Host returned an empty Antigravity model catalog.'),
        );
      }
      return AgyFetchResult.value(raw);
    } on Object catch (error) {
      _recordFailure('models', error);
      return AgyFetchResult.failure(error);
    }
  }

  Future<JsonMap> _modelsFor(AgySession session) async {
    final raw = (await _fetchModels(session)).raw;
    if (raw == null) {
      // Keep the wire shape but surface why the picker has no models instead
      // of presenting a silent empty Antigravity group.
      return <String, Object?>{
        'current': session.selectedModel.isNotEmpty
            ? session.selectedModel
            : <String, Object?>{'provider': agyBackend, 'model': 'host-settings'},
        'routable': true,
        'groups': const <Object?>[],
        'failures': _catalogFailures(const <String, Object?>{}),
      };
    }
    final current = agyMap(raw['current']);
    final projected = agyModelCatalogProjection(raw);
    // The per-session endpoint keeps the wire shape (current/routable) while
    // groups and failures come from the shared group-shaped projection.
    return <String, Object?>{
      'current': current.isNotEmpty
          ? current
          : (session.selectedModel.isNotEmpty
              ? session.selectedModel
              : <String, Object?>{'provider': agyBackend, 'model': 'host-settings'}),
      'routable': agyBool(raw['routable'] ?? true),
      'groups': projected['groups'],
      'failures': _catalogFailures(projected),
    };
  }

  /// The official `preferredSessionId`: inside the selected workspace prefer
  /// the most recent non-running non-blank session, then any non-running one,
  /// then the first listed session; with no selected workspace fall back to
  /// the most recent non-blank session across all AGY workspaces.
  AgySession? _preferredSession() {
    final home = events.selectedWorkspace;
    final catalog = this.catalog;
    AgyWorkspace? selected;
    if (home != null) {
      for (final workspace in catalog.workspaces) {
        if (workspace.path == home || workspace.id == home) {
          selected = workspace;
          break;
        }
      }
    }
    final candidates = selected?.sessionIds ?? const <String>[];
    if (candidates.isEmpty) {
      AgySession? best;
      for (final session in catalog.sessions) {
        if (session.blank) continue;
        if (best == null || session.updatedAt > best.updatedAt) best = session;
      }
      return best;
    }
    var bestUpdatedAt = -1;
    AgySession? best;
    for (final id in candidates) {
      final session = catalog.byId[id];
      if (session == null || session.running || session.blank) continue;
      if (session.updatedAt > bestUpdatedAt) {
        bestUpdatedAt = session.updatedAt;
        best = session;
      }
    }
    if (best != null) return best;
    for (final id in candidates) {
      final session = catalog.byId[id];
      if (session != null && !session.running) return session;
    }
    for (final id in candidates) {
      final session = catalog.byId[id];
      if (session != null) return session;
    }
    return null;
  }

  Future<Object?> _modelCatalog(JsonMap request) async {
    AgySession? session;
    try {
      session = _requireSession(request);
    } on Object {
      session = null;
    }
    // Without an explicit session the catalog is resolved for the preferred
    // AGY session, mirroring the official virtual harness.
    session ??= _preferredSession();
    if (session == null) {
      final empty = agyEmptyModelCatalog();
      return <String, Object?>{...empty, 'failures': _catalogFailures(empty)};
    }
    final fetched = await _fetchModels(session);
    if (fetched.raw == null) {
      final empty = agyEmptyModelCatalog();
      return <String, Object?>{...empty, 'failures': _catalogFailures(empty)};
    }
    final projected = agyModelCatalogProjection(fetched.raw!);
    // When the preferred session carries a selection it wins over the
    // Host-reported default.
    if (session.selectedModel.isNotEmpty) projected['default'] = session.selectedModel;
    return <String, Object?>{...projected, 'failures': _catalogFailures(projected)};
  }

  Future<Object?> _models(JsonMap request) => _modelsFor(_requireSession(request));

  JsonMap _selectionFromRequest(JsonMap request, AgySession session) {
    final direct = agyMap(request['selection']);
    final modelId = agyString(direct['modelId']) ??
        agyString(direct['model']) ??
        agyString(request['modelId']) ??
        agyString(request['model']);
    final effort = agyString(direct['reasoningEffort']) ??
        agyString(direct['effort']) ??
        agyString(request['reasoningEffort']) ??
        agyString(request['effort']);
    if (modelId == null || modelId.isEmpty) {
      throw const AgyFailure('bad-request', 'A model id is required.');
    }
    final selection = <String, Object?>{...session.selectedModel};
    selection['provider'] = agyBackend;
    selection['model'] = modelId;
    if (effort != null) {
      selection['reasoningEffort'] = effort;
    } else {
      selection.remove('reasoningEffort');
    }
    return selection;
  }

  Future<Object?> _selectModel(JsonMap request) async {
    final session = _requireSession(request);
    final selection = _selectionFromRequest(request, session);
    final api = await client;
    // `dsh/selectModel` rejects `cwd` but the Host needs a trusted session→cwd
    // binding before it can resolve the backend's model catalog.
    await _prebindSession(api, session);
    try {
      final selected = await agyShortRetry(() => api.selectModel(session.nativeId, selection));
      setModelSelection(session.id, selected);
      _clearFailures('selectModel');
      return <String, Object?>{'selected': selected};
    } on Object catch (error) {
      _recordFailure('selectModel', error);
      rethrow;
    }
  }

  Future<Object?> _selectPermission(JsonMap request) async {
    final session = _requireSession(request);
    final preset = agyString(request['preset']) ??
        agyString(request['permissionMode']) ??
        agyString(agyMap(request['selection'])['preset']);
    if (!agyIsPermissionPreset(preset)) {
      throw AgyFailure('invalid-preset', 'unknown preset "$preset"');
    }
    final applied = await (await client).selectPermission(session.nativeId, preset!);
    setPermissionPreset(session.id, applied);
    return <String, Object?>{'preset': applied};
  }

  Future<Object?> _describeHost() async {
    final loaded = await refreshCatalog();
    final path = loaded.workspaces.isEmpty ? '' : loaded.workspaces.first.path;
    return <String, Object?>{
      'version': 'Antigravity ACP Remote',
      'cwd': path,
      'home': path,
      'provider': 'Antigravity',
      'attachedSessions': loaded.sessions.length,
      'canOpenPath': loaded.workspaces.isNotEmpty,
      'failures': failures,
      'capabilityDiagnostics': explicitCapabilities?.diagnostics ?? const <JsonMap>[],
    };
  }
}

/// ACP tool endpoints owned by the Host; the virtual Harness never handles
/// their payloads itself.
const Set<String> agyHostCallEndpoints = <String>{
  'workspaceFiles/list',
  'workspaceFiles/stat',
  'workspaceFiles/read',
  'workspaceFiles/readBytes',
  'workspaceFiles/readAll',
  'terminal/environment',
  'terminal/shells',
  'terminal/list',
  'terminal/create',
  'terminal/write',
  'terminal/resize',
  'terminal/rename',
  'terminal/close',
};

const Set<String> _hostCallEndpoints = agyHostCallEndpoints;

/// Physical-Harness endpoints that the virtual Harness must never answer: they
/// pass straight through to the physical carrier.
const Set<String> _physicalEndpoints = <String>{
  'session/fork',
  'session/openWorkspacePath',
  'commands/execute',
};

const Set<String> _hostStreamEndpoints = <String>{
  'workspaceFiles/changes',
  'terminal/follow',
  'terminal/retain',
};

/// The carrier wrapper. Only `AgyVirtualCarrier` needs to be installed by
/// `RemoteAccount`; no UI, command or carrier API changes are required.
DshCarrier _agyPhysicalCarrier(DshCarrier inner) =>
    inner is DshCarrierWrapper ? (inner as DshCarrierWrapper).physicalCarrier : inner;

class AgyVirtualCarrier extends DshCarrier implements DshCarrierWrapper {
  AgyVirtualCarrier(this.inner, {String? hostDeviceId, AgyCapabilities? capabilities})
      : hostDeviceId = hostDeviceId ?? inner.hostVersion ?? 'agy-host',
        harness = AgyVirtualHarness(
          hostCarrier: inner,
          remote: _agyPhysicalCarrier(inner) is RemoteTunnelCarrier
              ? _agyPhysicalCarrier(inner) as RemoteTunnelCarrier
              : null,
          hostDeviceId: hostDeviceId ?? inner.hostVersion ?? 'agy-host',
          capabilities: capabilities,
        ) {
    final physical = _agyPhysicalCarrier(inner);
    final remoteCarrier = physical is RemoteTunnelCarrier ? physical : null;
    if (remoteCarrier != null) {
      _sessionSub = remoteCarrier.sessions.listen((_) => harness.onSessionReconnected());
    }
  }

  final DshCarrier inner;
  final String hostDeviceId;
  final AgyVirtualHarness harness;

  StreamSubscription<RemoteHostSession>? _sessionSub;

  @override
  DshCarrier get physicalCarrier => _agyPhysicalCarrier(inner);

  @override
  String get kind => 'agy+${inner.kind}';

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
    'session/history',
    'session/events',
    'session/page',
    'session/follow',
    'session/prompt',
    'session/control',
    'session/cancel',
    'session/fork',
    'session/openWorkspacePath',
    'session/rename',
    'session/updateQueue',
    'session/attachment',
    'session/canOpenWorkspacePath',
    'session/modelCatalog',
    'session/models',
    'session/selectModel',
    'session/selectPermission',
    'host/describe',
    'host/listDirectory',
    'directoryPicker/list',
    'skills/list',
    'job/list',
    'job/follow',
    'commands/list',
    'commands/execute',
  };

  @override
  bool allowsEndpoint(String endpoint) {
    if (dshOnlyRemoteEndpoints.contains(endpoint)) return false;
    return (harness.hasAgy && _virtualEndpoints.contains(endpoint)) || inner.allowsEndpoint(endpoint);
  }

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    // DSH-only writes never reach the physical Harness through an AGY
    // connection, even if a stale UI or an older build asks for them.
    if (dshOnlyRemoteEndpoints.contains(endpoint)) {
      throw const AgyFailure('FEATURE_NOT_SUPPORTED', 'Antigravity Remote does not expose session archive.');
    }
    if (_virtualEndpoints.contains(endpoint) && harness.hasAgy) {
      return harness.dispatch(endpoint, args);
    }
    return inner.call(endpoint, args, timeout: timeout);
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final base = _agyPhysicalCarrier(inner);
    // The virtual streams need the Host session (and its capabilities) open
    // before the link is built, otherwise `hasAgy` is still false here and
    // every AGY stream would be forwarded to the physical carrier.
    if (base is RemoteTunnelCarrier) await base.ensureSession();
    final physical = await inner.openLink(options);
    return _AgyVirtualLink(physical, harness);
  }

  @override
  Future<void> close() async {
    await _sessionSub?.cancel();
    _sessionSub = null;
    await harness.close();
    await inner.close();
  }
}

/// Forwards physical link frames verbatim, answering only the virtual streams.
class _AgyVirtualLink implements DshMuxLink {
  _AgyVirtualLink(this.physical, this.harness);

  final DshMuxLink physical;
  final AgyVirtualHarness harness;

  final Set<String> _virtualStreams = <String>{};
  final Map<String, StreamSubscription<JsonMap>> _subscriptions = <String, StreamSubscription<JsonMap>>{};

  DshMuxFrameHandler? _onFrame;

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
    physical.start(
      onFrame: (frame) {
        final streamId = agyString(frame['streamId']);
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
            'code': agyErrorCode(error) ?? 'internal',
            'message': agyErrorMessage(error),
            'details': const <String, Object?>{},
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
    for (final id in _virtualStreams.toList(growable: false)) {
      _virtualStreams.remove(id);
      await _subscriptions.remove(id)?.cancel();
    }
    await physical.close(code, reason);
  }
}
