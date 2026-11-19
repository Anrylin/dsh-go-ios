// The inert debug-log switch: off by default, remembered when toggled, and
// never wired to a sender.

import 'package:dsh_app/usage/debug_log_settings.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('auto-send debug logs defaults to off', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(debugLogSettingsProvider.notifier).ready();
    expect(container.read(debugLogSettingsProvider).autoSend, isFalse);
  });

  test('the switch persists and reads back', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final notifier = container.read(debugLogSettingsProvider.notifier);

    await notifier.setAutoSend(true);
    expect(container.read(debugLogSettingsProvider).autoSend, isTrue);

    final other = ProviderContainer();
    addTearDown(other.dispose);
    await other.read(debugLogSettingsProvider.notifier).ready();
    expect(other.read(debugLogSettingsProvider).autoSend, isTrue);
  });
}
