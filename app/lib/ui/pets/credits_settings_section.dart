// 宠物设置 › 余额 / 积分：把面板地址和只读令牌填进来，点宠物才显示积分卡。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/credits_state.dart';
import '../settings/settings_widgets.dart';
import 'pet_credits_sheet.dart';

class CreditsSettingsSection extends ConsumerWidget {
  const CreditsSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final config = ref.watch(creditsConfigProvider);
    final notifier = ref.read(creditsConfigProvider.notifier);
    return SettingsSection(
      footer: Text(l10n.creditsFooter),
      children: [
        SettingsSwitchTile(
          icon: Icons.savings_outlined,
          title: l10n.creditsEnable,
          subtitle: l10n.creditsEnableSubtitle,
          value: config.enabled,
          onChanged: (v) => unawaited(notifier.setEnabled(v)),
        ),
        SettingsTile(
          icon: Icons.link,
          title: l10n.creditsBase,
          value: Text(
            config.baseUrl.isEmpty ? l10n.creditsNotSetShort : config.baseUrl,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _edit(
            context,
            title: l10n.creditsBase,
            hint: 'http://192.0.2.10:7864',
            initial: config.baseUrl,
            onDone: (v) => notifier.setSource(baseUrl: v),
          ),
        ),
        SettingsTile(
          icon: Icons.key,
          title: l10n.creditsToken,
          value: Text(
            config.token.isEmpty
                ? l10n.creditsNotSetShort
                : _mask(config.token),
          ),
          onTap: () => _edit(
            context,
            title: l10n.creditsToken,
            hint: 'wbt_...',
            initial: config.token,
            onDone: (v) => notifier.setSource(token: v),
          ),
        ),
        SettingsTile(
          icon: Icons.admin_panel_settings,
          title: l10n.creditsAdminToken,
          subtitle: l10n.creditsAdminTokenHint,
          value: Text(
            config.adminToken.isEmpty ? l10n.creditsNotSetShort : _mask(config.adminToken),
          ),
          onTap: () => _edit(
            context,
            title: l10n.creditsAdminToken,
            hint: 'wbt_...（admin）',
            initial: config.adminToken,
            onDone: (v) => notifier.setSource(adminToken: v),
          ),
        ),
        if (config.configured) ...[
          SettingsTile(
            icon: Icons.insights,
            title: l10n.creditsPreview,
            chevron: true,
            onTap: () => unawaited(showCreditsSheet(context)),
          ),
          SettingsTile(
            icon: Icons.wifi_tethering,
            title: l10n.creditsTest,
            chevron: true,
            onTap: () => unawaited(_test(context, config)),
          ),
        ],
      ],
    );
  }

  /// 点一下就知道卡在哪:地址、HTTP 码、错误原文、合计。
  Future<void> _test(BuildContext context, CreditsConfig config) async {
    final url = endpointFor(config.baseUrl);
    String body;
    try {
      final snapshot = await fetchCredits(config);
      body = '${config.baseUrl}\n→ $url\n\nOK · 合计 ${snapshot.total}'
          ' · ${snapshot.knownCount} 个账号';
    } on Object catch (error) {
      body = '${config.baseUrl}\n→ $url\n\n失败：$error';
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(context.l10n.creditsTest),
        content: SelectableText(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(context.l10n.commonClose),
          ),
        ],
      ),
    );
  }

  static String _mask(String token) => token.length <= 8
      ? '••••'
      : '${token.substring(0, 4)}…${token.substring(token.length - 4)}';

  Future<void> _edit(
    BuildContext context, {
    required String title,
    required String hint,
    required String initial,
    required Future<void> Function(String) onDone,
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(dialog, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: Text(context.l10n.commonSave),
          ),
        ],
      ),
    );
    if (value != null) unawaited(onDone(value));
  }
}
