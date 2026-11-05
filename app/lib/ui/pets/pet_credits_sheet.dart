// 点宠物时弹的积分卡：合计 + 每个账号一行。数据来自本机配置的 WorkBuddy 面板
// （见 state/credits_state.dart），只读。
//
// 卡片自己发请求，不走 provider：这样刷新失败时还能把上一次的数字留在屏幕上，
// 而不是整张卡变成错误页；刷新中显示转圈并禁用按钮，不会出现「点了没反应」。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/credits_state.dart';
import '../common/app_sheet.dart';
import '../common/sheet_title_bar.dart';
import 'pet_settings_page.dart';
import '../theme/theme.dart';

Future<void> showCreditsSheet(BuildContext context) =>
    showAppSheet<void>(context, isScrollControlled: true, builder: (sheet) => const _CreditsSheet());

class _CreditsSheet extends ConsumerStatefulWidget {
  const _CreditsSheet();

  @override
  ConsumerState<_CreditsSheet> createState() => _CreditsSheetState();
}

class _CreditsSheetState extends ConsumerState<_CreditsSheet> {
  CreditsSnapshot? _last;
  String? _error;
  bool _loading = false;
  int? _tookMs;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final config = ref.read(creditsConfigProvider);
    if (!config.configured || _loading) return;
    final started = DateTime.now();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 有管理员令牌就顺手让面板去问上游,否则只能读它登记过的数字。
      final snapshot = await fetchCredits(
        config,
        force: config.adminToken.isNotEmpty,
      );
      if (!mounted) return;
      setState(() {
        _last = snapshot;
        _tookMs = DateTime.now().difference(started).inMilliseconds;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _tookMs = DateTime.now().difference(started).inMilliseconds;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final config = ref.watch(creditsConfigProvider);

    final rows = _last?.rows ?? const <CreditsRow>[];
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(l10n.creditsTitle),
          if (!config.configured)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.creditsNotSet, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 12),
                  FilledButton.tonal(
                    onPressed: () {
                      Navigator.of(context).pop();
                      unawaited(PetSettingsPage.open(context));
                    },
                    child: Text(l10n.creditsOpenSettings),
                  ),
                ],
              ),
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _last == null ? '—' : l10n.creditsTotal(_last!.total),
                          style: theme.textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            if (_last != null) l10n.creditsAccounts(_last!.knownCount),
                            if (_last != null) l10n.creditsSnapshotAt(_clock(_last!.at)),
                            if (_tookMs != null) '${_tookMs}ms',
                            if (_last != null) config.baseUrl,
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _RefreshButton(loading: _loading, onTap: _refresh),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Text(
                  l10n.creditsFailed(_error!),
                  style: theme.textTheme.bodySmall?.copyWith(color: colors.danger),
                ),
              ),
            if (rows.isNotEmpty) ...[
              const Divider(height: 1),
              for (final row in rows)
                ListTile(
                  dense: true,
                  title: Text('…${row.label}'),
                  trailing: Text('${row.credits}', style: AppType.tabular(theme.textTheme.titleSmall!)),
                ),
            ],
            const SizedBox(height: 20),
          ],
        ],
      ),
    );
  }

  static String _clock(DateTime t) => '${t.month}/${t.day} ${t.hour}:${t.minute.toString().padLeft(2, '0')}';
}

class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.loading, required this.onTap});

  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return TextButton.icon(
      // Disabled while a request is out: a second tap used to be swallowed and
      // read as "刷新没用".
      onPressed: loading ? null : onTap,
      icon: loading
          ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.refresh, size: 18),
      label: Text(loading ? l10n.creditsRefreshing : l10n.creditsRefresh),
    );
  }
}
