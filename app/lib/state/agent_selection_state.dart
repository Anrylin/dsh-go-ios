// Which Agent the app talks to on one remote Host.
//
// A connection carries exactly one Agent, so this is a single choice per Host,
// not a filter over a merged list: switching it reconnects, and every
// workspace, conversation, model and request afterwards belongs to that Agent.
// 本机 (the on-device engine) is always DSH and never offers a choice.

import 'dart:convert';

import 'package:dsh_remote/dsh_remote.dart' show RemoteAgent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hosts_state.dart';

/// The drawer's Agent order: native first, then the virtual layers.
const List<RemoteAgent> agentSelectionOrder = <RemoteAgent>[
  RemoteAgent.dsh,
  RemoteAgent.codex,
  RemoteAgent.agy,
];

/// Per-Host choice (JSON: `{"hostId":"CodeX",...}`); app-wide, not per account.
const String agentSelectionPrefsKey = 'drawer.agent';

/// A Host's Agent choice, plus the last one used anywhere as the default for
/// a Host this phone has never opened.
class AgentSelection {
  const AgentSelection({this.defaultAgent = RemoteAgent.dsh, this.byHost = const <String, RemoteAgent>{}});

  final RemoteAgent defaultAgent;

  /// Host id → Agent. Only hosts with an explicit choice appear here.
  final Map<String, RemoteAgent> byHost;

  /// The Agent for [hostId]; DSH for 本机 (null) and unknown hosts.
  RemoteAgent forHost(String? hostId) {
    if (hostId == null || hostId.isEmpty) return RemoteAgent.dsh;
    return byHost[hostId] ?? defaultAgent;
  }

  AgentSelection withHost(String hostId, RemoteAgent agent) => AgentSelection(
    defaultAgent: agent,
    byHost: {...byHost, hostId: agent},
  );

  /// Stable storage form: host id → code, in insertion order.
  Map<String, Object?> toJson() => <String, Object?>{
    'default': defaultAgent.code,
    'hosts': <String, Object?>{for (final entry in byHost.entries) entry.key: entry.value.code},
  };

  /// Unknown codes fall back to DSH; damaged values never break a connection.
  static AgentSelection fromJson(Object? raw) {
    if (raw is! Map) return const AgentSelection();
    final hosts = <String, RemoteAgent>{};
    final byHost = raw['hosts'];
    if (byHost is Map) {
      for (final entry in byHost.entries) {
        final id = entry.key;
        if (id is String && id.isNotEmpty) hosts[id] = RemoteAgent.parse(entry.value as String?);
      }
    }
    return AgentSelection(defaultAgent: RemoteAgent.parse(raw['default'] as String?), byHost: hosts);
  }
}

/// The Agent choice across Hosts. [select] updates one Host; persistence is
/// best-effort so a missing preferences backend only costs the choice on restart.
class AgentSelectionController extends Notifier<AgentSelection> {
  Future<void> _loading = Future.value();
  bool _loaded = false;

  @override
  AgentSelection build() {
    _loading = _load();
    return const AgentSelection();
  }

  /// Completes once the stored choice has loaded.
  Future<void> ready() => _loading;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_loaded) return;
      final raw = prefs.getString(agentSelectionPrefsKey);
      if (raw != null && raw.isNotEmpty) {
        state = AgentSelection.fromJson(json.decode(raw));
      }
    } catch (_) {
      // No preferences backend (tests) or damaged JSON: keep the default.
    } finally {
      _loaded = true;
    }
  }

  /// Chooses [agent] for [hostId]. Same value is a no-op, so a tap cannot
  /// restart a healthy connection.
  Future<void> select(String hostId, RemoteAgent agent) async {
    if (hostId.isEmpty) return;
    await _loading;
    final current = state.forHost(hostId);
    if (current == agent) return;
    state = state.withHost(hostId, agent);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(agentSelectionPrefsKey, json.encode(state.toJson()));
    } catch (_) {
      // Kept in memory for this run.
    }
  }
}

final agentSelectionProvider = NotifierProvider<AgentSelectionController, AgentSelection>(
  AgentSelectionController.new,
);

/// The Agent of the active Host: DSH for 本机 and for an SSH Host (which runs
/// the native Harness), the stored choice for a relay Host.
final activeAgentProvider = Provider<RemoteAgent>((ref) {
  final host = ref.watch(activeHostProvider);
  if (host.kind != HostKind.relay) return RemoteAgent.dsh;
  return ref.watch(agentSelectionProvider.select((s) => s.forHost(host.id)));
});
