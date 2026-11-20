import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/diagnostics/app_event_log.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/redact.dart';
import 'package:dsh_app/diagnostics/zip_writer.dart';
import 'package:dsh_app/performance/performance_state.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/voice_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

final _collectProbe = FutureProvider<DiagnosticsSnapshot>(
  (ref) => collectDiagnostics(ref, DateTime.utc(2026, 11, 20, 13, 3, 56)),
);

DiagnosticsSnapshot _snapshot({
  Map<String, Object?> connection = const {},
  List<AppEventRecord> events = const [],
  int dropped = 0,
}) => DiagnosticsSnapshot(
  at: DateTime.utc(2026, 11, 20, 13, 3, 56),
  status: const RuntimeStatus.unknown(),
  settings: const AppSettings(),
  native: const NativeDiagnostics(),
  connection: connection,
  appEvents: events,
  droppedEvents: dropped,
);

Map<String, Object?> _entry(List<ZipEntry> entries, String name) {
  final entry = entries.singleWhere((e) => e.name == name);
  return jsonDecode(utf8.decode(entry.bytes)) as Map<String, Object?>;
}

List<Object?> _events(List<ZipEntry> entries) {
  final entry = entries.singleWhere((e) => e.name == 'app-events.json');
  return jsonDecode(utf8.decode(entry.bytes)) as List<Object?>;
}

void main() {
  test('app-events.json is always present and an empty ring writes []', () {
    final entries = DiagnosticsBundle.entries(_snapshot());

    final entry = entries.singleWhere((e) => e.name == 'app-events.json');
    expect(utf8.decode(entry.bytes).trim(), '[]');
  });

  test('app-events.json contains redacted events in order', () {
    final log = AppEventLog();
    log.record(
      topic: 'diagnostics_collect',
      event: 'source_fallback',
      fields: {'source': 'bridge.logs', 'errorMessage': 'token=abcdefghijklmnop'},
    );
    final snapshot = _snapshot(events: log.snapshot(), dropped: 3);
    final entries = DiagnosticsBundle.entries(snapshot);

    final decoded = _events(entries);
    expect(decoded, hasLength(1));
    final event = decoded.single as Map<String, Object?>;
    expect(event['topic'], 'diagnostics_collect');
    expect(event['seq'], 1);
    expect(event['source'], 'bridge.logs');
    expect(event['errorMessage'], 'token=$redactionMark');
    expect(jsonEncode(event), isNot(contains('abcdefghijklmnop')));

    final summary = _entry(entries, 'summary.json');
    final appEvents = summary['appEvents'] as Map<String, Object?>;
    expect(appEvents['count'], 1);
    expect(appEvents['droppedEvents'], 3);
  });

  test('a long single line survives the bundle without implicit truncation', () {
    final log = AppEventLog();
    log.record(topic: 'probe', event: 'long_line', fields: {'payload': 'x' * 2500});
    final entries = DiagnosticsBundle.entries(_snapshot(events: log.snapshot()));

    final event = _events(entries).single as Map<String, Object?>;
    expect(event['payload'], 'x' * 2500);
    expect(event['payloadTruncated'], isNull);
    expect(event['payload'], isNot(contains('payload truncated')));
  });

  test('summary.connection always carries the full identity schema', () {
    final summary = DiagnosticsBundle.summary(
      _snapshot(
        connection: {
          'host': 'remote',
          'state': 'connected',
          'observedAtEpochMs': 1763660636000,
          'hostId': 'host-0123456789',
          'agent': 'CodeX',
        },
      ),
    );
    final connection = summary['connection'] as Map<String, Object?>;

    expect(connection['host'], 'remote');
    expect(connection['hostId'], 'host-0123456789');
    expect(connection['agent'], 'CodeX');
    expect(DiagnosticsBundle.connectionIdentityKeys, contains('hostKind'));
    for (final key in DiagnosticsBundle.connectionIdentityKeys) {
      expect(connection.containsKey(key), isTrue, reason: 'missing $key');
    }
    // Unknown observations stay null instead of being invented.
    expect(connection['hostKind'], isNull);
    expect(connection['clientId'], isNull);
    expect(connection['sessionId'], isNull);
    expect(connection['turnId'], isNull);
    expect(connection['requestId'], isNull);
    expect(connection['muxGeneration'], isNull);
    expect(connection['followEpoch'], isNull);
    expect(connection['connectedAt'], isNull);
  });

  test('summary exposes event counts without changing engine observations', () {
    final summary = DiagnosticsBundle.summary(_snapshot(connection: {'host': 'local', 'state': 'idle'}, dropped: 7));
    final appEvents = summary['appEvents'] as Map<String, Object?>;
    expect(appEvents['count'], 0);
    expect(appEvents['droppedEvents'], 7);
    expect(appEvents['capacity'], defaultAppEventCapacity);
    expect((summary['connection'] as Map<String, Object?>)['host'], 'local');
  });

  test('a recorded event survives collectDiagnostics and the ZIP', () async {
    appEventLog.clear();
    addTearDown(appEventLog.clear);
    appEventLog.record(
      topic: 'probe',
      event: 'roundtrip',
      fields: {
        'hostId': 'host-0123456789',
        'payload': {'access_token': 'short'},
      },
    );

    final container = ProviderContainer(
      overrides: [
        localRuntimeProvider.overrideWith(_FakeRuntime.new),
        localRuntimeLogsProvider.overrideWith(_FakeRuntimeLogs.new),
        settingsProvider.overrideWith(_FakeSettings.new),
        runtimeBridgeProvider.overrideWithValue(_FakeRuntimeBridge()),
        diagnosticsChannelProvider.overrideWithValue(const _FakeDiagnosticsChannel()),
        connectionDiagnosticsProvider.overrideWithValue(_FakeConnectionDiagnostics()),
        performancePrefsProvider.overrideWith(_FakePerformancePrefs.new),
        performanceProvider.overrideWith(_FakePerformance.new),
        voiceSettingsProvider.overrideWith(_FakeVoice.new),
      ],
    );
    addTearDown(container.dispose);
    final snapshot = await container.read(_collectProbe.future);

    // Diagnostics must not build a connection just to fill identity columns.
    expect(container.exists(activeConnectionProvider), isFalse);
    final summary = DiagnosticsBundle.summary(snapshot);
    final connection = summary['connection'] as Map<String, Object?>;
    expect(connection['hostId'], isNull);
    expect(connection['clientId'], isNull);

    final events = _events(DiagnosticsBundle.entries(snapshot));
    final event = events.whereType<Map<String, Object?>>().singleWhere((e) => e['topic'] == 'probe');
    expect(event['event'], 'roundtrip');
    expect(event['hostId'], maskDiagnosticsId('host-0123456789'));
    expect(event['payload'], contains('"access_token":"$appEventTokenRedacted"'));
    expect(jsonEncode(event), isNot(contains('abcdefghijklmnop')));
  });
}

class _FakeRuntime extends LocalRuntimeController {
  @override
  LocalRuntimeState build() => const LocalRuntimeState();
}

class _FakeRuntimeLogs extends LocalRuntimeLogsController {
  @override
  List<String> build() => const [];
}

class _FakeSettings extends SettingsController {
  @override
  AppSettings build() => const AppSettings();
}

class _FakePerformance extends PerformanceController {
  @override
  PerformanceSnapshot build() => const PerformanceSnapshot();
}

class _FakePerformancePrefs extends PerformancePrefsController {
  @override
  PerformancePrefs build() => const PerformancePrefs();
}

class _FakeVoice extends VoiceSettingsController {
  @override
  VoiceMode build() => VoiceMode.auto;

  @override
  Future<VoiceMode> ready() async => state;
}

class _FakeConnectionDiagnostics extends ConnectionDiagnostics {
  @override
  Map<String, Object?> get snapshot => const {'host': 'remote', 'state': 'connected'};
}

class _FakeRuntimeBridge extends RuntimeBridge {
  @override
  Stream<RuntimeEvent> get events => Stream<RuntimeEvent>.empty();

  @override
  Future<List<String>> logs({int lines = 500}) async => const [];

  @override
  Future<List<String>> failureLog() async => const [];
}

class _FakeDiagnosticsChannel extends DiagnosticsChannel {
  const _FakeDiagnosticsChannel();

  @override
  Future<NativeDiagnostics> info() async => const NativeDiagnostics();

  @override
  Future<List<String>> engineLog({int maxBytes = 512 * 1024}) async => const [];
}
