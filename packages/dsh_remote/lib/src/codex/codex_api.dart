/// Codex App Server RPC client (`codex.appserver.v1`), a faithful Dart port of
/// the official Web client's `CodexRemoteClient`
/// (`ds-harness-remote` v0.6.4, client-core `index.js` L65348-65525).
///
/// Every remote Codex call is an outer `codex.app.*` RPC whose envelope is
/// `{method, params}`; large payloads (full history reads, image inputs) and
/// any envelope above [maxDirectCodexCallBytes] go through the five-step
/// chunked transfer (`codex.app.transfer.*`, see `callTransferred`). Live
/// frames arrive on the shared event channel as `codex.app.frame` /
/// `codex.app.stream.closed` events tagged with a client-chosen `streamId`;
/// per protocol rule the event subscription MUST be armed before
/// `codex.app.stream.open` is sent (frames can race the open response), which
/// this class guarantees by subscribing in its constructor.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_remote/src/channel/rpc_client.dart';
import 'package:dsh_remote/src/util/bytes.dart';

/// Encoded bytes per Codex transfer chunk (Host constant, verbatim).
const int codexTransferChunkBytes = 512 * 1024;

/// Largest Codex transfer request or response (Host constant, verbatim).
const int maxCodexTransferBytes = 288 * 1024 * 1024;

/// Envelopes above this size bypass `codex.app.call` and use the chunked
/// transfer pipeline. The official client transfers only large-history reads
/// and image-bearing inputs (both usually far below 2 MiB), so the practical
/// triggers are the semantic rules in [CodexAppApi.request] / [CodexAppApi.call].
const int maxDirectCodexCallBytes = 2 * 1024 * 1024;

/// Inner App Server method allowlist (codex/method-policy.js). Envelopes for
/// methods outside this set are rejected by the Host with METHOD_NOT_ALLOWED.
const Set<String> codexAppMethodAllowlist = {
  'account/read',
  'model/list',
  'project/list',
  'project/create',
  'thread/list',
  'thread/read',
  'dsh/sessionHistory',
  'dsh/sessionAttachment',
  'dsh/directoryList',
  'thread/start',
  'thread/resume',
  'thread/fork',
  'thread/name/set',
  'thread/archive',
  'thread/unarchive',
  'thread/unsubscribe',
  'turn/start',
  'turn/steer',
  'turn/interrupt',
};

/// Reason a Host closed a Codex stream (`codex.app.stream.closed`). Any other
/// wire value normalizes to [failed], exactly like the official client's
/// `codexStreamCloseReason`.
enum CodexStreamCloseReason { cancelled, completed, failed, peerDisconnected }

CodexStreamCloseReason codexStreamCloseReason(Object? value) => switch (value) {
      'cancelled' => CodexStreamCloseReason.cancelled,
      'completed' => CodexStreamCloseReason.completed,
      'peer-disconnected' => CodexStreamCloseReason.peerDisconnected,
      _ => CodexStreamCloseReason.failed,
    };

/// A Host-side refusal of a Codex request. Carries the Remote error code
/// verbatim (`INVALID_MESSAGE`, `CODEX_UNAVAILABLE`, `CODEX_THREAD_BUSY`,
/// `TRANSFER_NOT_FOUND`, `RATE_LIMITED`, ...); [retryable] mirrors the Host's
/// retry hint (e.g. "Too many Codex transfers are active.").
class CodexAppException implements Exception {
  const CodexAppException(
    this.code,
    this.message, {
    this.details = const {},
    this.retryable = false,
  });

  const CodexAppException.transportClosed(String method)
      : this('TRANSPORT_CLOSED', 'Codex RPC $method: the remote channel is closed.');

  factory CodexAppException.fromRpc(RemoteRpcException error) => CodexAppException(
        error.code,
        error.message,
        details: asMapOrEmpty(error.details),
        retryable: error.retryable,
      );

  final String code;
  final String message;
  final Map<String, Object?> details;
  final bool retryable;

  bool get isTransportClosed => code == 'TRANSPORT_CLOSED' || code == 'CLIENT_CLOSED';

  @override
  String toString() => 'CodexAppException($code): $message';
}

/// A Host response the client cannot make sense of (shape violation). The
/// official client raises `RemoteGatewayError('INVALID_MESSAGE', ...)`;
/// we use a distinct code so callers can tell transport errors from bad
/// payloads while keeping the official message text.
class CodexInvalidResponseException extends CodexAppException {
  const CodexInvalidResponseException(String part)
      : super('INVALID_RESPONSE', 'The Host returned an invalid Codex $part.');
}

/// Decisions accepted by `codex.app.respond` (domain.js `parseRespond`:
/// exactly `{requestHandle, decision}` with decision in this set).
enum CodexApprovalDecision { accept, decline, cancel }

/// One live Codex thread stream: frames for a single threadId, multiplexed by
/// a client-chosen [streamId] on the shared remote event channel.
class CodexStreamHandle {
  CodexStreamHandle._(this.streamId, this._api, this._closed)
      : _closePending = true;

  final String streamId;
  final CodexAppApi _api;
  final StreamController<CodexStreamCloseReason> _closed;
  bool _closePending;

  /// Fires once with the normalized close reason when the Host closes the
  /// stream (`codex.app.stream.closed`) or the channel dies (peer-disconnect /
  /// failure synthesis).
  Stream<CodexStreamCloseReason> get closed => _closed.stream;

  bool get isClosed => !_closePending;

  Future<void> close() {
    if (!_closePending) return Future<void>.value();
    _closePending = false;
    return _api.closeStream(streamId);
  }
}

/// Frame callback receiving the inner Codex App Server notification frame
/// `{method, params}` verbatim (e.g. `turn/started`, `turn/completed`,
/// `thread/settings/updated`, sanitized `item/*/requestApproval`).
typedef CodexFrameHandler = void Function(Map<String, Object?> frame);

/// Live frames are `{streamId, frame}` event data; `codex.app.stream.closed`
/// data is `{streamId, reason}`. This decoder filters out foreign streams and
/// strips frames without a string `method` (official-client behavior).
class _CodexStreamMux {
  final Map<String, CodexFrameHandler> handlers = {};
  final Map<String, void Function(CodexStreamCloseReason)> closeHandlers = {};

  void handleEvent(RemoteEvent event) {
    final data = asMap(event.data);
    if (data == null) return;
    final streamId = asString(data['streamId']);
    if (streamId == null) return;
    switch (event.event) {
      case 'codex.app.frame':
        final frame = asMap(data['frame']);
        final handler = handlers[streamId];
        if (frame == null || handler == null) return;
        if (frame['method'] is! String) return;
        handler(frame);
      case 'codex.app.stream.closed':
        final onClose = closeHandlers.remove(streamId);
        handlers.remove(streamId);
        if (onClose == null) return;
        onClose(codexStreamCloseReason(data['reason']));
    }
  }

  /// Channel death or client teardown: fail every open stream exactly once.
  /// Host behavior on app-server swap / peer disconnect is to close all
  /// streams; `peer-disconnected` mirrors that for local transport loss.
  void failAll() {
    if (handlers.isEmpty && closeHandlers.isEmpty) return;
    handlers.clear();
    final pending = Map<String, void Function(CodexStreamCloseReason)>.from(closeHandlers);
    closeHandlers.clear();
    for (final entry in pending.entries) {
      entry.value.call(CodexStreamCloseReason.peerDisconnected);
    }
  }
}

/// Client for the Host's Codex App Server domain over ds-harness-remote.
///
/// One instance per [RemoteRpcClient] (i.e. per Host connection). The stream
/// mux subscribes to the RPC client's shared event broadcast at construction
/// time, before any `codex.app.stream.open` can be issued. When the underlying
/// channel dies every open stream is failed with [CodexStreamCloseReason.peerDisconnected].
class CodexAppApi {
  CodexAppApi(
    this._rpc, {
    this.previewHistory = false,
    this.callTimeout = const Duration(seconds: 65),
    this.transferCallTimeout = const Duration(seconds: 65),
  }) {
    _subscription = _rpc.events.listen(_mux.handleEvent);
    unawaited(_rpc.done.then((_) => _mux.failAll()));
  }

  final RemoteRpcClient _rpc;
  final _CodexStreamMux _mux = _CodexStreamMux();

  /// Whether `dsh/sessionHistory` requests advertise `previewHistory: true`
  /// (Host-side compact-history preview). The official client latches the
  /// flag off permanently after one `INVALID_MESSAGE`; `RESPONSE_TOO_LARGE`
  /// falls back without disabling the flag.
  bool previewHistory;

  /// Unary deadline for `codex.app.call` / `codex.app.respond` / stream RPCs.
  final Duration callTimeout;
  final Duration transferCallTimeout;

  StreamSubscription<RemoteEvent>? _subscription;
  bool _disposed = false;

  /// Low-level outer RPC with error translation.
  Future<Object?> _rpcCall(
    String method,
    Map<String, Object?> params, {
    Duration? timeout,
  }) async {
    if (_disposed || _rpc.isClosed) {
      throw CodexAppException.transportClosed(method);
    }
    try {
      return await _rpc.call(method, params, timeout: timeout ?? callTimeout);
    } on RemoteRpcException catch (error) {
      throw CodexAppException.fromRpc(error);
    }
  }

  /// Chunked five-step transfer of one `{method, params}` envelope; a verbatim
  /// port of the official `callTransferred` (index.js L65484-65523) including
  /// descriptor validation and best-effort `transfer.close` in `finally`.
  Future<Object?> callTransferred(Uint8List encoded) async {
    if (encoded.isEmpty || encoded.length > maxCodexTransferBytes) {
      throw const CodexAppException(
        'INVALID_MESSAGE',
        'The Codex request exceeds the transfer limit.',
      );
    }
    final transferId = uuidV7();
    final totalChunks = encoded.length ~/ codexTransferChunkBytes +
        (encoded.length % codexTransferChunkBytes == 0 ? 0 : 1);
    var opened = false;
    try {
      await _rpcCall('codex.app.transfer.open', {
        'transferId': transferId,
        'totalBytes': encoded.length,
        'totalChunks': totalChunks,
      }, timeout: transferCallTimeout);
      opened = true;
      for (var index = 0; index < totalChunks; index += 1) {
        final start = index * codexTransferChunkBytes;
        final end = (start + codexTransferChunkBytes) < encoded.length
            ? start + codexTransferChunkBytes
            : encoded.length;
        await _rpcCall('codex.app.transfer.chunk', {
          'transferId': transferId,
          'index': index,
          'data': base64Encode(encoded.sublist(start, end)),
        }, timeout: transferCallTimeout);
      }
      final committed = asMap(await _rpcCall('codex.app.transfer.commit', {
        'transferId': transferId,
      }, timeout: transferCallTimeout));
      if (committed == null) throw const CodexInvalidResponseException('transfer commit');
      final kind = asString(committed['kind']);
      if (kind == 'inline') return committed['response'];
      if (kind != 'chunked') throw const CodexInvalidResponseException('transfer commit');
      final returnedId = asString(committed['transferId']);
      final totalBytes = asInt(committed['totalBytes']);
      final committedChunks = asInt(committed['totalChunks']);
      final expectedChunks = totalBytes == null
          ? null
          : totalBytes ~/ codexTransferChunkBytes +
              (totalBytes % codexTransferChunkBytes == 0 ? 0 : 1);
      if (returnedId != transferId ||
          totalBytes == null ||
          totalBytes <= 0 ||
          totalBytes > maxCodexTransferBytes ||
          committedChunks == null ||
          committedChunks != expectedChunks) {
        throw const CodexInvalidResponseException('transfer descriptor');
      }
      final response = Uint8List(totalBytes);
      var offset = 0;
      for (var index = 0; index < committedChunks; index += 1) {
        final result = asMap(await _rpcCall('codex.app.transfer.read', {
          'transferId': transferId,
          'index': index,
        }, timeout: transferCallTimeout));
        if (result == null ||
            asString(result['transferId']) != transferId ||
            asInt(result['index']) != index) {
          throw const CodexInvalidResponseException('transfer ordering');
        }
        final data = asString(result['data']);
        if (data == null) throw const CodexInvalidResponseException('transfer data');
        final Uint8List chunk;
        try {
          chunk = base64Decode(data);
        } on FormatException {
          throw const CodexInvalidResponseException('transfer data');
        }
        final expected = (offset + codexTransferChunkBytes) < totalBytes
            ? codexTransferChunkBytes
            : totalBytes - offset;
        if (chunk.length != expected) {
          throw const CodexInvalidResponseException('transfer chunk');
        }
        response.setRange(offset, offset + chunk.length, chunk);
        offset += chunk.length;
      }
      try {
        // The reassembled bytes are the serialized call result value (same
        // payload shape as the inline `response` field).
        return jsonDecode(utf8.decode(response));
      } on FormatException {
        throw const CodexInvalidResponseException('transfer response');
      }
    } finally {
      if (opened) {
        // Best-effort cleanup; a failed close never masks the primary error.
        unawaited(_rpc
            .call('codex.app.transfer.close', {'transferId': transferId},
                timeout: const Duration(seconds: 5))
            .catchError((Object _) => null));
      }
    }
  }

  /// Whether any prompt input item is an image (forces transfer, matching the
  /// official client's `hasImageInput`).
  static bool hasImageInput(Map<String, Object?> params) {
    final input = params['input'];
    if (input is! List) return false;
    return input.any((item) => item is Map && item['type'] == 'image');
  }

  /// One Codex App Server call. [transfer] forces the chunked pipeline;
  /// envelopes above [maxDirectCodexCallBytes] transfer automatically.
  Future<Object?> call(
    String method,
    Map<String, Object?> params, {
    bool transfer = false,
  }) async {
    final envelope = <String, Object?>{'method': method, 'params': params};
    if (!transfer) {
      if (utf8.encode(jsonEncode(envelope)).length <= maxDirectCodexCallBytes) {
        return _rpcCall('codex.app.call', envelope);
      }
    }
    return callTransferred(
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))));
  }

  /// Official client's `request`: adds `previewHistory` for session history
  /// and transfers large-history reads and image-bearing inputs.
  Future<Object?> request(String method, Map<String, Object?> params) async {
    if (method == 'dsh/sessionHistory' && previewHistory) {
      try {
        return await _rpcCall('codex.app.call', {
          'method': method,
          'params': params,
          'previewHistory': true,
        });
      } on CodexAppException catch (error) {
        if (error.code != 'INVALID_MESSAGE' && error.code != 'RESPONSE_TOO_LARGE') {
          rethrow;
        }
        if (error.code == 'INVALID_MESSAGE') previewHistory = false;
        // Both fall through to the plain call/transfer path below.
      }
    }
    final largeHistory = method == 'dsh/historyDetail' ||
        method == 'dsh/sessionHistory' ||
        (method == 'thread/read' && params['includeTurns'] == true);
    return call(method, params, transfer: largeHistory || hasImageInput(params));
  }

  // ---------------------------------------------------------------------------
  // Streams (live frames per thread).
  // ---------------------------------------------------------------------------

  /// Opens a live stream for [threadId]. The mux subscription exists from
  /// construction, so frames racing the open response are never lost. The
  /// Host validates the thread via an internal read and may reject with
  /// `CODEX_THREAD_NOT_ALLOWED` / `CODEX_THREAD_BUSY`.
  Future<CodexStreamHandle> subscribe(
    String threadId,
    CodexFrameHandler onFrame, {
    void Function(CodexStreamCloseReason reason)? onClose,
  }) async {
    final streamId = uuidV7();
    final closed = StreamController<CodexStreamCloseReason>.broadcast();
    var settled = false;
    void markClosed(CodexStreamCloseReason reason) {
      if (settled) return;
      settled = true;
      _mux.handlers.remove(streamId);
      _mux.closeHandlers.remove(streamId);
      closed.add(reason);
      unawaited(closed.close());
      onClose?.call(reason);
    }

    _mux.handlers[streamId] = onFrame;
    _mux.closeHandlers[streamId] = markClosed;
    try {
      await _rpcCall('codex.app.stream.open', {
        'streamId': streamId,
        'threadId': threadId,
      }, timeout: callTimeout);
    } on Object {
      _mux.handlers.remove(streamId);
      _mux.closeHandlers.remove(streamId);
      unawaited(closed.close());
      rethrow;
    }
    return CodexStreamHandle._(streamId, this, closed);
  }

  /// Host-initiated close notification path (also used by [CodexStreamHandle.close]).
  Future<void> closeStream(String streamId) async {
    try {
      await _rpcCall('codex.app.stream.close', {'streamId': streamId});
    } on CodexAppException {
      // Best-effort, exactly like the official client's `.catch(() => void 0)`.
    }
  }

  /// Approval decision for a forwarded `item/*/requestApproval` frame.
  /// `requestHandle` comes from the sanitized frame params.
  Future<void> respond(String requestHandle, CodexApprovalDecision decision) {
    return _rpcCall('codex.app.respond', {
      'requestHandle': requestHandle,
      'decision': switch (decision) {
        CodexApprovalDecision.accept => 'accept',
        CodexApprovalDecision.decline => 'decline',
        CodexApprovalDecision.cancel => 'cancel',
      },
    }).then<void>((_) {});
  }

  /// Tears down the event subscription and fails all open streams.
  Future<void> dispose() async {
    _disposed = true;
    await _subscription?.cancel();
    _mux.failAll();
  }
}

// -----------------------------------------------------------------------------
// Typed wrappers around the inner App Server method allowlist
// (codex/method-policy.js). Field names and strictness are wire-exact; the
// zod schemas are `.strict()`, so unknown keys are rejected by the Host.
// -----------------------------------------------------------------------------

extension CodexAppApiMethods on CodexAppApi {
  Future<Object?> accountRead() => call('account/read', const {});

  Future<Object?> modelList({String? cursor, int? limit, bool? includeHidden}) =>
      call('model/list', {
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
        if (includeHidden != null) 'includeHidden': includeHidden,
      });

  Future<Object?> projectList({String? cursor, int? limit}) => call('project/list', {
        if (cursor != null) 'cursor': cursor,
        if (limit != null) 'limit': limit,
      });

  Future<Object?> threadList(Map<String, Object?> params) => call('thread/list', params);

  /// Full-thread read; `includeTurns: true` responses are transferred.
  Future<Object?> threadRead(String threadId, {bool includeTurns = false}) =>
      call('thread/read', {'threadId': threadId, if (includeTurns) 'includeTurns': true},
          transfer: includeTurns);

  /// `dsh/sessionHistory` with preview latch semantics (goes through [request]).
  Future<Object?> sessionHistory(
    String threadId, {
    int? beforeSeq,
    int? throughSeq,
    int? maxMessages,
  }) =>
      request('dsh/sessionHistory', {
        'threadId': threadId,
        if (beforeSeq != null) 'beforeSeq': beforeSeq,
        if (throughSeq != null) 'throughSeq': throughSeq,
        if (maxMessages != null) 'maxMessages': maxMessages,
      });

  /// Large-history detail read (peer-expiring handle; always transferred).
  Future<Object?> historyDetail(String threadId, String detailId) =>
      request('dsh/historyDetail', {'threadId': threadId, 'detailId': detailId});

  /// Attachment bytes for a stubbed-out history item (history preview mode).
  Future<Object?> sessionAttachment(String threadId, String attachmentId) =>
      request('dsh/sessionAttachment', {'threadId': threadId, 'attachmentId': attachmentId});

  Future<Object?> directoryList(String path) => call('dsh/directoryList', {'path': path});

  Future<Object?> threadStart({
    required String cwd,
    String? model,
    String? personality,
    String? permissionPreset,
  }) =>
      call('thread/start', {
        'cwd': cwd,
        if (model != null) 'model': model,
        if (personality != null) 'personality': personality,
        if (permissionPreset != null) 'permissionPreset': permissionPreset,
      });

  Future<Object?> threadResume(
    String threadId, {
    String? model,
    String? permissionPreset,
  }) =>
      call('thread/resume', {
        'threadId': threadId,
        if (model != null) 'model': model,
        if (permissionPreset != null) 'permissionPreset': permissionPreset,
      });

  Future<Object?> threadFork(
    String threadId, {
    String? lastTurnId,
    String? permissionPreset,
  }) =>
      call('thread/fork', {
        'threadId': threadId,
        if (lastTurnId != null) 'lastTurnId': lastTurnId,
        if (permissionPreset != null) 'permissionPreset': permissionPreset,
      });

  Future<Object?> threadNameSet(String threadId, String name) =>
      call('thread/name/set', {'threadId': threadId, 'name': name});

  Future<Object?> threadArchive(String threadId) => call('thread/archive', {'threadId': threadId});

  Future<Object?> threadUnarchive(String threadId) =>
      call('thread/unarchive', {'threadId': threadId});

  Future<Object?> threadUnsubscribe(String threadId) =>
      call('thread/unsubscribe', {'threadId': threadId});

  /// Reasoning effort levels accepted by `turn/start` (`effort` field).
  static const codexEffortLevels = {
    'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra',
  };

  Future<Object?> turnStart(
    String threadId,
    List<Map<String, Object?>> input, {
    String? model,
    String? effort,
    String? summary,
    String? personality,
    String? permissionPreset,
  }) =>
      call('turn/start', {
        'threadId': threadId,
        'input': input,
        if (model != null) 'model': model,
        if (effort != null) 'effort': effort,
        if (summary != null) 'summary': summary,
        if (personality != null) 'personality': personality,
        if (permissionPreset != null) 'permissionPreset': permissionPreset,
      }, transfer: CodexAppApi.hasImageInput({'input': input}));

  Future<Object?> turnSteer(
    String threadId,
    String expectedTurnId,
    List<Map<String, Object?>> input,
  ) =>
      call('turn/steer', {
        'threadId': threadId,
        'expectedTurnId': expectedTurnId,
        'input': input,
      }, transfer: CodexAppApi.hasImageInput({'input': input}));

  Future<Object?> turnInterrupt(String threadId, String turnId) =>
      call('turn/interrupt', {'threadId': threadId, 'turnId': turnId});
}

/// Builders for Codex turn input items (codex/method-policy.js schemas:
/// `textInput` / `imageInput`, 1..16 items).
abstract final class CodexInput {
  /// Text item; 1..256 KiB (Host-side zod `max(256 * 1024)`).
  static Map<String, Object?> text(String text) => {'type': 'text', 'text': text};

  /// Image item built from a data URL. Media types are restricted to
  /// png/jpeg/webp/gif; base64 must be canonical (Host-side refine), so this
  /// builder re-encodes and compares to reject non-canonical input early.
  static Map<String, Object?> imageFromDataUrl(String dataUrl) {
    final match = RegExp(r'^data:(image/(?:png|jpeg|webp|gif));base64,([A-Za-z0-9+/]+={0,2})$')
        .firstMatch(dataUrl);
    if (match == null) {
      throw ArgumentError.value(dataUrl, 'dataUrl', 'Unsupported image data URL');
    }
    final mediaType = match.group(1)!;
    final base64Data = match.group(2)!;
    try {
      final bytes = base64Decode(base64Data);
      if (base64Encode(bytes) != base64Data) {
        throw ArgumentError.value(dataUrl, 'dataUrl', 'Non-canonical base64');
      }
      return {'type': 'image', 'mediaType': mediaType, 'data': base64Data};
    } on FormatException {
      throw ArgumentError.value(dataUrl, 'dataUrl', 'Invalid base64');
    }
  }
}
