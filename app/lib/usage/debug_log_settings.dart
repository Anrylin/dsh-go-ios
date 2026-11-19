// 自动发送调试日志: a deliberately inert switch. The person can turn it on,
// and the choice is remembered, but nothing is uploaded yet. The real sender
// (and where it sends) is a later decision — currently only the manual
// 「导出调试日志」 path exists, through the diagnostics bundle.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DebugLogSettingsState {
  const DebugLogSettingsState({this.autoSend = false});

  /// Off unless the person turns it on. No sending is wired up yet.
  final bool autoSend;

  DebugLogSettingsState copyWith({bool? autoSend}) =>
      DebugLogSettingsState(autoSend: autoSend ?? this.autoSend);
}

class DebugLogSettingsController extends Notifier<DebugLogSettingsState> {
  static const autoSendKey = 'debug_log_auto_send_enabled';

  @override
  DebugLogSettingsState build() => const DebugLogSettingsState();

  Future<void> ready() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = state.copyWith(autoSend: prefs.getBool(autoSendKey) ?? false);
    } catch (_) {
      // Keep the default (off) when preferences are unavailable.
    }
  }

  Future<void> setAutoSend(bool enabled) async {
    state = state.copyWith(autoSend: enabled);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(autoSendKey, enabled);
    } catch (_) {
      // The visible switch still follows the tap; persistence is best-effort.
    }
  }
}

final debugLogSettingsProvider =
    NotifierProvider<DebugLogSettingsController, DebugLogSettingsState>(DebugLogSettingsController.new);
