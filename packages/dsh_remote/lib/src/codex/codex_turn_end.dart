/// Turn-end classification and error projection for Codex virtual Sessions,
/// a faithful Dart port of `dist/codex/turn-end-reason.js` (36 lines).
library;

import '../util/bytes.dart';
import 'codex_values.dart';

/// End reason published as the terminal `agent/turn_end` event payload.
/// Exactly one of `{kind: error, error: {...}}`, `{kind: interrupted}` or
/// `{kind: completed}`.
JsonMap codexTurnEndReason(JsonMap turn) {
  if (turn['status'] == 'failed' || turn['error'] != null) {
    return <String, Object?>{
      'kind': 'error',
      'error': codexProjectTurnError(turn['error']),
    };
  }
  if (turn['status'] == 'interrupted' ||
      turn['status'] == 'cancelled' ||
      turn['status'] == 'canceled' ||
      turn['status'] == 'aborted') {
    return const <String, Object?>{'kind': 'interrupted'};
  }
  return const <String, Object?>{'kind': 'completed'};
}

/// Preserves `codex_error_info` verbatim when the Host supplies it, falling
/// back to `code` then to `codex-turn-failed` (official text verbatim).
JsonMap codexProjectTurnError(Object? error) {
  if (error is String) {
    final message = error.trim();
    return <String, Object?>{
      'message': message.isEmpty ? 'CodeX turn failed.' : message,
      'code': 'codex-turn-failed',
    };
  }
  final record = codexRecord(error);
  final message = codexString(record['message'])?.trim();
  final info = codexString(record['codex_error_info'])?.trim();
  final rawCode = codexString(record['code'])?.trim();
  final code = (info != null && info.isNotEmpty ? info : rawCode) ?? 'codex-turn-failed';
  return <String, Object?>{
    'message': message != null && message.isNotEmpty ? message : 'CodeX turn failed.',
    'code': code.isEmpty ? 'codex-turn-failed' : code,
    if (info != null && info.isNotEmpty) 'codex_error_info': info,
  };
}
