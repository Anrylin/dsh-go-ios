import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/common/read_list_status.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

ModelCatalog _catalog(String model) => ModelCatalog(
      defaultSelection: ModelSelection(provider: 'deepseek', model: model),
      routableProviders: const [],
      groups: const [],
      failures: const [],
    );

void main() {
  setUp(() => AppLocale.use(AppLocale.zhCN));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('read list headings never append 上次结果, and offline stays a one-word placeholder', () {
    expect(readListStatusText(ReadListStatus.current), '');
    // 需求⑩: no 「上次结果」 suffix; the word 离线 itself must stay —
    // the drawer uses it as the empty-list placeholder while the host is down.
    expect(readListStatusText(ReadListStatus.offline), '离线');
    expect(readListStatusText(ReadListStatus.updating), '更新中');
    expect(readListStatusText(ReadListStatus.failed), '未更新');
    // A heading never borrows the offline placeholder.
    expect(readListHeading('模型', ReadListStatus.offline), '模型');
    expect(readListHeading('模型', ReadListStatus.current), '模型');
    expect(readListHeading('模型', ReadListStatus.updating), '模型 · 更新中');
    expect(readListHeading('模型', ReadListStatus.failed), '模型 · 未更新');
  });

  test('English read list copy keeps a one-word offline placeholder', () {
    AppLocale.use(AppLocale.en);
    expect(readListStatusText(ReadListStatus.offline), 'Offline');
    expect(readListStatusText(ReadListStatus.failed), 'Not updated');
    expect(readListStatusText(ReadListStatus.updating), 'Updating');
  });

  test('model chip stays optimistic with no live catalog', () {
    final cached = _catalog('deepseek-chat');
    final live = _catalog('deepseek-reasoner');
    final explicit = ModelSelection(provider: 'custom', model: 'my-model');

    // No connection, no settings snapshot, cached catalog: still a choice.
    expect(
      optimisticModelSelection(null, null, null, cached),
      cached.defaultSelection,
    );
    // Live catalog wins over cache when both exist.
    expect(
      optimisticModelSelection(null, null, live, cached),
      live.defaultSelection,
    );
    // An explicit pick wins over every default.
    expect(
      optimisticModelSelection(explicit, null, live, cached),
      explicit,
    );
    // Nothing at all is still null, not a fake pick.
    expect(optimisticModelSelection(null, null, null, null), isNull);
  });

  test('the new quiet copy exists in both languages', () {
    expect(appL10n.chatPreparingEllipsis, '准备中…');
    expect(appL10n.shellNetworkUnavailable, '无法连接到网络');
    expect(appL10n.viewModelRefreshing, '正在获取最新模型');

    AppLocale.use(AppLocale.en);
    expect(appL10n.chatPreparingEllipsis, 'One moment…');
    expect(appL10n.shellNetworkUnavailable, 'Can’t connect to the network');
    expect(appL10n.viewModelRefreshing, 'Getting the latest models');
  });
}
