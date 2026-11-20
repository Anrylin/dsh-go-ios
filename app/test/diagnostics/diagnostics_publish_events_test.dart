import 'package:dsh_app/diagnostics/app_event_log.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_publish.dart';
import 'package:dsh_app/diagnostics/redact.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

DiagnosticsSnapshot _snapshot() => DiagnosticsSnapshot(
  at: DateTime.utc(2026, 11, 20, 13, 3, 56),
  status: const RuntimeStatus.unknown(),
  settings: const AppSettings(),
  native: const NativeDiagnostics(),
);

void main() {
  testWidgets('collect fallback records source, exception and replaced value', (tester) async {
    final log = AppEventLog();
    final value = await diagnosticsAttempt<String>(
      'bridge.logs',
      'in-memory log',
      () async => throw PlatformException(code: 'denied', message: 'password=hunter2'),
      'fallback',
      log: log,
    );

    expect(value, 'fallback');
    final event = log.snapshot().single;
    expect(event.topic, 'diagnostics_collect');
    expect(event.event, 'source_fallback');
    expect(event.fields['source'], 'bridge.logs');
    expect(event.fields['errorType'], 'PlatformException');
    expect(event.fields['fallback'], 'in-memory log');
    expect(event.fields['errorMessage'], isNot(contains('hunter2')));
  });

  testWidgets('PlatformException from publish becomes an event', (tester) async {
    final log = AppEventLog();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, (call) async {
      expect(call.method, 'publishDiagnostics');
      throw PlatformException(code: 'permission_denied', message: 'token=abcdefghijklmnop');
    });
    final publisher = DiagnosticsPublisher(collect: (_) async => _snapshot(), log: log);

    expect(await publisher.publish(), isNull);
    final event = log.snapshot().single;
    expect(event.topic, 'diagnostics_publish');
    expect(event.event, 'publish_failed');
    expect(event.fields['source'], 'publishDiagnostics');
    expect(event.fields['errorCode'], 'permission_denied');
    expect(event.fields['errorType'], 'PlatformException');
    expect(event.fields['errorMessage'], contains('token=$redactionMark'));
    expect(event.fields['errorMessage'], isNot(contains('abcdefghijklmnop')));
  });

  testWidgets('MissingPluginException from publish becomes an event', (tester) async {
    final log = AppEventLog();
    // A mock handler that throws MissingPluginException replies with no
    // envelope, which is exactly what a missing native plugin looks like to
    // MethodChannel. Clearing the handler instead would fall through to the
    // real messenger and never complete under flutter_tester.
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, (call) async {
      throw MissingPluginException('no publishDiagnostics on dsh/runtime');
    });
    final publisher = DiagnosticsPublisher(collect: (_) async => _snapshot(), log: log);

    expect(await publisher.publish(), isNull);
    final event = log.snapshot().single;
    expect(event.topic, 'diagnostics_publish');
    expect(event.event, 'publish_failed');
    expect(event.fields['errorCode'], 'missing_plugin');
    expect(event.fields['errorType'], 'MissingPluginException');
  });

  testWidgets('a null native reply becomes an event', (tester) async {
    final log = AppEventLog();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(DiagnosticsPublisher.channel, (call) async => null);
    final publisher = DiagnosticsPublisher(collect: (_) async => _snapshot(), log: log);

    expect(await publisher.publish(), isNull);
    final event = log.snapshot().single;
    expect(event.topic, 'diagnostics_publish');
    expect(event.event, 'publish_failed');
    expect(event.fields['source'], 'publishDiagnostics');
    expect(event.fields['errorCode'], 'null_reply');
    expect(event.fields['errorType'], 'StateError');
  });
}
