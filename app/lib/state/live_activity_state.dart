// Keeps the live activity (lib/notify/live_activity.dart) fed: the global pet
// state in words, pushed to `dsh/notify` whenever it changes.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../notify/live_activity.dart';
import '../pets/pet_signals.dart';
import '../pets/pet_state.dart';
import 'notify_state.dart';

export '../notify/live_activity.dart';

/// Titles of conversations seen running, so a finished one keeps its name.
final _liveTitlesProvider = Provider<Map<PetTarget, String>>((ref) => <PetTarget, String>{});

/// What the live activity shows now; null: nothing. Reads the pet's own
/// signals, so it sees exactly what the pet sees.
final liveActivityProvider = Provider<LiveActivity?>((ref) {
  final signals = ref.watch(petSignalsProvider);
  final titles = ref.watch(_liveTitlesProvider);
  learnLiveTitles(titles, signals.runs);
  final prefs = ref.watch(notifyPrefsProvider);
  final activity = liveActivityOf(
    pet: ref.watch(petStateProvider),
    runs: signals.runs,
    pending: signals.pending,
    titles: titles,
    showDone: prefs.done,
    showFailed: prefs.failed,
  );
  // 没有活儿的时候也留一张「待命」的卡：在岛上就一直有位置，不必等下一次
  // 状态变化才出现（前台尤其明显——那时新状态往往要等到下一轮才推）。
  return activity ?? idleActivityOf(ref.watch(petStateProvider));
});

/// 空闲时的活动：标题留给当前会话（拿不到就用 DSH），没有计时。
LiveActivity idleActivityOf(PetState pet) {
  final l10n = appL10n;
  return LiveActivity(
    kind: LiveKind.idle,
    title: 'DSH',
    text: l10n.liveIdleText,
    chip: l10n.liveChipIdle,
    publicText: l10n.liveIdleText,
    mood: pet.state,
  );
}

/// What `dsh/notify` is told: off with notifications or the switch, else the
/// activity and the pet whose pictures it uses.
final livePushProvider = Provider<LivePush>((ref) {
  final enabled = ref.watch(notifyPrefsProvider.select((p) => p.enabled && p.live));
  return LivePush(
    enabled: enabled,
    packId: ref.watch(petStateProvider.select((s) => s.packId == noPetId ? null : s.packId)),
    activity: enabled ? ref.watch(liveActivityProvider) : null,
  );
});

/// Watch it to keep the live activity fed (with the pet overlay's bridge, in
/// both 原生 and 网页 modes). Equal pushes are not sent twice.
final liveActivityBridgeProvider = Provider<void>((ref) {
  ref.listen<LivePush>(livePushProvider, (previous, next) {
    if (previous == next) return;
    unawaited(ref.read(notifyChannelProvider).live(next));
  }, fireImmediately: true);
});

/// What the phone offers; re-read with `ref.invalidate` when the app comes back.
final liveSystemStatusProvider = FutureProvider<LiveSystemStatus>(
  (ref) => ref.watch(notifyChannelProvider).liveStatus(),
);
