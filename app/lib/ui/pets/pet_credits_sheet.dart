// 点宠物时弹的积分卡：合计 + 每个账号一行。数据来自本机配置的 WorkBuddy 面板
// （见 state/credits_state.dart），只读，点「刷新」才重新请求。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/credits_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import '../theme/theme.dart';

Future<void> showCreditsSheet(BuildContext context) => showAppSheet<void>(
  context,
  isScrollControlled: true,
  builder: (sheet) => const _CreditsSheet(),
);

class _CreditsSheet extends ConsumerWidget {
  const _CreditsSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final config = ref.watch(creditsConfigProvider);
    final value = ref.watch(creditsProvider);

    final Widget body;
    if (!config.configured) {
      body = Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Text(l10n.creditsNotSet, style: theme.textTheme.bodyMedium),
      );
    } else {
      body = switch (value) {
        AsyncError(:final error) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          child: Text(
            l10n.creditsFailed('$error'),
            style: theme.textTheme.bodyMedium?.copyWith(color: colors.danger),
          ),
        ),
        AsyncData(:final value) when value != null => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.creditsTotal(value.total),
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${l10n.creditsAccounts(value.knownCount)} · '
                    '${l10n.creditsSnapshotAt(_clock(value.at))}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            for (final row in value.rows)
              ListTile(
                dense: true,
                title: Text('…${row.label}'),
                trailing: Text(
                  '${row.credits}',
                  style: AppType.tabular(theme.textTheme.titleSmall!),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
              child: TextButton.icon(
                onPressed: () => ref.invalidate(creditsProvider),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(l10n.creditsRefresh),
              ),
            ),
          ],
        ),
        _ => const Padding(
          padding: EdgeInsets.fromLTRB(20, 24, 20, 28),
          child: Center(child: CircularProgressIndicator()),
        ),
      };
    }

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(title: l10n.creditsTitle),
          body,
        ],
      ),
    );
  }

  static String _clock(DateTime t) =>
      '${t.month}/${t.day} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}
