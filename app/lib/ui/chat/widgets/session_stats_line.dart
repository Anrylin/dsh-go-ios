// 输入框下面那一行：本对话最近一次的 ↑输入 ↓输出 · 缓存 · 以及当前的 tok/s。
// 没有数据时整行不占位。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/run_pulse.dart';
import '../../../state/token_usage.dart' show formatTokens;
import '../../theme/theme.dart';

class SessionStatsLine extends ConsumerWidget {
  const SessionStatsLine({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pulse = ref.watch(runPulseProvider(sessionId));
    return ListenableBuilder(
      listenable: pulse,
      builder: (context, _) {
        final usage = pulse.lastUsage;
        final speed = pulse.tokensPerSecond;
        if (usage == null && speed <= 0) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final colors = DshColors.of(context);
        final parts = <String>[
          if (usage != null) '↑${formatTokens(usage.inputTokens)}',
          // 跑动时输出数还没来,先用脉冲的估算顶上去（带 ≈）。
          if (speed > 0 && usage == null)
            '≈${formatTokens(pulse.estimatedOutput)}'
          else if (usage != null)
            '↓${formatTokens(usage.outputTokens)}',
          if (usage?.cacheReadTokens case final cached? when cached > 0)
            '${context.l10n.statsCache} ${formatTokens(cached)}',
          if (speed > 0) '${speed.toStringAsFixed(speed < 10 ? 1 : 0)} tok/s',
        ];
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            parts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.tabular(
              theme.textTheme.bodySmall!.copyWith(color: colors.textTertiary),
            ),
          ),
        );
      },
    );
  }
}
