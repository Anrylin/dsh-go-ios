// 「发送失败」 must say something a person can act on, in their own language.
//
// Two halves, tested separately:
//   * the headline — a known code becomes a sentence, an unknown one degrades
//     to the bare action label and never to the Host's English;
//   * the 「详情」 line — whitelisted keys only, redacted, length-capped.

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/chat_error_text.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => AppLocale.use(AppLocale.zhCN));
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  group('headline', () {
    /// Every code the fix promises to word, and the sentence it becomes.
    const cases = <String, (String zh, String en)>{
      'session/agent-busy': ('AI 正忙，稍后再试', 'AI is busy. Try again later.'),
      'session/writer-held': ('这个对话正在别处使用', 'This chat is in use elsewhere'),
      'CODEX_THREAD_BUSY': ('另一端正在操作这个 Codex 对话，等它结束后会自动重试', 'The other end is working in this Codex chat. It will retry when that finishes.'),
      'CODEX_TURN_OWNED': ('另一端正在操作这个 Codex 对话，等它结束后会自动重试', 'The other end is working in this Codex chat. It will retry when that finishes.'),
      'CODEX_UPSTREAM_ERROR:active writer': ('另一端正在操作这个 Codex 对话，等它结束后会自动重试', 'The other end is working in this Codex chat. It will retry when that finishes.'),
      'RATE_LIMITED': ('请求太频繁，稍后再试', 'Too many requests. Try again later.'),
      'CODEX_UNAVAILABLE': ('CodeX 暂时用不了，稍后再试', 'CodeX is unavailable. Try again later.'),
      'FEATURE_NOT_SUPPORTED': ('当前引擎版本不支持这个操作', 'This engine version doesn’t support this action'),
      'INVALID_MESSAGE': ('这次请求的内容引擎没看懂，换个说法再试', 'The engine couldn’t read this request. Try wording it differently.'),
      'steer-unavailable': ('这一轮已经结束，消息会作为新一轮发送', 'This turn has ended. Your message will start a new turn.'),
      'workspace-not-found': ('这个工作区已经不在了', 'This workspace is gone'),
      'session/model-unavailable': ('这个模型现在用不了', 'This model is unavailable'),
      'attachment-error': ('这个附件发不了', 'Can’t send this attachment'),
      'session/fork-unavailable': ('这里不能分叉', 'Can’t branch here'),
      'FRAME_TOO_LARGE': ('图片太大，少选几张再发', 'Images are too large. Send fewer at once.'),
    };

    cases.forEach((code, words) {
      test('$code is worded in both languages', () {
        final error = code.startsWith('CODEX_UPSTREAM_ERROR:')
            ? const DshRemoteException('CODEX_UPSTREAM_ERROR', 'An active writer owns this turn.')
            : DshRemoteException(code, 'host text nobody should see');
        expect(chatErrorText(error, action: '发送失败'), '发送失败：${words.$1}');
        AppLocale.use(AppLocale.en);
        expect(chatErrorText(error, action: 'Couldn’t send'), 'Couldn’t send: ${words.$2}');
      });
    });

    test('an unknown code keeps only the action label', () {
      final error = DshRemoteException('some/new-code', 'The CodeX command image list is required.');
      final text = chatErrorText(error, action: '发送失败');
      expect(text, '发送失败');
      expect(text, isNot(contains('image list')));
      expect(text, isNot(contains('some/new-code')));
    });

    test('a transport failure still says the engine is unreachable', () {
      final text = chatErrorText(const DshTransportException('socket closed'), action: '发送失败');
      expect(text, startsWith('发送失败：'));
    });

    test('an HTTP rejection without a mapped reason reads as unreachable', () {
      final text = chatErrorText(const DshHttpException(502, 'Bad Gateway'), action: '发送失败');
      expect(text, startsWith('发送失败：'));
    });
  });

  group('details', () {
    test('keeps whitelisted keys and drops everything else', () {
      final error = DshRemoteException('gateway/arguments-invalid', 'bad field', {
        'field': 'images',
        'statusCode': 400,
        'message': 'the whole Host sentence',
        'stack': 'at foo (/Users/someone/app/lib/main.dart:12)',
        'nested': {'anything': true},
      });
      final details = chatErrorDetails(error);
      expect(details, contains('field=images'));
      expect(details, contains('statusCode=400'));
      expect(details, isNot(contains('the whole Host sentence')));
      expect(details, isNot(contains('someone')));
      expect(details, isNot(contains('nested')));
    });

    test('redacts URLs, paths, tokens and addresses', () {
      final error = DshRemoteException('RATE_LIMITED', 'slow down', {
        'endpoint': 'https://api.example.com/v1/chat?key=abcdef0123456789abcdef',
        'scope': '/Users/someone/work/secret-project',
        'provider': 'acct-someone@example.com',
        'transport': 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9payload',
      });
      final details = chatErrorDetails(error);
      expect(details, isNot(contains('example.com')));
      expect(details, isNot(contains('someone')));
      expect(details, isNot(contains('secret-project')));
      expect(details, contains('<url>'));
      expect(details, contains('<path>'));
      expect(details, contains('<email>'));
    });

    test('redacts bare hosts, CJK paths and short credentials', () {
      final error = DshRemoteException('INVALID_MESSAGE', 'x', {
        'endpoint': 'gateway.internal.example.com/v1/chat',
        'scope': '/Users/张三/私密/project',
        'provider': 'sk-abc12345',
        'field': 'apiKey=abcdef123456',
      });
      final details = chatErrorDetails(error);
      expect(details, isNot(contains('example.com')));
      expect(details, isNot(contains('张三')));
      expect(details, isNot(contains('72189689')));
      expect(details, isNot(contains('abcdef123456')));
      expect(details, contains('<url>'));
      expect(details, contains('<path>'));
      expect(details, contains('<token>'));
    });

    test('an HTTP body never reaches the expandable details', () {
      const error = DshHttpException(502, 'Bad Gateway', body: '<html>BO主机原文</html> token=sk-abc12345');
      final details = chatErrorDetails(error);
      expect(details, contains('statusCode=502'));
      expect(details, isNot(contains('BO主机原文')));
      expect(details, isNot(contains('Bad Gateway')));
      expect(details, isNot(contains('sk-abc12345')));
    });

    test('caps the whole line', () {
      final error = DshRemoteException('INVALID_MESSAGE', 'x', {
        'reason': 'y' * 400,
        'kind': 'k' * 400,
        'phase': 'p' * 400,
      });
      expect(chatErrorDetails(error).length, lessThanOrEqualTo(errorDigestLimit + 1));
    });

    test('is empty when there is nothing to show', () {
      expect(chatErrorDetails(null), '');
      expect(chatErrorDetails(const DshRemoteException('session/agent-busy', 'busy')), '');
      expect(chatErrorDetails(const DshTransportException('socket closed')), '');
      expect(chatErrorDetails(const DshHttpException(502, 'Bad Gateway', body: '')), isNotEmpty);
    });

    test('the log line carries the same digest', () {
      const error = DshRemoteException('gateway/bad-request', 'bad', {'field': 'images', 'statusCode': 400});
      expect(error.toString(), contains('field=images'));
      expect(error.toString(), contains('statusCode=400'));
    });
  });
}
