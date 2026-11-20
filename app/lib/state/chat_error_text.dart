import 'package:dsh_client/dsh_client.dart';
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
String chatErrorText(Object error, {required String action}) {
  debugPrint('$action: $error');
  final reason = switch (error) {
    // Another device owning this Codex thread is a normal, transient state.
    // Say what is happening instead of reporting the action as a failure.
    _ when codexThreadBusy(error) => appL10n.stateChatCodexThreadBusy,
    DshRemoteException(:final code) => switch (code) {
      'session/agent-busy' => appL10n.stateChatAgentBusy,
      'session/writer-held' => appL10n.stateChatWriterHeld,
      'session/model-unavailable' || 'session/provider-models-unavailable' => appL10n.stateChatModelUnavailable,
      'session/attachment-invalid' || 'attachment-error' => appL10n.stateChatAttachmentInvalid,
      'session/fork-unavailable' => appL10n.stateChatForkUnavailable,
      'FRAME_TOO_LARGE' => appL10n.stateChatImagesTooLarge,
      _ => engineErrorReason(error),
    },
    // Uploads and exports go over HTTP: any other status means no engine.
    DshHttpException() => engineErrorReason(error) ?? appL10n.commonEngineUnreachable,
    _ => engineErrorReason(error),
  };
  return reason == null ? action : appL10n.stateActionReason(action, reason);
}
