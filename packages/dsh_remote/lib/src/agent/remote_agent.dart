/// Which Agent a remote connection speaks to.
///
/// One connection carries exactly one Agent: the drawer's selector picks it,
/// and every workspace, conversation, model and stream on that client belongs
/// to it. Switching the Agent is a new connection, never a filter over a
/// shared list, so a request can never reach an Agent other than the one shown.
library;

/// RPC endpoints only the native DSH Harness implements, and whose effect is a
/// write to the real Harness state (archived conversations).
///
/// A CodeX or AGY connection must not forward them to the physical Host behind
/// the virtual layer: the app hides the archive actions there, and a stray
/// call (a stale sheet, a deep link, an older build) would otherwise archive a
/// DSH conversation while the person is looking at another Agent.
const Set<String> dshOnlyRemoteEndpoints = <String>{
  'session/archive',
  'session/unarchive',
};

/// The Agents a Host can expose.
enum RemoteAgent {
  /// The native DSH Harness: every endpoint and feature DSH itself has.
  dsh('DSH'),

  /// OpenAI CodeX through its App Server.
  codex('CodeX'),

  /// Antigravity through its ACP backend.
  agy('AGY');

  const RemoteAgent(this.code);

  /// Stable wire/prefs code (`DSH`, `CodeX`, `AGY`); never translated.
  final String code;

  /// Parses a stored/wire code; unknown or empty values fall back to [dsh].
  static RemoteAgent parse(String? code) {
    for (final agent in RemoteAgent.values) {
      if (agent.code == code?.trim()) return agent;
    }
    return RemoteAgent.dsh;
  }
}
