// 输入框下面那一行：本对话最近一次的 ↑输入 ↓输出 · 缓存 · 已完成输出的平均速度 ·
// 当前/最后速率（停下来保留，输出结束后打勾）。没有数据时整行不占位。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/chat_state.dart' show chatProvider;
import '../../../state/run_pulse.dart';
import '../../../state/token_usage.dart' show formatTokens;
import '../../theme/theme.dart';

class SessionStatsLine extends ConsumerWidget {
  const SessionStatsLine({super.key, required this.sessionId});

  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pulse = ref.watch(runPulseProvider(sessionId));
    // 已完成输出的整段平均（正在跑的那一步没有完整分母，不估算）。
    // 和 pulse 分开订阅，吐字时不会反复算。
    final turns = ref.watch(chatProvider(sessionId).select((state) => state.turns));
    final average = conversationTokensPerSecond(turns);
    return ListenableBuilder(
      listenable: pulse,
      builder: (context, _) {
        final usage = pulse.lastUsage;
        final speed = pulse.displayTps;
        // 只有真正什么都没有才收起；速度停了要留着，平均速度也算数据。
        if (usage == null && speed <= 0 && average == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final colors = DshColors.of(context);
        final l10n = context.l10n;
        final parts = <String>[
          if (usage != null) '↑${formatTokens(usage.inputTokens)}',
          // 跑动时输出数还没来,先用脉冲的估算顶上去（带 ≈）。
          if (speed > 0 && usage == null)
            '≈${formatTokens(pulse.estimatedOutput)}'
          else if (usage != null)
            '↓${formatTokens(usage.outputTokens)}',
          if (usage?.cacheReadTokens case final cached? when cached > 0)
            '${l10n.statsCache} ${formatTokens(cached)}',
          if (average != null) l10n.statsAvgRate(_rate(average)),
          if (speed > 0) '${_rate(speed)} tok/s',
        ];
        final spans = <InlineSpan>[];
        for (final part in parts) {
          if (spans.isNotEmpty) spans.add(const TextSpan(text: ' · '));
          spans.add(TextSpan(text: part));
        }
        if (pulse.rateSettled) {
          // ✓ 只说这段输出结束了；右边留的是最后一次采样速率，不是本段平均。
          spans.add(TextSpan(text: ' ✓', semanticsLabel: l10n.statsRateSettled));
        }
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text.rich(
            TextSpan(children: spans),
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

String _rate(double value) => value.toStringAsFixed(value < 10 ? 1 : 0);
