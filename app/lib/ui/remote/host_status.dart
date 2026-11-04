import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../runtime/runtime_state.dart';
import '../../state/connection_state.dart';
import '../../state/hosts_state.dart';
import '../common/status_dot.dart';
import '../engine/engine_status.dart';
import '../theme/app_icons.dart';

/// Dot + words for a host's state. Colour is never the only signal.
class HostStatusView {
  const HostStatusView(this.tone, this.label);

  final StatusTone tone;
  final String label;

  static HostStatusView ofLink(HostLinkStatus status) => switch (status.phase) {
    HostLinkPhase.idle => HostStatusView(StatusTone.idle, appL10n.commonNotConnected),
    HostLinkPhase.connecting => HostStatusView(
      StatusTone.busy,
      status.step == null ? appL10n.remoteConnecting : '${status.step!.label}…',
    ),
    HostLinkPhase.connected => HostStatusView(StatusTone.ok, appL10n.remoteConnected),
    HostLinkPhase.reconnecting => HostStatusView(StatusTone.warn, appL10n.remoteReconnecting),
    HostLinkPhase.failed => HostStatusView(StatusTone.error, appL10n.commonConnectionFailed),
  };

  static HostStatusView ofRelayHost(RelayHost host) => host.online
      ? HostStatusView(StatusTone.ok, appL10n.remoteOnline)
      : HostStatusView(StatusTone.idle, appL10n.remoteOffline);
}

/// Live status of [host]: the engine for 本机, the link for remote hosts.
HostStatusView watchHostStatus(WidgetRef ref, HostRef host) {
  if (host.isLocal) {
    final view = EngineStatusView.of(ref.watch(localRuntimeProvider));
    return HostStatusView(view.tone, view.label);
  }
  final status = ref.watch(hostLinkStatusProvider(host)).value ?? HostLinkStatus.idle;
  // 有一条活着的连接就是「已连接」。
  //
  // 连线对象是 autoDispose 的:抽屉、设置、网页版各自 watch 一次,重建时可能
  // 换成新实例,而旧的实例交出去的 client 还在跑。新实例从第一步(连接服务器)
  // 起步,于是页脚一直显示「正在连接」,人却早就连上了。连接本身是事实,
  // 状态文字要跟着事实走。
  if (!status.isConnected) {
    final connection = ref.watch(activeConnectionProvider).value;
    if (connection != null && !connection.isLocal && connection.hostId == host.id) {
      return HostStatusView(StatusTone.ok, appL10n.remoteConnected);
    }
  }
  return HostStatusView.ofLink(status);
}

IconData hostKindIcon(HostKind kind) => switch (kind) {
  HostKind.local => AppIcons.thisPhone,
  HostKind.ssh => AppIcons.sshHost,
  HostKind.relay => AppIcons.computer,
};

/// Identity tint per kind (one of the 8 fixed pairs), so rows read as a set.
int hostKindTint(HostKind kind) => switch (kind) {
  HostKind.local => 0,
  HostKind.ssh => 6,
  HostKind.relay => 1,
};
