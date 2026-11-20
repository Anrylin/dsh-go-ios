import 'package:dsh_client/dsh_client.dart';
import 'package:dsh_remote/dsh_remote.dart' show CodexAppException;
import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import 'engine_error_text.dart';

const _codexBusyCodes = {'CODEX_THREAD_BUSY', 'CODEX_TURN_OWNED'};

/// Whether the Host refused because another Codex client holds this thread's
/// turn writer. The refusal is made before the turn reaches upstream, so the
/// very same request can be offered again once that turn is over.
///
/// A carrier/transport loss, a `CODEX_REQUEST_TIMEOUT` or any ordinary upstream
/// error is deliberately *not* busy: its outcome is unknown and it must never
/// be auto-replayed.
bool codexThreadBusy(Object error) {
  if (error is! DshRemoteException) return false;
  if (_codexBusyCodes.contains(error.code)) return true;
  return error.code == 'CODEX_UPSTREAM_ERROR' && error.message.toLowerCase().contains('active writer');
}

/// 「[action]：原因」, or just [action] when the reason means nothing to a
/// person. The raw error only goes to the log.
///
/// The rule for the fallback is deliberate: a code we do not recognise must
/// degrade to the bare action label, never to the Host's own English text.
/// "The CodeX command image list is required." on a Chinese screen tells the
/// user nothing and looks like a bug in our own app.
String chatErrorText(Object error, {required String action}) {
  debugPrint('$action: $error');
  final reason = switch (error) {
    // Another device owning this Codex thread is a normal, transient state.
    // Say what is happening instead of reporting the action as a failure.
    _ when codexThreadBusy(error) => appL10n.stateChatCodexThreadBusy,
    DshRemoteException(:final code) => _remoteCodeReason(code) ?? engineErrorReason(error),
    // The CodeX/AGY clients raise their own exception before the RPC layer ever
    // sees the failure, so the same codes arrive here by a second route.
    CodexAppException(:final code) => _remoteCodeReason(code),
    DshHttpException(:final statusCode) => engineErrorReason(error) ?? _httpReason(statusCode),
    _ => engineErrorReason(error),
  };
  return reason == null ? action : appL10n.stateActionReason(action, reason);
}

/// The reasons worth naming per Host/agent error code.
///
/// Covers the DSH codes and the CodeX/AGY virtual-harness codes that reach the
/// app as [DshRemoteException]s (`codexFailFrom` lifts a `CodexValueError`'s
/// code straight onto the RPC failure). Codes stay grouped by what the user can
/// do about them: wait, fix the input, or nothing at all.
String? _remoteCodeReason(String code) => switch (code) {
  // Someone else is using the conversation; retrying is the whole fix.
  'session/agent-busy' => appL10n.stateChatAgentBusy,
  'session/writer-held' => appL10n.stateChatWriterHeld,
  // Wait a moment.
  'RATE_LIMITED' || 'rate-limited' || 'RATE_LIMIT' => appL10n.stateProviderRateLimited,
  'CODEX_UNAVAILABLE' => appL10n.stateChatCodexUnavailable,
  // The engine or agent cannot do this at all.
  'FEATURE_NOT_SUPPORTED' || 'method-not-found' => appL10n.stateProviderUnsupported,
  'INVALID_MESSAGE' => appL10n.stateChatInvalidRequest,
  // The conversation itself moved on.
  'session/steer-unavailable' || 'steer-unavailable' => appL10n.stateChatTurnEnded,
  'workspace-not-found' => appL10n.stateChatWorkspaceMissing,
  'session/model-unavailable' || 'session/provider-models-unavailable' => appL10n.stateChatModelUnavailable,
  // The attachment was refused: too big, wrong type, unreadable.
  'session/attachment-invalid' || 'attachment-error' => appL10n.stateChatAttachmentInvalid,
  'session/fork-unavailable' => appL10n.stateChatForkUnavailable,
  'FRAME_TOO_LARGE' => appL10n.stateChatImagesTooLarge,
  _ => null,
};

/// A controlled label for an HTTP status: never the response body. The body is
/// Host-authored free text (an HTML error page, a stack trace, a proxy banner)
/// and must stay in the log, out of anything the user can expand.
String? _httpReason(int statusCode) {
  if (statusCode == 429) return appL10n.stateProviderRateLimited;
  if (statusCode >= 500) return appL10n.commonEngineUnreachable;
  if (statusCode >= 400) return appL10n.stateChatInvalidRequest;
  return null;
}

Map<String, Object?> _httpDetails(int statusCode) {
  final reason = _httpReason(statusCode);
  return <String, Object?>{'statusCode': statusCode, 'reason': ?reason};
}

/// The expandable 「详情」 line for an error banner: whitelisted keys, values
/// redacted and capped, `''` when there is nothing safe to show.
///
/// Kept separate from [chatErrorText] on purpose. The banner headline is read
/// by everyone; this line is read by whoever is filing a bug report, so it can
/// name a field or a status code without leaking a path or a token.
String chatErrorDetails(Object? error) => switch (error) {
  DshRemoteException(:final details) => errorDigest(details),
  CodexAppException(:final details) => errorDigest(details),
  DshHttpException(:final statusCode) => errorDigest(_httpDetails(statusCode)),
  DshCarrierRefusedException(:final code) => errorDigest({'code': code}),
  _ => '',
};
