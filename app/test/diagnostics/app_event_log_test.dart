import 'package:dsh_app/diagnostics/app_event_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('records oldest-first with assigned at/seq and a stable schema', () {
    var tick = 0;
    final log = AppEventLog(clock: () => DateTime.utc(2026, 11, 20, 13, 0, tick++));
    for (var i = 0; i < 3; i++) {
      log.record(topic: 'agent_switch', event: 'event_$i', fields: {'agent': 'CodeX'});
    }

    final events = log.snapshot();
    expect(events.map((e) => e.seq), <int>[1, 2, 3]);
    expect(events.map((e) => e.event), <String>['event_0', 'event_1', 'event_2']);
    expect(events.first.at.toIso8601String(), contains('2026-11-20T13:00:00'));
    final json = events.first.toJson();
    expect(json['topic'], 'agent_switch');
    expect(json['hostKind'], isNull);
    expect(json.containsKey('hostKind'), isTrue);
    expect(json.containsKey('connectedAt'), isFalse);
    expect(log.droppedEvents, 0);
  });

  test('caps the ring and counts evictions instead of silently dropping', () {
    final log = AppEventLog(capacity: 3);
    for (var i = 0; i < 5; i++) {
      log.record(topic: 'chat', event: 'event_$i', fields: const {});
    }

    expect(log.length, 3);
    expect(log.snapshot().map((e) => e.event), <String>['event_2', 'event_3', 'event_4']);
    expect(log.snapshot().map((e) => e.seq), <int>[3, 4, 5]);
    expect(log.droppedEvents, 2);
  });

  test('bounds oversized payloads with a visible marker and a counter', () {
    final log = AppEventLog(payloadLength: 120);
    log.record(topic: 'chat', event: 'send', fields: {'payload': 'x' * 500});

    final event = log.snapshot().single;
    final payload = event.fields['payload'] as String;
    expect(payload.length, lessThanOrEqualTo(120));
    expect(payload, endsWith('…<payload truncated>'));
    expect(event.fields['payloadTruncated'], isTrue);
    expect(log.droppedEvents, 1);
  });

  test('redacts secrets, tokens and identifiers before storing', () {
    final log = AppEventLog();
    log.record(
      topic: 'chat',
      event: 'send_failed',
      fields: {
        'sessionId': 'session-abcdefghijklmnop',
        'hostId': 'host-0123456789',
        'apiKey': 'sk-verysecretvalue',
        'token': 'rawtoken123456',
        'access_token': 'anotherRawTokenValue',
        'errorMessage': 'failed password=hunter2 token=abc12345',
        'payload': 'Authorization: Bearer rawtoken123456',
      },
    );

    final fields = log.snapshot().single.fields;
    expect(fields['sessionId'], 'sess…mnop');
    expect(fields['hostId'], 'host…6789');
    expect(fields['apiKey'], isTrue);
    expect(fields['token'], '<redacted>');
    expect(fields['access_token'], '<redacted>');
    expect(fields['errorMessage'], isNot(contains('hunter2')));
    expect(fields['errorMessage'], isNot(contains('abc12345')));
    expect(fields['payload'], isNot(contains('rawtoken123456')));
  });

  test('serializes map payloads with key-aware nested redaction', () {
    final log = AppEventLog();
    log.record(
      topic: 'tools',
      event: 'invoked',
      fields: {
        'payload': {
          'apiKey': 'rawtoken123456',
          'access_token': 'abc',
          'nested': {'password': 'x', 'session_id': 'sess-abcdefghijklmnop'},
          'id': 'exact-abcdefghijklmnop',
          'note': 'plain',
        },
      },
    );

    final fields = log.snapshot().single.fields;
    final payload = fields['payload'] as String;
    expect(payload, contains('plain'));
    expect(payload, contains('"apiKey":true'));
    expect(payload, contains('"access_token":"<redacted>"'));
    expect(payload, contains('"password":true'));
    expect(payload, contains('"session_id":"sess…mnop"'));
    expect(payload, contains('"id":"exac…mnop"'));
    for (final raw in ['rawtoken123456', 'abc', 'sess-abcdefghijklmnop', 'exact-abcdefghijklmnop']) {
      expect(payload, isNot(contains(raw)));
    }
  });

  test('keeps a long single-line payload until the explicit bound', () {
    final log = AppEventLog(payloadLength: 4000);
    final long = 'x' * 2500;
    log.record(topic: 'chat', event: 'send', fields: {'payload': long});

    final event = log.snapshot().single;
    expect(event.fields['payload'], long);
    expect(event.fields.containsKey('payloadTruncated'), isFalse);
    expect(log.droppedEvents, 0);
  });

  test('sanitizes JSON-shaped strings and structured ordinary fields', () {
    final log = AppEventLog();
    log.record(
      topic: 'probe',
      event: 'structured',
      fields: {
        'payload': '{"access_token":"abc","session_id":"sess-abcdefghijklmnop"}',
        'context': {'apiKey': 'rawtoken123456'},
      },
    );

    final fields = log.snapshot().single.fields;
    final payload = fields['payload'] as String;
    expect(payload, contains('"access_token":"<redacted>"'));
    expect(payload, contains('"session_id":"sess…mnop"'));
    expect(payload, isNot(contains('abc')));
    final context = fields['context'] as String;
    expect(context, contains('"apiKey":true'));
    expect(context, isNot(contains('rawtoken123456')));
  });

  test('counts reentrant records instead of recursing', () {
    final log = AppEventLog();
    final object = _Reenter(log);
    log.record(topic: 'chat', event: 'send', fields: {'note': object});

    expect(log.length, 1);
    expect(log.snapshot().single.fields['note'], 'reentered');
    expect(log.droppedEvents, 1);
  });

  test('counts a failed record without throwing', () {
    final log = AppEventLog();
    log.record(topic: 'chat', event: 'send', fields: {'note': const _Throws()});

    expect(log.length, 0);
    expect(log.droppedEvents, 1);
  });
}

class _Reenter {
  const _Reenter(this.log);

  final AppEventLog log;

  @override
  String toString() {
    log.record(topic: 'nested', event: 'ignored', fields: const {});
    return 'reentered';
  }
}

class _Throws {
  const _Throws();

  @override
  String toString() => throw StateError('boom');
}
