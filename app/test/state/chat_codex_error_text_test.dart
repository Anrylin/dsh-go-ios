import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/chat_error_text.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const busy = DshRemoteException('CODEX_THREAD_BUSY', 'another client owns this thread');
  const owned = DshRemoteException('CODEX_TURN_OWNED', 'not the turn owner');
  const upstream = DshRemoteException('CODEX_UPSTREAM_ERROR', 'an active writer is already attached');
  const timeout = DshRemoteException('CODEX_REQUEST_TIMEOUT', 'upstream timed out');

  tearDown(() => AppLocale.use(AppLocale.zhCN));

  test('codexThreadBusy matches only definite writer-ownership refusals', () {
    expect(codexThreadBusy(busy), isTrue);
    expect(codexThreadBusy(owned), isTrue);
    expect(codexThreadBusy(upstream), isTrue);
    expect(codexThreadBusy(timeout), isFalse);
    expect(codexThreadBusy(const DshRemoteException('session/writer-held', 'held')), isFalse);
    expect(codexThreadBusy(const DshRemoteException('session/agent-busy', 'busy')), isFalse);
    expect(codexThreadBusy(const DshTransportException('lost')), isFalse);
    expect(codexThreadBusy(const DshCarrierLostException('gone')), isFalse);
  });

  test('busy text explains the other client in both languages', () {
    AppLocale.use(AppLocale.zhCN);
    expect(chatErrorText(busy, action: '发送失败'), contains('另一端正在操作这个 Codex 对话'));
    expect(chatErrorText(owned, action: '插话'), contains('另一端正在操作这个 Codex 对话'));
    expect(chatErrorText(upstream, action: '发送失败'), contains('另一端正在操作这个 Codex 对话'));

    AppLocale.use(AppLocale.en);
    final english = chatErrorText(busy, action: 'Send failed');
    expect(english, contains('other end'));
    expect(english, contains('Codex chat'));

    // DSH's own lease code stays a different explanation.
    AppLocale.use(AppLocale.zhCN);
    expect(
      chatErrorText(const DshRemoteException('session/writer-held', 'held'), action: '发送失败'),
      contains('这个对话正在别处使用'),
    );
  });
}
