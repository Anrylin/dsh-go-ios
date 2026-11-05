// 今日用量：把主机推来的 usage 按会话摊开。数据只来自本机记录，从这一版开始计。

import 'package:flutter/material.dart';
import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/sessions_state.dart';
import '../../state/token_usage.dart';
import '../shell/page_frame.dart';
import '../theme/theme.dart';

class TokenUsagePage extends ConsumerWidget {
  const TokenUsagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    final usage = ref.watch(tokenUsageProvider);
    // 会话标题来自会话列表:拿不到就退回 id,别让一行空着。
    final titles = {
      for (final s in ref.watch(sessionsProvider).value ?? const <SessionSummary>[]) s.sessionId: s.title,
    };

    final rows = usage.bySession.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return AppPage.list(
      title: l10n.tokenUsageTitle,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpace.gutter, 8, AppSpace.gutter, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TotalCard(usage: usage),
              const SizedBox(height: 12),
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Text(
                    l10n.tokenUsageEmpty,
                    style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary),
                  ),
                )
              else
                Card(
                  margin: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (final row in rows)
                        ListTile(
                          dense: true,
                          title: Text(titles[row.key] ?? row.key, maxLines: 1, overflow: TextOverflow.ellipsis),
                          trailing: Text(formatTokens(row.value), style: AppType.tabular(theme.textTheme.titleSmall!)),
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              // 没数字先看这行：没有时间说明这一版还没收到过 usage。
              Text(
                usage.lastAt == null
                    ? l10n.tokenUsageNoData
                    : '${l10n.tokenUsageLastAt(_clock(usage.lastAt!))}\n${l10n.tokenUsageFooter}',
                style: theme.textTheme.bodySmall?.copyWith(color: colors.textTertiary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _clock(DateTime t) =>
    '${t.hour}:${t.minute.toString().padLeft(2, '0')}';

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.usage});

  final TokenUsage usage;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.tokenUsageToday, style: theme.textTheme.labelLarge?.copyWith(color: colors.textTertiary)),
            const SizedBox(height: 6),
            Text(formatTokens(usage.total), style: theme.textTheme.headlineMedium),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _Metric(label: l10n.tokenUsageInput, value: formatTokens(usage.input)),
                ),
                Expanded(
                  child: _Metric(label: l10n.tokenUsageOutput, value: formatTokens(usage.output)),
                ),
                Expanded(
                  child: _Metric(label: l10n.tokenUsageSessions, value: '${usage.bySession.length}'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(height: 2),
        Text(value, style: AppType.tabular(theme.textTheme.titleMedium!)),
      ],
    );
  }
}
