// Bounded, structured application events for diagnostics bundles.
//
// Stable API (use this from any app module that needs to leave a trace):
//
// ```dart
// appEventLog.record(
//   topic: 'agent_switch',
//   event: 'connected',
//   fields: {
//     'hostKind': host.kind.name,
//     'hostId': host.id,
//     'agent': agent.code,
//     'sessionId': sessionId,
//     'turnId': turnId,
//     'requestId': requestId,
//     'muxGeneration': generation.number,
//     'followEpoch': epoch.toString(),
//     'clientId': generation.clientId,
//     'toolName': 'shell',
//     'durationMs': elapsed.inMilliseconds,
//     'payload': {'workspace': workspace},
//   },
// );
// ```
//
// From a widget use `ref.read(appEventLogProvider)` instead of the singleton.
// `record` is synchronous, never throws, and never performs IO or provider
// reads; it is safe to call from an error handler or a dispose callback.
//
// Every string is passed through the shared diagnostics redactor. Credentials
// become a boolean marker, ids keep only a prefix/last-four mask, and anything
// named `*token*` becomes the literal `<redacted>`. A full schema and more
// examples live in APP_EVENTS.md next to this file.

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'redact.dart';

/// Default ring capacity (kept inside the requested 500–1000 range).
const defaultAppEventCapacity = 1000;

/// Longest retained ordinary field (after redaction).
const defaultAppEventFieldLength = 1000;

/// Longest retained `payload` string (after redaction).
const defaultAppEventPayloadLength = 4000;

/// What a token value becomes, whatever its original contents were.
const appEventTokenRedacted = '<redacted>';

/// Redaction must not silently cut a payload before its explicit bound is
/// checked; the redactor's default 2000-character line limit is for logs.
const appEventRedactionLineLimit = 1 << 30;

const _idSeparator = '…';
const _truncatedMark = '…<payload truncated>';

final _tokenKey = RegExp(r'token', caseSensitive: false);
final _secretKey = RegExp(
  r'passw(or)?d|passphrase|secret|credential|cookie|authorization|api[_-]?key|apikey|access[_-]?key|private[_-]?key',
  caseSensitive: false,
);

/// Identifiers that are masked to a prefix plus last four characters.
/// Counters such as `muxGeneration`/`followEpoch` stay readable: they identify
/// a reconnect, not a person.
const _idKeys = <String>{'hostId', 'clientId', 'sessionId', 'turnId', 'requestId'};

/// Stable columns of a recorded event. Extra [AppEventRecord.fields] keys are
/// preserved after these, so new instrumentation does not need a schema bump.
const eventFieldKeys = <String>{
  'hostKind',
  'hostId',
  'agent',
  'sessionId',
  'turnId',
  'requestId',
  'muxGeneration',
  'followEpoch',
  'clientId',
  'toolName',
  'errorCode',
  'errorMessage',
  'durationMs',
  'payload',
  'payloadTruncated',
  'source',
  'errorType',
  'fallback',
};

/// One redacted event. `at` and `seq` are assigned by [AppEventLog.record].
@immutable
class AppEventRecord {
  const AppEventRecord({
    required this.at,
    required this.seq,
    required this.topic,
    required this.event,
    required this.fields,
  });

  final DateTime at;
  final int seq;
  final String topic;
  final String event;
  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'seq': seq,
    'topic': topic,
    'event': event,
    for (final key in eventFieldKeys) key: fields[key],
    for (final entry in fields.entries)
      if (!eventFieldKeys.contains(entry.key)) entry.key: entry.value,
  };
}

/// A synchronous in-memory ring. No IO, no connection/provider reads, so it
/// cannot interfere with the failure being recorded.
class AppEventLog {
  AppEventLog({
    DateTime Function()? clock,
    int capacity = defaultAppEventCapacity,
    int fieldLength = defaultAppEventFieldLength,
    int payloadLength = defaultAppEventPayloadLength,
  }) : _clock = clock ?? DateTime.now,
       capacity = _bounded(capacity, 1, 10000),
       fieldLength = _bounded(fieldLength, 64, 100000),
       payloadLength = _bounded(payloadLength, 64, 100000);

  final DateTime Function() _clock;
  final int capacity;
  final int fieldLength;
  final int payloadLength;

  final Queue<AppEventRecord> _records = Queue();
  int _seq = 0;
  int _dropped = 0;
  bool _recording = false;

  /// Events evicted for capacity, payloads that exceeded [payloadLength],
  /// and reentrant or failed records. Never reset by a snapshot; exposed in
  /// the bundle's `summary.json`.
  int get droppedEvents => _dropped;

  int get length => _records.length;

  /// Oldest first, like every other log in a diagnostics bundle.
  List<AppEventRecord> snapshot() => List.unmodifiable(_records);

  @visibleForTesting
  void clear() {
    _records.clear();
    _seq = 0;
    _dropped = 0;
  }

  void record({required String topic, required String event, required Map<String, Object?> fields}) {
    // An arbitrary value's toString can itself fail or record again. Keep a
    // nested report out of the collector while the original handler runs.
    if (_recording) {
      _dropped++;
      return;
    }
    _recording = true;
    try {
      var payloadTruncated = false;
      final normalized = <String, Object?>{};
      for (final entry in fields.entries) {
        if (entry.key == 'payload') {
          final (Object? value, bool truncated) = _payload(entry.value);
          normalized[entry.key] = value;
          payloadTruncated = payloadTruncated || truncated;
        } else {
          normalized[entry.key] = _value(entry.key, entry.value);
        }
      }
      if (payloadTruncated) {
        normalized['payloadTruncated'] = true;
        _dropped++;
      }
      final record = AppEventRecord(
        at: _clock(),
        seq: ++_seq,
        topic: _safeText(topic, fieldLength),
        event: _safeText(event, fieldLength),
        fields: Map.unmodifiable(normalized),
      );
      if (_records.length == capacity) {
        _records.removeFirst();
        _dropped++;
      }
      _records.addLast(record);
    } catch (_) {
      // Diagnostics must not replace the failure being reported.
      _dropped++;
    } finally {
      _recording = false;
    }
  }

  Object? _value(String key, Object? value) {
    if (value == null) return null;
    // Tokens are checked first: an access_token is a token, not a generic key.
    if (_tokenKey.hasMatch(key)) return appEventTokenRedacted;
    if (_secretKey.hasMatch(key)) return value.toString().isNotEmpty;
    if (_isIdKey(key)) return maskDiagnosticsId(value.toString());
    if (value is num || value is bool) return value;
    if (value is Map || value is Iterable) {
      try {
        return _safeText(jsonEncode(_sanitizeStructured(value)), fieldLength);
      } catch (_) {
        return '<unserializable value>';
      }
    }
    return _safeText(value.toString(), fieldLength);
  }

  (Object?, bool) _payload(Object? value) {
    late final String text;
    if (value is String) {
      // Redact without the log-oriented 2000-character line cut, then apply
      // the explicit event bound below exactly once. A JSON-shaped string is
      // sanitized by key as well, so a short `access_token` inside it cannot
      // slip through the key-blind text redactor.
      final trimmed = value.trim();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          text = _redact(jsonEncode(_sanitizeStructured(jsonDecode(trimmed))));
        } catch (_) {
          text = _redact(value);
        }
      } else {
        text = _redact(value);
      }
    } else {
      try {
        text = _redact(jsonEncode(_sanitizeStructured(value)));
      } catch (_) {
        text = '<unserializable payload>';
      }
    }
    if (text.length <= payloadLength) return (text, false);
    final keep = _bounded(payloadLength - _truncatedMark.length, 0, payloadLength);
    return ('${text.substring(0, keep)}$_truncatedMark', true);
  }

  /// Key-aware sanitizer for structured payloads. `redactDiagnostics` alone
  /// is key-blind: a short `access_token` inside a map would survive it.
  Object? _sanitizeStructured(Object? value, {String? key}) {
    if (value == null) return null;
    if (key != null) {
      // Tokens are checked first: an access_token is a token, not a generic key.
      if (_tokenKey.hasMatch(key)) return appEventTokenRedacted;
      if (_secretKey.hasMatch(key)) return value.toString().isNotEmpty;
      if (_isIdKey(key)) return maskDiagnosticsId(value.toString());
    }
    if (value is Map) {
      return {for (final entry in value.entries) '${entry.key}': _sanitizeStructured(entry.value, key: '${entry.key}')};
    }
    if (value is Iterable) return [for (final item in value) _sanitizeStructured(item)];
    if (value is num || value is bool) return value;
    return _safeText(value.toString(), fieldLength);
  }

  String _redact(String text) => redactDiagnostics(text, lineLimit: appEventRedactionLineLimit);

  String _safeText(String text, int limit) {
    final redacted = _redact(text);
    return redacted.length > limit ? '${redacted.substring(0, limit - 1)}…' : redacted;
  }
}

bool _isIdKey(String key) =>
    key == 'id' || _idKeys.contains(key) || key.endsWith('_id') || (key.length > 2 && key.endsWith('Id'));

int _bounded(int value, int min, int max) => value < min ? min : (value > max ? max : value);

/// Keeps at most a four-character prefix plus the last four characters of an
/// identifier. Short identifiers are split in half. Used by both app events
/// and the identity fields in `summary.json`.
String maskDiagnosticsId(String id) {
  if (id.isEmpty) return '';
  if (id.length <= 8) {
    final prefix = id.length ~/ 2;
    return '${id.substring(0, prefix)}$_idSeparator${id.substring(prefix)}';
  }
  return '${id.substring(0, 4)}$_idSeparator${id.substring(id.length - 4)}';
}

/// The process-wide ring other modules write to.
final appEventLog = AppEventLog();

/// Riverpod handle for widgets that prefer `ref.read` over the singleton.
final appEventLogProvider = Provider<AppEventLog>((ref) => appEventLog);
