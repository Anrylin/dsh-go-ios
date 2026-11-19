// What the currently selected Agent can actually do.
//
// The app was written for the native DSH Harness; CodeX and AGY expose only a
// subset of its endpoints. Instead of letting a DSH-only page or action fail
// against a virtual Agent, every surface that offers those features asks this
// table and hides (or disables) what the Agent cannot deliver. The table is
// keyed by the connection's own Agent, so an entry can never describe one
// Agent while sending a request to another.

import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'agent_selection_state.dart';
import 'connection_state.dart';
import 'hosts_state.dart';

/// Capabilities of the Agent behind the active connection.
class AgentCapabilities {
  const AgentCapabilities({
    required this.agent,
    required this.bots,
    required this.teams,
    required this.plugins,
    required this.schedules,
    required this.terminal,
    required this.jobs,
    required this.skills,
    required this.subagents,
    required this.artifacts,
    required this.exportLog,
    required this.planGoals,
    required this.sessionDetail,
    required this.tokenUsage,
    required this.webClient,
    required this.models,
    required this.permissions,
    required this.attachments,
    required this.rename,
    required this.archive,
    required this.fork,
    required this.workspaceFiles,
    required this.reference,
    required this.shareProfile,
  });

  /// The Agent this table describes.
  final RemoteAgent agent;

  // DSH-only surfaces.
  final bool bots;
  final bool teams;
  final bool plugins;
  final bool schedules;
  final bool terminal;
  final bool jobs;
  final bool skills;
  final bool subagents;
  final bool artifacts;
  final bool exportLog;
  final bool planGoals;
  final bool sessionDetail;
  final bool tokenUsage;
  final bool webClient;
  final bool reference;
  final bool shareProfile;

  // Surfaces the virtual Agents do implement.
  final bool models;
  final bool permissions;
  final bool attachments;
  final bool rename;
  final bool workspaceFiles;

  // Per-Agent gaps.
  final bool archive;
  final bool fork;

  /// Everything DSH has (本机 and an SSH Host, which runs the native Harness).
  static const AgentCapabilities dsh = AgentCapabilities(
    agent: RemoteAgent.dsh,
    bots: true,
    teams: true,
    plugins: true,
    schedules: true,
    terminal: true,
    jobs: true,
    skills: true,
    subagents: true,
    artifacts: true,
    exportLog: true,
    planGoals: true,
    sessionDetail: true,
    tokenUsage: true,
    webClient: true,
    models: true,
    permissions: true,
    attachments: true,
    rename: true,
    archive: true,
    fork: true,
    workspaceFiles: true,
    reference: true,
    shareProfile: true,
  );

  /// CodeX through its App Server: conversations, workspaces, models,
  /// approvals, attachments, rename/fork and workspace files. No DSH plugin,
  /// Bot, automation, terminal, job, skill, subagent or archive surface.
  static const AgentCapabilities codex = AgentCapabilities(
    agent: RemoteAgent.codex,
    bots: false,
    teams: false,
    plugins: false,
    schedules: false,
    terminal: false,
    jobs: false,
    skills: false,
    subagents: false,
    artifacts: false,
    exportLog: false,
    planGoals: false,
    sessionDetail: false,
    tokenUsage: false,
    webClient: false,
    models: true,
    permissions: true,
    attachments: true,
    rename: true,
    archive: false,
    fork: true,
    workspaceFiles: true,
    reference: false,
    shareProfile: false,
  );

  /// Antigravity through ACP: conversations, workspaces, models, permissions,
  /// attachments, rename/fork and workspace files. It explicitly has no
  /// session archive, and none of the DSH-only surfaces.
  static const AgentCapabilities agy = AgentCapabilities(
    agent: RemoteAgent.agy,
    bots: false,
    teams: false,
    plugins: false,
    schedules: false,
    terminal: false,
    jobs: false,
    skills: false,
    subagents: false,
    artifacts: false,
    exportLog: false,
    planGoals: false,
    sessionDetail: false,
    tokenUsage: false,
    webClient: false,
    models: true,
    permissions: true,
    attachments: true,
    rename: true,
    archive: false,
    fork: true,
    workspaceFiles: true,
    reference: false,
    shareProfile: false,
  );

  static AgentCapabilities of(RemoteAgent agent) => switch (agent) {
    RemoteAgent.dsh => dsh,
    RemoteAgent.codex => codex,
    RemoteAgent.agy => agy,
  };

  /// Whether 全部功能 entry [featureId] applies to this Agent. A DSH entry the
  /// table does not know (a plugin panel, say) belongs to the native Harness;
  /// for a virtual Agent an unknown entry is not offered, so a new DSH-only
  /// surface cannot silently appear there.
  bool supportsFeature(String featureId) => switch (featureId) {
    'models' || 'permission' || 'phone' || 'remote' || 'search' || 'workspaces' => true,
    'files' => workspaceFiles,
    'forum' || 'community' || 'voice-input' || 'cot-translation' => true,
    'session-detail' => sessionDetail,
    'artifacts' => artifacts,
    'terminal' => terminal,
    'export' => exportLog,
    'jobs' => jobs,
    'plan-goal' => planGoals,
    'skills' => skills,
    'subagents' => subagents,
    'reference' => reference,
    'schedules' => schedules,
    'token-usage' => tokenUsage,
    'plugins' => plugins,
    'cordis' => plugins,
    'agent-team' => teams,
    'ds-bot' => bots,
    'share-profile' => shareProfile,
    'web' => webClient,
    _ => agent == RemoteAgent.dsh,
  };
}

/// Capabilities of the Agent the active connection speaks to. While a switch is
/// in flight the provider still describes the destination Agent, so the UI
/// does not flash DSH-only entries during the reconnect.
final agentCapabilitiesProvider = Provider<AgentCapabilities>((ref) {
  final connection = ref.watch(activeConnectionProvider).value;
  final connectedAgent = connection?.agent;
  if (connectedAgent != null) return AgentCapabilities.of(connectedAgent);
  final host = ref.watch(activeHostProvider);
  if (host.kind == HostKind.relay) {
    return AgentCapabilities.of(ref.watch(agentSelectionProvider.select((s) => s.forHost(host.id))));
  }
  return AgentCapabilities.dsh;
});
