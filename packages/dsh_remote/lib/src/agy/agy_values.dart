/// Shared values, bounds and small helpers for the Antigravity ACP virtual
/// Harness.
///
/// Every constant here is copied from the Host plugin (`ds-harness-remote`
/// v0.6.5) or from the existing Remote transport. The virtual Harness speaks
/// `agent.acp.*` to the Host and exposes the ordinary DSH endpoint vocabulary
/// to the native Chat UI.
library;

import 'dart:async';
import 'dart:collection';

import 'package:dsh_client/dsh_client.dart';

import '../channel/rpc_client.dart';
import '../util/bytes.dart';

const String agyBackend = 'antigravity';
const String agySessionPrefix = 'acp:';
const String agyWorkspacePrefix = 'antigravity:cwd:';
const String agyDefaultPermission = 'workspace-write';

// Capability strings (client-capabilities.js / agy-protocol-spec.md §1.1).
const String acpCapability = 'agent.acp.v1';
const String agyCapability = 'agent.acp.antigravity.v1';
const String agyModelsCapability = 'agent.acp.antigravity.models.v1';
const String agyModelLoadCapability = 'agent.acp.antigravity.model-load.v1';
const String agyTransferCapability = 'agent.acp.transfer.v1';
const String agyWorkspaceFilesCapability = 'agent.acp.workspace-files.v1';

// Wire limits (peer-bridge.js / protocol §10).
const int maxSecureMessageBytes = 4 * 1024 * 1024;
const int directRemoteCallBytes = 2 * 1024 * 1024;
const int agyTransferChunkBytes = 512 * 1024;
const int maxAgyTransferBytes = 288 * 1024 * 1024;
const int maxActiveAcpStreams = 16;
const int maxBufferedAcpFrames = 200;
const Duration acpFrameBufferTtl = Duration(minutes: 5);
const int maxTurnCatchUpFrames = 120;
const int maxAcpPromptBytes = 64 * 1024;
const int maxAcpUpdateBytes = 512 * 1024;
const Duration agyPromptTimeout = Duration(minutes: 10);

// Image bounds (acp/image-content.js / protocol §12.5).
const int agyMaxImages = 4;
const int agyMaxImageBytes = 8 * 1024 * 1024;
const int agyMaxPromptImageBytes = 32 * 1024 * 1024;
const Set<String> agyImageMimeTypes = <String>{'image/png', 'image/jpeg', 'image/webp', 'image/gif'};

/// The official Web client's `ClientModeError('FEATURE_NOT_SUPPORTED', ...)`
/// is not part of the Dart client package. We keep the same class name and
/// field values so the exact capability diagnostic survives the port.
class ClientModeError implements Exception {
  const ClientModeError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'ClientModeError($code): $message';
}

/// Local validation/translation failure. [code] is used as the failure code
/// in the `{ok:false}` envelope returned to the native UI.
class AgyFailure implements Exception {
  const AgyFailure(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'AgyFailure($code): $message';
}

RpcResult agyOk(Object? value) => RpcOk(value);

RpcResult agyFail(String code, String message) => RpcError(DshRemoteException(code, message));

String? agyString(Object? value) => value is String ? value : null;

int? agyInt(Object? value) {
  if (value is int) return value;
  if (value is double && value.isFinite && value == value.truncateToDouble()) return value.toInt();
  return null;
}

bool agyBool(Object? value) => value is bool ? value : false;

JsonMap agyMap(Object? value) => asMap(value) ?? const <String, Object?>{};

List<Object?> agyList(Object? value) => value is List<Object?> ? value : const <Object?>[];

List<String> agyStringList(Object? value) =>
    agyList(value).map(agyString).whereType<String>().toList(growable: false);

bool agyIsRecord(Object? value) => value is Map<String, Object?> || value is Map;

int agyNowMs() => DateTime.now().millisecondsSinceEpoch;

String agyUuid() => uuidV7();

/// `acp:<conversation_id>` (virtual) -> bare conversation id (ACP wire).
String agyNativeId(String sessionId) {
  if (sessionId.startsWith(agySessionPrefix)) return sessionId.substring(agySessionPrefix.length);
  return sessionId;
}

/// Bare conversation id (ACP wire) -> `acp:<conversation_id>` (virtual).
String agyVirtualId(String sessionId) =>
    sessionId.startsWith(agySessionPrefix) ? sessionId : '$agySessionPrefix$sessionId';

/// AGY tool-call scope is `acp:<sessionId>`, never `antigravity:<sessionId>`.
String agyToolScope(String sessionId) => agyVirtualId(sessionId);

String agyWorkspaceId(String path) => '$agyWorkspacePrefix${Uri.encodeComponent(path)}';

String agyWorkspacePath(String workspaceId) {
  if (!workspaceId.startsWith(agyWorkspacePrefix)) return '';
  try {
    return Uri.decodeComponent(workspaceId.substring(agyWorkspacePrefix.length));
  } on FormatException {
    return '';
  }
}

String agyTitle(JsonMap session) {
  final title = agyString(session['title'])?.trim();
  if (title != null && title.isNotEmpty && title != 'Untitled Session') return title;
  final first = agyList(session['events']).firstWhere(
        (event) => agyString(agyMap(event)['type']) == 'user/message',
        orElse: () => const <String, Object?>{},
      );
  final text = agyString(agyMap(first)['text'])?.trim();
  if (text != null && text.isNotEmpty) return text.length > 80 ? text.substring(0, 80) : text;
  return 'Untitled Session';
}

JsonMap agyEvent(String type, [JsonMap data = const <String, Object?>{}]) => <String, Object?>{
      'type': type,
      ...data,
    };

String? agyErrorCode(Object? error) {
  if (error is AgyFailure) return error.code;
  if (error is ClientModeError) return error.code;
  if (error is DshRemoteException) return error.code;
  if (error is RpcError) return error.error.code;
  if (error is RemoteRpcException) return error.code;
  if (error is Map<String, Object?>) return agyString(error['code']);
  return null;
}

String agyErrorMessage(Object? error) {
  if (error is AgyFailure || error is ClientModeError || error is DshRemoteException || error is RemoteRpcException) {
    return (error as Exception).toString();
  }
  if (error is RpcError) return error.error.message;
  return error.toString();
}

/// Normalizes a caught error into the `{code, message, phase}` shape carried by
/// the AGY catalog `failures` list. Discovery failures must never be swallowed
/// into an empty catalog: the native model picker shows this entry instead.
JsonMap agyFailureEntry(Object? error, {String? phase}) => <String, Object?>{
      'code': agyErrorCode(error) ?? 'ACP_ERROR',
      'message': agyErrorMessage(error),
      if (phase != null && phase.isNotEmpty) 'phase': phase,
    };

/// Errors worth one short wait + retry. Antigravity processes warm up lazily
/// and a session's trusted cwd is written by `dsh/sessionList`, so the first
/// model or prompt call can legitimately fail before the Host is ready.
const Set<String> agyTransientCodes = <String>{
  'ACP_SESSION_NOT_LOADED',
  'ACP_WORKSPACE_UNAVAILABLE',
  'ACP_STREAM_UNAVAILABLE',
  'ACP_PROCESS_STARTING',
  'SESSION_NOT_ACTIVE',
  'NOT_READY',
  'TIMEOUT',
  'DEADLINE_EXCEEDED',
  'RATE_LIMITED',
  'RETRYABLE',
  'TRANSPORT_CLOSED',
};

bool agyIsTransientError(Object? error) =>
    agyTransientCodes.contains(agyErrorCode(error)?.toUpperCase());

/// Attempts [action] up to [attempts] times with a short linear backoff.
/// Non-transient errors are not retried; the final error is always rethrown so
/// callers can surface it as a catalog failure instead of hiding it.
Future<T> agyShortRetry<T>(
  Future<T> Function() action, {
  int attempts = 3,
  Duration delay = const Duration(milliseconds: 250),
  bool Function(Object error)? retryable,
}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    try {
      return await action();
    } on Object catch (error) {
      final shouldRetry = retryable != null ? retryable(error) : agyIsTransientError(error);
      if (attempt + 1 >= attempts || !shouldRetry) rethrow;
      await Future<void>.delayed(delay * (attempt + 1));
    }
  }
  throw const AgyFailure('ACP_ERROR', 'The AGY short retry loop did not produce a result.');
}

/// Result of one model-discovery attempt. A failure is carried as a value,
/// never silently converted into an empty catalog.
class AgyFetchResult {
  const AgyFetchResult.value(this.raw) : failure = null;
  const AgyFetchResult.failure(this.failure) : raw = null;

  final JsonMap? raw;
  final Object? failure;

  bool get ok => failure == null;
}

/// `dsh/sessionList` is the Host's only trusted way to bind a session id to a
/// working directory; `dsh/selectModel` and `session/prompt` reject `cwd` in
/// their strict schemas. Prebinding therefore uses `path`, never `cwd`.
JsonMap agyPrebindParams(String cwd, {int limit = 100}) => <String, Object?>{
      'path': cwd,
      'backend': agyBackend,
      'limit': limit.clamp(1, 100),
    };

/// Strict `session/prompt` payload. No `cwd` and no extra fields: the trusted
/// directory must be prebound through `dsh/sessionList` first.
JsonMap agyPromptParams(String sessionId, String text, List<JsonMap> images) => <String, Object?>{
      'sessionId': sessionId,
      'backend': agyBackend,
      'prompt': <Object?>[
        if (text.isNotEmpty) <String, Object?>{'type': 'text', 'text': text},
        ...images,
      ],
    };

/// Strict `dsh/selectModel` payload. The Host injects the trusted directory
/// from its own session binding, so no `cwd` is sent on this call either.
JsonMap agySelectModelParams(String sessionId, String model, String? effort) => <String, Object?>{
      'sessionId': sessionId,
      'backend': agyBackend,
      'model': model,
      if (effort != null && effort.isNotEmpty) 'reasoningEffort': effort,
    };

/// Bounded abort-aware queue used by every virtual stream. Dart has no
/// AbortSignal, so the owner closes the queue when cancelled.
class AgyValueQueue<T> {
  final Queue<T> _values = Queue<T>();
  final Queue<Completer<_AgyQueueStep<T>>> _waiters = Queue<Completer<_AgyQueueStep<T>>>();
  bool _closed = false;

  void push(T value) {
    if (_closed) return;
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(_AgyQueueStep<T>(false, value));
      return;
    }
    _values.addLast(value);
  }

  bool get isClosed => _closed;

  void close() {
    if (_closed) return;
    _closed = true;
    final pending = _waiters.toList(growable: false);
    _waiters.clear();
    for (final waiter in pending) {
      waiter.complete(_AgyQueueStep<T>(true, null));
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
        final waiter = Completer<_AgyQueueStep<T>>();
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

class _AgyQueueStep<T> {
  const _AgyQueueStep(this.done, this.value);

  final bool done;
  final Object? value;
}

/// Capability snapshot from `harness.transport.describe`.
class AgyCapabilities {
  AgyCapabilities._({
    required this.hostVersion,
    required this.capabilities,
    required this.workspaceTypes,
    required this.unavailableBackends,
  });

  /// Parses a decoded `harness.transport.describe` envelope. Public so the
  /// iOS compatibility path can be tested without a live RPC.
  factory AgyCapabilities.fromDescription(Object? raw) {
    final described = agyMap(raw);
    final values = described['capabilities'];
    if (values is! List<Object?> ||
        values.isEmpty ||
        values.any((item) => item is! String || item.isEmpty) ||
        values.toSet().length != values.length) {
      throw const ClientModeError('FEATURE_NOT_SUPPORTED', 'The remote Host returned invalid transport capabilities.');
    }
    final capabilities = values.cast<String>();
    if (!capabilities.contains(acpCapability)) {
      throw const ClientModeError(
        'FEATURE_NOT_SUPPORTED',
        'The remote Host exposes no supported Harness transport.',
      );
    }
    return AgyCapabilities._(
      hostVersion: agyString(described['version']) ?? '',
      capabilities: capabilities.toList(growable: false),
      workspaceTypes: described['workspaceTypes'],
      unavailableBackends: _unavailableBackends(described['workspaceTypes']),
    );
  }

  static List<String> _unavailableBackends(Object? workspaceTypes) => agyList(workspaceTypes)
      .map(agyMap)
      .where((item) => agyString(item['id']) != null && item['available'] == false)
      .map((item) => agyString(item['id'])!)
      .toList(growable: false);

  /// Calls `harness.transport.describe` and validates the exact envelope.
  static Future<AgyCapabilities> probe(RemoteRpcClient rpc) async {
    final Object? raw;
    try {
      raw = await rpc.call('harness.transport.describe', const <String, Object?>{});
    } on RemoteRpcException catch (error) {
      if (error.code == 'METHOD_NOT_FOUND') {
        throw const ClientModeError(
          'FEATURE_NOT_SUPPORTED',
          'This Host predates Typert Remote capability discovery. Upgrade the Host.',
        );
      }
      rethrow;
    }
    return AgyCapabilities.fromDescription(raw);
  }

  /// Re-probes after a short pause while the Antigravity workspace entry is
  /// still warming up (`available: false`). The final snapshot is returned
  /// with its diagnostics either way: a backend flag never removes a
  /// capability that the Host explicitly advertised on the wire.
  static Future<AgyCapabilities> probeWithRetry(
    RemoteRpcClient rpc, {
    int attempts = 3,
    Duration delay = const Duration(milliseconds: 250),
  }) async {
    for (var attempt = 0; attempt < attempts; attempt += 1) {
      try {
        final probed = await probe(rpc);
        if (probed.unavailableBackends.isEmpty || attempt + 1 >= attempts) return probed;
      } on Object catch (error) {
        if (error is ClientModeError || attempt + 1 >= attempts || !agyIsTransientError(error)) rethrow;
      }
      await Future<void>.delayed(delay * (attempt + 1));
    }
    throw const ClientModeError('FEATURE_NOT_SUPPORTED', 'The remote Host exposes no supported Harness transport.');
  }

  final String hostVersion;
  final List<String> capabilities;
  final Object? workspaceTypes;

  /// Backend ids whose Host workspace entry reported `available: false`.
  /// Kept as diagnostics, not as a capability gate: on iOS the Antigravity
  /// process can still be warming up when the snapshot is taken.
  final List<String> unavailableBackends;

  /// Normalized capability diagnostics, copied into the AGY catalog `failures`
  /// so the native UI can explain a delayed backend instead of "feature
  /// not supported".
  List<JsonMap> get diagnostics => unavailableBackends
      .map((backend) => <String, Object?>{
            'code': 'WORKSPACE_UNAVAILABLE',
            'backend': backend,
            'message': 'The Host reported $backend as unavailable; the advertised capability is still attempted.',
          })
      .toList(growable: false);

  bool _available(String id, String capability) {
    if (!capabilities.contains(capability)) return false;
    final types = workspaceTypes;
    if (types == null) return true;
    final matches = agyList(types).map(agyMap).where((item) => agyString(item['id']) == id).toList();
    if (matches.isEmpty) return true;
    if (matches.length != 1 || agyString(matches.first['capability']) != capability) return false;
    // `available: false` is a transient warm-up / settings state, not a
    // removal of a capability the Host explicitly advertised. It is surfaced
    // in `diagnostics` instead of becoming FEATURE_NOT_SUPPORTED.
    return true;
  }

  bool get acp => capabilities.contains(acpCapability);
  bool get agy => _available(agyBackend, agyCapability);
  bool get models => capabilities.contains(agyModelsCapability);
  bool get modelLoad => capabilities.contains(agyModelLoadCapability);
  bool get transfer => capabilities.contains(agyTransferCapability);
  bool get workspaceFiles => capabilities.contains(agyWorkspaceFilesCapability);

  /// The exact "conflicting session formats" diagnostic from the Web client.
  AgyCapabilities requireConsistentSessionFormats() {
    if (capabilities.contains('harness.remote.v1') && capabilities.contains('harness.remote.v3')) {
      throw const ClientModeError(
        'FEATURE_NOT_SUPPORTED',
        'The remote Host advertised conflicting Harness Session formats.',
      );
    }
    return this;
  }

  bool get available => acp && agy;
}

