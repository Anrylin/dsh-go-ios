// 设置 › 隐私与分享 › 改进 DSH Go: the switch for anonymous usage statistics
// (lib/usage/usage_stats.dart) and, under it, what goes out.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../usage/debug_log_settings.dart';
import '../../usage/usage_stats.dart';
import '../engine/diagnostics_export_card.dart' show showDiagnosticsExportSheet;
import 'settings_widgets.dart';

class UsageStatsSection extends ConsumerStatefulWidget {
  const UsageStatsSection({super.key});

  @override
  ConsumerState<UsageStatsSection> createState() => _UsageStatsSectionState();
}

class _UsageStatsSectionState extends ConsumerState<UsageStatsSection> {
  @override
  void initState() {
    super.initState();
    // The switch and its sentence on screen count as being told.
    unawaited(ref.read(usageStatsProvider.notifier).markNoticed());
    unawaited(ref.read(debugLogSettingsProvider.notifier).ready());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final enabled = ref.watch(usageStatsProvider.select((s) => s.enabled));
    final autoSend = ref.watch(debugLogSettingsProvider.select((s) => s.autoSend));
    return SettingsSection(
      title: l10n.usageStatsSection,
      footer: Text(l10n.usageStatsFooter),
      children: [
        SettingsSwitchTile(
          spot: Spots.usageStats,
          value: enabled,
          onChanged: (on) => unawaited(ref.read(usageStatsProvider.notifier).setEnabled(on)),
        ),
        SettingsSwitchTile(
          spot: Spots.debugLogAutoSend,
          value: autoSend,
          subtitle: l10n.debugLogAutoSendHint,
          onChanged: (on) => unawaited(ref.read(debugLogSettingsProvider.notifier).setAutoSend(on)),
        ),
        SettingsTile(
          spot: Spots.debugLogExport,
          subtitle: l10n.debugLogExportHint,
          onTap: () => unawaited(showDiagnosticsExportSheet(context)),
        ),
      ],
    );
  }
}
