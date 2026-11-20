import '../../l10n/l10n.dart';
import '../../state/read_list_cache.dart';

/// A quiet label in an existing heading/subtitle; no progress animation and
/// no extra row that would push a retained list down during refresh.
///
/// Offline gets no label here: the session drawer owns the single global
/// 「无法连接到网络」 line, and every other page just keeps its cached data
/// without a second connectivity status.
String readListStatusText(ReadListStatus status) => switch (status) {
  ReadListStatus.current => '',
  ReadListStatus.updating => appL10n.readListUpdating,
  ReadListStatus.offline => '',
  ReadListStatus.failed => appL10n.readListFailed,
};

String readListHeading(String heading, ReadListStatus status) {
  final suffix = readListStatusText(status);
  return suffix.isEmpty ? heading : '$heading · $suffix';
}
