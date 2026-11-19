/// Contract helpers for the Codex virtual Harness, a faithful Dart port of
/// the official Web client's `dist/codex/virtual-contract.js` (187 lines).
///
/// Two layers matter here: [codexBusiness] / [codexFailFrom] translate an
/// App-Server `{ok, value, error}` envelope into the [RpcResult] the
/// `DshCarrier` contract expects, and [CodexValueQueue] is the abort-aware
/// queue used by every virtual stream (Dart has no AbortSignal, so callers
/// pass a [Future] that completes on cancellation).
library;

import 'dart:async';
import 'dart:collection';

import 'package:dsh_client/dsh_client.dart';

import '../util/bytes.dart';
import 'codex_api.dart';
import 'codex_image_codec.dart';
import 'codex_values.dart';

const int codexSessionSearchResultLimit = 20;
const int codexSessionSearchSnippetCodePoints = 240;
const String codexDefaultPermission = 'workspace-write';

const int _maxCodexPromptParts = 16;
const int _maxCodexPromptText = 256 * 1024;

const Set<String> _hostWorkspaceEndpoints = <String>{
  'workspaceFiles/list',
  'workspaceFiles/stat',
  'workspaceFiles/read',
  'workspaceFiles/readBytes',
  'workspaceFiles/readAll',
  'workspaceFiles/readRelated',
  'terminal/environment',
  'terminal/shells',
  'terminal/list',
  'terminal/create',
  'terminal/write',
  'terminal/resize',
  'terminal/rename',
  'terminal/close',
};

const Set<String> _hostWorkspaceStreamEndpoints = <String>{
  'workspaceFiles/changes',
  'terminal/follow',
  'terminal/retain',
};

bool codexIsHostWorkspaceEndpoint(String endpoint) => _hostWorkspaceEndpoints.contains(endpoint);

bool codexIsHostWorkspaceStreamEndpoint(String endpoint) => _hostWorkspaceStreamEndpoints.contains(endpoint);

/// Validates at most 16 text/image parts; returns `null` for any violation so
/// the caller can answer `gateway/bad-request` verbatim.
List<JsonMap>? codexPromptInput(Object? content) {
  final parts = codexArray(content);
  if (parts.isEmpty || parts.length > _maxCodexPromptParts) return null;
  final input = <JsonMap>[];
  for (final value in parts) {
    if (!codexIsRecord(value)) return null;
    final part = codexRecord(value);
    if (part['type'] == 'text') {
      final text = codexString(part['text']);
      if (text == null || text.isEmpty || text.length > _maxCodexPromptText) return null;
      input.add(<String, Object?>{'type': 'text', 'text': text});
      continue;
    }
    if (part['type'] == 'image') {
      final mediaType = codexString(part['mediaType']);
      final data = codexString(part['data']);
      if (mediaType == null ||
          !codexImageMediaTypes.contains(mediaType) ||
          data == null ||
          data.length > maxCodexImageBase64 ||
          !codexIsCanonicalBase64(data)) {
        return null;
      }
      input.add(<String, Object?>{'type': 'image', 'mediaType': mediaType, 'data': data});
      continue;
    }
    return null;
  }
  return input;
}

JsonMap codexPermissionsProjection(String? preset) => <String, Object?>{
      'options': <JsonMap>[
        <String, Object?>{
          'value': 'workspace-write',
          'name': 'workspace-write',
          'description': 'Write inside the workspace; wider command and file access requires one-time approval.',
        },
        <String, Object?>{
          'value': 'danger-full-access',
          'name': 'danger-full-access',
          'description': 'Full Host file access without approval prompts for subsequent turns in this virtual Session.',
        },
      ],
      'currentValue': preset ?? 'Host settings (not reported)',
    };

JsonMap codexImageLimitsProjection() => <String, Object?>{
      'maxImageBytes': 20 * 1024 * 1024,
      'maxImagesPerMessage': _maxCodexPromptParts,
      'maxMessageImageBytes': 100 * 1024 * 1024,
      'maxImagePixels': 40000000,
      'maxImageDimension': 8192,
      'mediaTypes': codexImageMediaTypes.toList(),
    };

bool codexIsPermissionPreset(Object? value) =>
    value == 'workspace-write' || value == 'danger-full-access';

String codexSessionIdFromAddress(JsonMap address) => address['kind'] == 'session'
    ? codexRequiredString(address['sessionId'], 'sessionId')
    : codexRequiredString(address['childSessionId'], 'childSessionId');

/// The Host carrier wraps every virtual endpoint's payload in `{"args":…}`.
JsonMap codexCarrierArgs(Object? payload) => codexRecord(codexRecord(payload)['args']);

JsonMap codexRequestArg(JsonMap args) =>
    codexRecord(args['request'] ?? args['_request'] ?? args);

RpcResult codexSuccess(Object? value) => RpcOk(value);

RpcResult codexFailure(String code, String message, [JsonMap details = const <String, Object?>{}]) =>
    RpcError(DshRemoteException(code, message, details));

/// `ok(value)` omits `value` when it is `undefined`; [RpcOk] with a null value
/// is the equivalent on this wire.
RpcResult codexOk([Object? value]) => RpcOk(value);

RpcResult codexFail(String code, String message, [JsonMap details = const <String, Object?>{}]) =>
    codexFailure(code, message, details);

/// Unwraps an App-Server envelope: `{ok:true,value}` / `{ok:false,error}`.
RpcResult codexBusiness(Object? value) {
  final result = codexRecord(value);
  if (result['ok'] == true) return RpcOk(result['value']);
  if (result['ok'] == false) {
    final error = codexRecord(result['error']);
    return codexFail(
      codexString(error['code']) ?? 'internal',
      codexString(error['message']) ?? 'CodeX virtual Harness rejected the request.',
      codexRecord(error['details']),
    );
  }
  return RpcOk(value);
}

RpcResult codexFailFrom(Object? error) {
  final String code;
  final String message;
  JsonMap details = const <String, Object?>{};
  if (error is CodexValueError) {
    code = error.code ?? 'internal';
    message = error.message;
  } else if (error is CodexAppException) {
    code = error.code;
    message = error.message;
    details = error.details;
  } else if (error is DshRemoteException) {
    code = error.code;
    message = error.message;
    details = error.details;
  } else {
    code = codexErrorCode(error) ?? 'internal';
    message = error?.toString() ?? 'Error';
  }
  return codexFail(code, message, details);
}

bool codexIsLegacySessionHistoryUnsupported(Object? error) {
  final code = codexErrorCode(error);
  return code == 'METHOD_NOT_ALLOWED' ||
      code == 'METHOD_NOT_FOUND' ||
      error is CodexValueError && error.message.contains('The requested Codex method is not available over Remote.');
}

String codexTruncateCodePoints(String value, int maximum) =>
    String.fromCharCodes(value.runes.take(maximum));

class _CodexQueueStep<T> {
  const _CodexQueueStep(this.done, this.value);

  final bool done;
  final Object? value;
}

/// Abort-aware value queue (official `AsyncValueQueue`). [dispose] is invoked
/// exactly once when iteration ends, then the queue is closed so no waiter
/// survives its stream.
class CodexValueQueue<T extends Object?> {
  CodexValueQueue({Future<void>? abort}) {
    if (abort != null) {
      unawaited(abort.then((_) => close(), onError: (Object _) => close()));
    }
  }

  final Queue<T> _values = Queue<T>();
  final Queue<Completer<_CodexQueueStep<T>>> _waiters = Queue<Completer<_CodexQueueStep<T>>>();
  bool _closed = false;

  bool get isClosed => _closed;

  void push(T value) {
    if (_closed) return;
    if (_waiters.isEmpty) {
      _values.addLast(value);
      return;
    }
    _waiters.removeFirst().complete(_CodexQueueStep<T>(false, value));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final pending = _waiters.toList(growable: false);
    _waiters.clear();
    for (final waiter in pending) {
      waiter.complete(_CodexQueueStep<T>(true, null));
    }
  }

  Stream<T> iterate(void Function() dispose) async* {
    try {
      while (true) {
        if (_values.isNotEmpty) {
          yield _values.removeFirst();
          continue;
        }
        if (_closed) return;
        final waiter = Completer<_CodexQueueStep<T>>();
        _waiters.addLast(waiter);
        final step = await waiter.future;
        if (step.done) return;
        yield step.value as T;
      }
    } finally {
      dispose();
      close();
    }
  }
}
