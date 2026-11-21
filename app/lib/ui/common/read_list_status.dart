import '../../l10n/l10n.dart';
import '../../state/read_list_cache.dart';

/// A quiet label in an existing heading/subtitle; no progress animation and
/// no extra row that would push a retained list down during refresh.
///
/// `offline` keeps a one-word label: the session drawer uses this exact text
/// as the empty-list placeholder while the host is down, so it must not be
/// empty (需求⑩ only bans the 「· 上次结果」 suffix, not the word 离线).
String readListStatusText(ReadListStatus status) => switch (status) {
  ReadListStatus.current => '',
  ReadListStatus.updating => appL10n.readListUpdating,
  ReadListStatus.offline => appL10n.readListOffline,
  ReadListStatus.failed => appL10n.readListFailed,
};

/// A heading keeps its own word and never borrows the offline placeholder:
/// connectivity lives in the drawer's one global line, not in a page heading.
String readListHeading(String heading, ReadListStatus status) {
  final suffix = status == ReadListStatus.offline ? '' : readListStatusText(status);
  return suffix.isEmpty ? heading : '$heading · $suffix';
}
