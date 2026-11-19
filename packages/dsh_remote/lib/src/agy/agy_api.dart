/// Thin Dart client for the Host's `agent.acp.*` transport plus the AGY
/// domain calls used by the virtual Harness.
///
/// The event subscription is installed in the constructor, before any
/// `agent.acp.stream.open` RPC, because `RemoteRpcClient.events` is a
/// synchronous broadcast stream.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../channel/rpc_client.dart';
import '../util/bytes.dart';
import 'agy_contract.dart';
import 'agy_image_codec.dart';
import 'agy_values.dart';

/// Outbound ACP methods accepted by `dist/acp/method-policy.js`.
///
/// `dsh/sessionArchive` is intentionally present in the Host allowlist but
/// absent from the virtual Harness (it is OpenCode only).
const Set<String> agyAllowedAcpMethods = <String>{
  'initialize',
  'session/new',
  'session/load',
  'session/prompt',
  'session/cancel',
  'dsh/directoryList',
  'dsh/workspaceList',
  'dsh/sessionList',
  'dsh/sessionHistory',
  'dsh/sessionArchive',
  'dsh/toolCall',
  'dsh/sessionModels',
  'dsh/selectModel',
  'dsh/selectPermission',
};

typedef AgyFrameHandler = void Function(Map<String, Object?> frame);
typedef AgyStreamClosedHandler = void Function(String reason);

/// One Host-side ACP stream for a single (native) session id.
class AgyStreamHandle {
  AgyStreamHandle._(this.streamId, this._close);

  final String streamId;
  final Future<void> Function() _close;
  bool _closed = false;

  bool get isClosed => _closed;

  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    return _close();
  }
}

/// Multiplexes `agent.acp.frame` / `agent.acp.stream.closed` across open
/// streams. The Web client's `frameMatchesSubscription` rules are copied
/// verbatim, including session-scoped `session:<id>` delivery.
class AgyStreamMux {
  final Map<String, AgyFrameHandler> _frames = <String, AgyFrameHandler>{};
  final Map<String, AgyStreamClosedHandler> _closes = <String, AgyStreamClosedHandler>{};
  final Map<String, String> _sessionByStream = <String, String>{};

  void handleEvent(RemoteEvent event) {
    final data = asMap(event.data);
    if (data == null) return;
    final streamId = asString(data['streamId']);
    if (streamId == null) return;
    switch (event.event) {
      case 'agent.acp.frame':
        final frame = asMap(data['frame']);
        if (frame == null || frame['method'] is! String) return;
        for (final entry in _frames.entries.toList(growable: false)) {
          if (_matches(data, entry.key, _sessionByStream[entry.key] ?? '')) {
            entry.value(frame);
          }
        }
      case 'agent.acp.stream.closed':
        final close = _closes.remove(streamId);
        _frames.remove(streamId);
        _sessionByStream.remove(streamId);
        close?.call(asString(data['reason']) ?? 'closed');
    }
  }

  static bool _matches(JsonMap data, String streamId, String sessionId) {
    if (data['streamId'] == streamId) return true;
    if (data['streamId'] == 'session:$sessionId') return true;
    final frame = data['frame'];
    final params = asMapOrEmpty(frame is Map<String, Object?> ? frame['params'] : null);
    if (params.isEmpty && frame is! Map<String, Object?>) return false;
    if (params['sessionId'] == sessionId) return true;
    return asMapOrEmpty(params['update'])['sessionId'] == sessionId;
  }

  void register({
    required String streamId,
    required String sessionId,
    required bool tool,
    required AgyFrameHandler onFrame,
    required AgyStreamClosedHandler onClosed,
  }) {
    if (tool) {
      _frames[streamId] = (frame) {
        final value = asMapOrEmpty(asMapOrEmpty(frame['params'])['value']);
        if (asString(value['streamId']) == streamId) onFrame(frame);
      };
    } else {
      _frames[streamId] = onFrame;
    }
    _closes[streamId] = onClosed;
    _sessionByStream[streamId] = sessionId;
  }

  void unregister(String streamId) {
    _frames.remove(streamId);
    _closes.remove(streamId);
    _sessionByStream.remove(streamId);
  }

  /// Host reconnect/channel loss closes every local stream exactly once.
  void failAll() {
    final pending = Map<String, AgyStreamClosedHandler>.from(_closes);
    _frames.clear();
    _closes.clear();
    _sessionByStream.clear();
    pending.forEach((streamId, close) => close('peer-disconnected'));
  }

  bool get isEmpty => _frames.isEmpty && _closes.isEmpty;
}

/// Low-level transport plus AGY domain calls.
class AgyTransport {
  AgyTransport(this._rpc, this.capabilities) {
    _eventSub = _rpc.events.listen(_mux.handleEvent);
    unawaited(_rpc.done.then((_) {
      _closed = true;
      _mux.failAll();
    }));
  }

  final RemoteRpcClient _rpc;
  final AgyCapabilities capabilities;
  final AgyStreamMux _mux = AgyStreamMux();
  StreamSubscription<RemoteEvent>? _eventSub;
  bool _closed = false;

  bool get isClosed => _closed;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _mux.failAll();
    await _eventSub?.cancel();
    _eventSub = null;
  }

  Future<Object?> _raw(String method, Map<String, Object?> params, {Duration? timeout}) async {
    if (_closed || _rpc.isClosed) {
      throw const AgyFailure('TRANSPORT_CLOSED', 'The ACP remote channel is closed.');
    }
    try {
      return await _rpc.call(method, params, timeout: timeout);
    } on RemoteRpcException catch (error) {
      throw AgyFailure(error.code, error.message);
    }
  }

  /// One ACP method call. `session/prompt` gets the Host's 10 minute deadline.
  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    Duration? timeout,
  }) async {
    if (!agyAllowedAcpMethods.contains(method)) {
      throw AgyFailure('METHOD_NOT_ALLOWED', 'The ACP method "$method" is not allowed.');
    }
    final resolvedTimeout = timeout ?? (method == 'session/prompt' ? agyPromptTimeout : null);
    final encodedLength = utf8.encode(jsonEncode(<String, Object?>{'method': method, 'params': params})).length;
    if (encodedLength > directRemoteCallBytes && capabilities.transfer && !_closed) {
      return agyBusiness(await transferCall(method, params, timeout: resolvedTimeout));
    }
    return agyBusiness(await _raw(
      'agent.acp.call',
      <String, Object?>{'method': method, 'params': params},
      timeout: resolvedTimeout,
    ));
  }

  /// Chunked five-step ACP transfer (peer-bridge.js verbatim).
  Future<Object?> transferCall(
    String method,
    Map<String, Object?> params, {
    Duration? timeout,
  }) async {
    if (!capabilities.transfer) {
      throw const AgyFailure('FEATURE_NOT_SUPPORTED', 'The Host does not support ACP transfers.');
    }
    final encoded = Uint8List.fromList(
      utf8.encode(jsonEncode(<String, Object?>{'method': method, 'params': params})),
    );
    if (encoded.isEmpty || encoded.length > maxAgyTransferBytes) {
      throw const AgyFailure('REQUEST_TOO_LARGE', 'The ACP transfer request exceeds the bounded limit.');
    }
    final transferId = agyUuid();
    final totalChunks = encoded.length ~/ agyTransferChunkBytes +
        (encoded.length % agyTransferChunkBytes == 0 ? 0 : 1);
    var opened = false;
    try {
      await _raw('agent.acp.transfer.open', <String, Object?>{
        'transferId': transferId,
        'totalBytes': encoded.length,
        'totalChunks': totalChunks,
      });
      opened = true;
      for (var index = 0; index < totalChunks; index += 1) {
        final start = index * agyTransferChunkBytes;
        final end = (start + agyTransferChunkBytes < encoded.length) ? start + agyTransferChunkBytes : encoded.length;
        await _raw('agent.acp.transfer.chunk', <String, Object?>{
          'transferId': transferId,
          'index': index,
          'data': base64Encode(encoded.sublist(start, end)),
        });
      }
      final committed = agyMap(await _raw('agent.acp.transfer.commit', <String, Object?>{
        'transferId': transferId,
      }, timeout: timeout));
      final kind = asString(committed['kind']);
      if (kind == 'inline') return agyBusiness(committed['response']);
      if (kind != 'chunked') {
        throw const AgyFailure('INVALID_RESPONSE', 'Invalid ACP transfer descriptor.');
      }
      final returnedId = asString(committed['transferId']);
      final totalBytes = agyInt(committed['totalBytes']);
      final committedChunks = asInt(committed['totalChunks']);
      final expectedChunks = totalBytes == null
          ? null
          : (totalBytes ~/ agyTransferChunkBytes + (totalBytes % agyTransferChunkBytes == 0 ? 0 : 1));
      if (returnedId != transferId ||
          totalBytes == null ||
          totalBytes < 1 ||
          totalBytes > maxAgyTransferBytes ||
          committedChunks == null ||
          expectedChunks == null ||
          committedChunks != expectedChunks) {
        throw const AgyFailure('INVALID_RESPONSE', 'Invalid ACP transfer descriptor.');
      }
      final chunks = <Uint8List>[];
      for (var index = 0; index < committedChunks; index += 1) {
        final part = agyMap(await _raw('agent.acp.transfer.read', <String, Object?>{
          'transferId': transferId,
          'index': index,
        }));
        final data = asString(part['data']);
        final expected = agyInt(part['index']) == index && asString(part['transferId']) == transferId && data != null;
        if (!expected) {
          throw const AgyFailure('INVALID_RESPONSE', 'Invalid ACP transfer chunk.');
        }
        late final Uint8List chunk;
        try {
          chunk = base64Decode(data);
        } on FormatException {
          throw const AgyFailure('INVALID_RESPONSE', 'Invalid ACP transfer chunk.');
        }
        final expectedBytes = index == committedChunks - 1
            ? totalBytes - index * agyTransferChunkBytes
            : agyTransferChunkBytes;
        if (chunk.length != expectedBytes || base64Encode(chunk) != data) {
          throw const AgyFailure('INVALID_RESPONSE', 'Invalid ACP transfer chunk size or encoding.');
        }
        chunks.add(chunk);
      }
      final bytes = concatBytes(chunks);
      try {
        return agyBusiness(jsonDecode(const Utf8Decoder(allowMalformed: false).convert(bytes)));
      } on FormatException {
        throw const AgyFailure('INVALID_RESPONSE', 'The ACP transfer does not contain a valid request.');
      }
    } finally {
      if (opened) {
        try {
          await _raw('agent.acp.transfer.close', <String, Object?>{'transferId': transferId});
        } on Object {
          // Best-effort teardown, matching the official client.
        }
      }
    }
  }

  Future<Object?> respond(String requestHandle, String decision) => _raw('agent.acp.respond', <String, Object?>{
        'requestHandle': requestHandle,
        'decision': decision,
      });

  /// Registers the event listener before opening the stream, then opens it.
  Future<AgyStreamHandle> openStream(
    String sessionId, {
    required AgyFrameHandler onFrame,
    required AgyStreamClosedHandler onClosed,
    bool tool = false,
  }) async {
    if (_closed || _rpc.isClosed) {
      throw const AgyFailure('TRANSPORT_CLOSED', 'The ACP remote channel is closed.');
    }
    final streamId = agyUuid();
    var settled = false;
    void closeLocal(String reason) {
      if (settled) return;
      settled = true;
      _mux.unregister(streamId);
      onClosed(reason);
    }

    _mux.register(
      streamId: streamId,
      sessionId: sessionId,
      tool: tool,
      onFrame: onFrame,
      onClosed: closeLocal,
    );
    try {
      await _raw('agent.acp.stream.open', <String, Object?>{
        'streamId': streamId,
        'sessionId': sessionId,
        if (tool) 'tool': true,
      });
    } on Object {
      _mux.unregister(streamId);
      rethrow;
    }
    return AgyStreamHandle._(streamId, () async {
      closeLocal('client-closed');
      try {
        await _raw('agent.acp.stream.close', <String, Object?>{'streamId': streamId});
      } on Object {
        // Closing an already dead stream must not surface to the UI.
      }
    });
  }
}

/// AGY domain calls used by the virtual Harness.
class AgyClient {
  AgyClient(this.transport);

  final AgyTransport transport;

  Future<JsonMap> initialize() async => agyMap(await transport.call('initialize', <String, Object?>{
        'protocolVersion': 1,
        'clientInfo': <String, Object?>{'name': 'dsh-ios', 'version': '1'},
      }));

  Future<String> createSession(String cwd, {String? mode}) async {
    final result = agyMap(await transport.call('session/new', <String, Object?>{
      'cwd': cwd,
      'mcpServers': <Object?>[],
      if (mode != null) 'mode': mode,
      'backend': agyBackend,
    }));
    final sessionId = agyString(result['sessionId']);
    if (sessionId == null || sessionId.isEmpty) {
      throw const AgyFailure('INVALID_RESPONSE', 'ACP session/new did not return sessionId.');
    }
    return sessionId;
  }

  Future<void> loadSession(String sessionId) async {
    await transport.call('session/load', <String, Object?>{
      'sessionId': sessionId,
      'backend': agyBackend,
    });
  }

  Future<void> prompt(String sessionId, String text, List<JsonMap> images) async {
    final params = agyPromptParams(sessionId, text, images);
    final encodedLength = utf8.encode(jsonEncode(params)).length;
    if (images.isNotEmpty || encodedLength > maxAcpPromptBytes) {
      await transport.transferCall('session/prompt', params, timeout: agyPromptTimeout);
      return;
    }
    await transport.call('session/prompt', params, timeout: agyPromptTimeout);
  }

  Future<void> cancel(String sessionId) async {
    await transport.call('session/cancel', <String, Object?>{'sessionId': sessionId});
  }

  /// Discovery failures are propagated, never reduced to an empty list, so
  /// the virtual Harness can surface them in the catalog `failures`.
  Future<List<JsonMap>> listWorkspaces() async {
    final result = await transport.call('dsh/workspaceList', <String, Object?>{'backend': agyBackend});
    return agyList(result).map(agyMap).where((item) => agyString(item['path']) != null).toList();
  }

  /// `dsh/sessionList({path: cwd})` is what writes the Host's trusted
  /// session→cwd binding. No `cwd` key is sent: the strict schema rejects it.
  Future<List<JsonMap>> listSessions(String path, {int limit = 30}) async {
    final result = await transport.call('dsh/sessionList', agyPrebindParams(path, limit: limit));
    return agyList(agyMap(result)['items']).map(agyMap).toList();
  }

  /// Prebinds [sessionId] to [cwd] on the Host before `dsh/selectModel` or
  /// `session/prompt`. Those strict schemas reject `cwd`, so the trusted
  /// directory must arrive through `dsh/sessionList` first.
  Future<void> prebindSession(String sessionId, String cwd) async {
    if (sessionId.isEmpty || cwd.isEmpty) return;
    await listSessions(cwd, limit: 100);
  }

  Future<List<Object?>> history(String sessionId) async {
    final result = await transport.transferCall('dsh/sessionHistory', <String, Object?>{
      'sessionId': sessionId,
      'backend': agyBackend,
    }).catchError((Object _) => <String, Object?>{'events': <Object?>[]});
    return agyList(agyMap(result)['events']);
  }

  Future<JsonMap> models(String sessionId) async {
    if (!transport.capabilities.models) {
      throw const AgyFailure('METHOD_NOT_ALLOWED', 'The Host does not expose an AGY model catalog.');
    }
    return agyMap(await transport.call('dsh/sessionModels', <String, Object?>{
      'sessionId': sessionId,
      'backend': agyBackend,
    }));
  }

  Future<JsonMap> selectModel(String sessionId, JsonMap selection) async {
    final provider = asString(selection['provider']);
    final model = asString(selection['model']);
    if (provider != agyBackend || model == null || model.isEmpty) {
      throw const AgyFailure('INVALID_MESSAGE', 'The model provider does not match the ACP backend.');
    }
    if (!transport.capabilities.modelLoad) {
      await loadSession(sessionId);
    }
    final params = agySelectModelParams(sessionId, model, agyString(selection['reasoningEffort']));
    final result = agyMap(await transport.call('dsh/selectModel', params));
    final selected = agyMap(result['selected']);
    if (agyString(selected['provider']) != agyBackend || agyString(selected['model']) == null) {
      throw const AgyFailure('INVALID_RESPONSE', 'ACP did not confirm the selected model.');
    }
    return selected;
  }

  Future<String> selectPermission(String sessionId, String preset) async {
    if (preset != 'workspace-write' && preset != 'danger-full-access') {
      throw AgyFailure('invalid-preset', 'unknown preset "$preset"');
    }
    final result = agyMap(await transport.call('dsh/selectPermission', <String, Object?>{
      'sessionId': sessionId,
      'backend': agyBackend,
      'preset': preset,
    }));
    return agyString(result['preset']) ?? preset;
  }

  Future<Object?> toolCall(String sessionId, String endpoint, Object? args) async {
    if (!transport.capabilities.workspaceFiles) {
      throw const AgyFailure('METHOD_NOT_ALLOWED', 'The ACP workspace tool is unavailable.');
    }
    final scope = agyToolScope(sessionId);
    if (scope != agyVirtualId(sessionId) || !scope.startsWith('acp:')) {
      throw const AgyFailure('PERMISSION_DENIED', 'The tool scope does not match the ACP session.');
    }
    return transport.call('dsh/toolCall', <String, Object?>{
      'sessionId': scope,
      'workspaceFileScopeId': scope,
      'agentId': agyBackend,
      'backend': agyBackend,
      'endpoint': endpoint,
      'args': args ?? const <String, Object?>{},
    });
  }

  Future<Object?> listDirectory(String path) => transport.call('dsh/directoryList', <String, Object?>{'path': path});

  Future<AgyStreamHandle> openSessionStream(
    String nativeSessionId, {
    required AgyFrameHandler onFrame,
    required AgyStreamClosedHandler onClosed,
  }) =>
      transport.openStream(nativeSessionId, onFrame: onFrame, onClosed: onClosed);

  Future<AgyStreamHandle> openToolStream(
    String nativeSessionId, {
    required AgyFrameHandler onFrame,
    required AgyStreamClosedHandler onClosed,
  }) =>
      transport.openStream(nativeSessionId, onFrame: onFrame, onClosed: onClosed, tool: true);

  Future<void> respond(String requestHandle, String decision) => transport.respond(requestHandle, decision);
}

/// Prompt image validation (AGY wire field is `mimeType`, not `mediaType`).
List<JsonMap>? agyPromptImages(Object? content) => agyValidatePromptImages(content);
