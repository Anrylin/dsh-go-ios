// 「智能体」: which Agent the app talks to on the current remote Host.
//
// One Agent per connection, chosen here. Selecting a row reconnects to that
// Agent's own workspaces and conversations; it is not a filter over a shared
// list, so nothing from another Agent can appear or be sent.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;

import '../../../l10n/l10n.dart';
import '../../../state/agent_selection_state.dart';
import '../../common/app_sheet.dart';
import '../../common/list_page_row.dart';
import '../../common/sheet_title_bar.dart';
import '../../theme/app_icons.dart';

/// Opens the Agent sheet for [hostId]; it closes on drag, a tap outside, or a
/// selection (which reconnects).
Future<void> showAgentSelectionSheet(BuildContext context, String hostId) async {
  await showAppSheet<void>(context, builder: (_) => AgentSelectionSheet(hostId: hostId));
}

class AgentSelectionSheet extends ConsumerWidget {
  const AgentSelectionSheet({super.key, required this.hostId});

  final String hostId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final current = ref.watch(agentSelectionProvider.select((s) => s.forHost(hostId)));
    final notifier = ref.read(agentSelectionProvider.notifier);
    Future<void> choose(RemoteAgent agent) async {
      await notifier.select(hostId, agent);
      if (context.mounted) Navigator.of(context).maybePop();
    }

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetTitleBar(l10n.pluginsNamespaceAgent),
          SheetGroup(
            margin: const EdgeInsets.fromLTRB(SheetTitleBar.inset, 0, SheetTitleBar.inset, 12),
            children: [
              for (final agent in agentSelectionOrder)
                MergeSemantics(
                  child: ListPageRow(
                    icon: agentIcon(agent),
                    title: agent.code,
                    trailing: agent == current ? Icon(AppIcons.selected, size: 18) : null,
                    onTap: () => unawaited(choose(agent)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// Each Agent's glyph, shared by the sheet and the drawer key.
IconData agentIcon(RemoteAgent agent) => switch (agent) {
  RemoteAgent.codex => AppIcons.terminal,
  RemoteAgent.agy => AppIcons.subagents,
  RemoteAgent.dsh => AppIcons.engine,
};
