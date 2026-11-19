/// Strict value guards shared by the Codex virtual Harness, a faithful Dart
/// port of the official Web client's `virtual-values.js`
/// (`ds-harness-remote` v0.6.4, `dist/codex/virtual-values.js`).
///
/// The Host validates everything it receives; these guards reproduce the
/// client-side validation and the exact error text so an invalid cursor or a
/// non-Codex session fails identically before any RPC is sent.
library;

import 'dart:math';

import 'package:dsh_client/dsh_client.dart';

import '../util/bytes.dart';
import 'codex_api.dart';

/// Session ids owned by the Codex virtual Harness (`codex:<threadId>`).
const String codexSessionPrefix = 'codex:';

/// The strict Remote history schema accepts at most 200 messages per page.
const int codexHistoryPageMaxMessages = 200;

/// Mirrors a plain `new Error(message)` in the official client; [code] maps to
/// the optional `Error.code` used by `errorCode` / `failFrom`.
class CodexValueError implements Exception {
  const CodexValueError(this.message, [this.code]);

  final String message;
  final String? code;

  @override
  String toString() => 'CodexValueError: $message';
}

/// Strips the virtual prefix, rejecting sessions owned by the native DSH
/// Harness. Verbatim text: `The selected Session does not belong to CodeX.`
String codexNativeThreadId(String sessionId) {
  if (!sessionId.startsWith(codexSessionPrefix) || sessionId.length == codexSessionPrefix.length) {
    throw const CodexValueError('The selected Session does not belong to CodeX.');
  }
  return sessionId.substring(codexSessionPrefix.length);
}

JsonMap codexRecord(Object? value) => asMapOrEmpty(value);

bool codexIsRecord(Object? value) => value is Map && value is! List && value is! Set;

List<Object?> codexArray(Object? value) => value is List<Object?> ? value : (value is List ? value.cast<Object?>() : const []);

String? codexString(Object? value) => value is String ? value : null;

/// `Number.isSafeInteger`, including integral JSON doubles.
int? codexInteger(Object? value) {
  if (value is int) {
    return value >= -9007199254740991 && value <= 9007199254740991 ? value : null;
  }
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    final result = value.toInt();
    return result >= -9007199254740991 && result <= 9007199254740991 ? result : null;
  }
  return null;
}

num? codexFiniteNumber(Object? value) => value is num && value.isFinite ? value : null;

int? codexOptionalInteger(Object? value) {
  if (value == null) return null; // wire `undefined` == Dart `null`
  final parsed = codexInteger(value);
  if (parsed == null) throw const CodexValueError('The CodeX History cursor is invalid.');
  return parsed;
}

int? codexOptionalNonNegativeInteger(Object? value) {
  final parsed = codexOptionalInteger(value);
  if (parsed != null && parsed < 0) throw const CodexValueError('The CodeX History cursor is invalid.');
  return parsed;
}

int? codexOptionalPositiveInteger(Object? value) {
  final parsed = codexOptionalInteger(value);
  if (parsed != null && parsed <= 0) throw const CodexValueError('The CodeX History page size is invalid.');
  return parsed;
}

/// Cap native DSH's larger history window requests at the Remote page limit.
int? codexBoundedHistoryPageSize(int? value) => value == null ? null : min(value, codexHistoryPageMaxMessages);

String codexRequiredString(Object? value, String field) {
  final text = codexString(value);
  if (text == null || text.isEmpty) throw CodexValueError('The CodeX $field is required.');
  return text;
}

/// Seconds below 10^10 are treated as seconds and scaled to milliseconds.
int codexNormalizeTime(Object? value) {
  final number = codexFiniteNumber(value);
  if (number == null || number <= 0) return 0;
  return number < 10000000000 ? (number * 1000).floor() : number.floor();
}

String codexIsoTime(Object? value) {
  final normalized = codexNormalizeTime(value);
  final milliseconds = normalized == 0 ? DateTime.now().millisecondsSinceEpoch : normalized;
  return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true).toIso8601String();
}

String codexBasename(String path) {
  final normalized = path.replaceFirst(RegExp(r'[\\/]+$'), '');
  final parts = normalized.split(RegExp(r'[\\/]'));
  final last = parts.isEmpty ? '' : parts.last;
  return last.isEmpty ? path : last;
}

/// FNV-1a over UTF-16 code units, rendered base36 (verbatim `hashString`).
String codexHashString(String value) {
  int hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash = (hash ^ unit) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(36);
}

/// `'code' in error && typeof error.code === 'string'` in the official client,
/// extended to the typed exceptions used by this port.
String? codexErrorCode(Object? error) {
  if (error is CodexValueError) return error.code;
  if (error is CodexAppException) return error.code;
  if (error is DshRemoteException) return error.code;
  if (error is Map<String, Object?>) return codexString(error['code']);
  return null;
}
