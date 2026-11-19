import 'dart:convert';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_client/dsh_client.dart';

final _t0 = DateTime(2026, 10, 23, 14, 30);

UserChatItem user(int seq, String text) =>
    UserChatItem(seq: seq, time: _t0, text: text, images: const [], files: const []);

AssistantChatItem assistant(
  int seq,
  String text, {
  String reasoning = '',
  String? rowKey,
  bool streaming = false,
  bool interrupted = false,
}) => AssistantChatItem(
  id: streaming ? 'd$seq' : 'a$seq',
  rowKey: rowKey,
  seq: streaming ? null : seq,
  text: text,
  reasoning: reasoning,
  streaming: streaming,
  interrupted: interrupted,
);

ToolChatItem tool(
  String id,
  String name,
  Map<String, Object?> args, {
  ToolStatus status = ToolStatus.succeeded,
  String result = '',
  Object? meta,
  ApprovalRequest? pending,
}) => ToolChatItem(
  callId: id,
  name: name,
  arguments: jsonEncode(args),
  status: status,
  resultParts: result.isEmpty ? const [] : [TextPart(result)],
  meta: meta,
  pendingApproval: pending,
);

const sandboxRefusal =
    'Error: sandbox mode "workspace-write" is requested but no sandbox backend '
    'is usable on this host; refusing to run the command unconfined. Install '
    'bubblewrap or run a Landlock-enforcing kernel';

final approval = ApprovalRequest(
  eventId: 'evt-approval-1',
  sessionId: 's1',
  toolName: 'bash',
  callId: 'call-test',
  reason: 'escalate sandbox to danger-full-access: run the auth tests',
);

/// A finished exchange: reasoning, two tool rows, Markdown with code, an
/// edit with a diff count, the Android sandbox refusal and a pending approval.
ChatState conversationState() {
  final items = <ChatItem>[
    user(1, '登录按钮连点会重复提交,帮我看看是哪里的问题,顺便修一下。'),
    assistant(2, '先看一下登录控制器和相关的调用点。', reasoning: '用户说登录会重复提交。先读 login_controller.dart,再搜一下 submit 的调用点。'),
    tool(
      'call-read',
      'read',
      {'file_path': '/root/workspace/app/lib/auth/login_controller.dart'},
      result: '<path>…</path>',
      meta: {
        'path': 'app/lib/auth/login_controller.dart',
        'offset': 1,
        'lines': [
          {'number': 40, 'text': 'Future<void> submit() async {'},
          {'number': 41, 'text': '  final result = await _api.login(email, password);'},
          {'number': 42, 'text': '  _submitting = false;'},
          {'number': 43, 'text': '  state = result;'},
          {'number': 44, 'text': '}'},
        ],
        'totalLines': 88,
        'lang': 'dart',
      },
    ),
    tool('call-grep', 'grep', {
      'pattern': 'submit\\(',
      'path': '/root/workspace/app/lib',
    }, result: 'lib/auth/login_page.dart:52:  onPressed: controller.submit,'),
    assistant(
      3,
      '**原因**:提交按钮只在请求返回后才禁用,两次点击之间的 `await` 让第二次点击也进了 `submit()`。\n\n'
          '修复思路:\n\n1. 进入 `submit()` 时立刻置 `_submitting = true`\n2. 请求结束后在 `finally` 里复位',
    ),
    tool('call-edit', 'edit', {
      'file_path': '/root/workspace/app/lib/auth/login_controller.dart',
      'old_string': 'final result = await _api.login(email, password);',
      'new_string': 'if (_submitting) return;\n  _submitting = true;\n  try {\n    state = await _api.login(email, password);',
    }, result: 'The file has been updated.'),
    assistant(4, '改好了,跑一遍登录相关的测试确认一下。'),
    tool(
      'call-sandbox',
      'bash',
      {'command': 'flutter test test/auth', 'description': '运行登录相关测试'},
      status: ToolStatus.failed,
      result: sandboxRefusal,
    ),
    tool(
      'call-test',
      'bash',
      {'command': 'flutter test test/auth', 'description': '运行登录相关测试', 'sandbox_permissions': 'danger-full-access'},
      status: ToolStatus.awaitingApproval,
      pending: approval,
    ),
  ];
  return ChatState(
    items: items,
    running: true,
    title: '修复登录重复提交',
    approvals: [approval],
    loading: false,
    model: const ModelSelection(provider: 'deepseek-official', model: 'deepseek-v4-pro', reasoningEffort: 'high'),
  );
}

/// Mid-stream: a collapsed tool group, then an answer still arriving.
ChatState streamingState() {
  final items = <ChatItem>[
    user(1, '这个项目的测试是怎么组织的?'),
    tool('c1', 'glob', {'pattern': '**/*_test.dart'}, result: '12 files'),
    tool('c2', 'read', {'file_path': '/root/workspace/app/test/widget_test.dart'}),
    tool('c3', 'bash', {'command': 'flutter test --reporter compact'}, result: '\x1B[32m+42\x1B[0m: All tests passed!'),
    assistant(
      2,
      '测试分成三层:\n\n- **单元测试**放在 `test/unit/`,只测纯 Dart 逻辑;\n'
      '- **组件测试**在 `test/widgets/`,用 `pumpWidget` 渲染单个页面;\n'
      '- 集成测试在 `integration_test/`,需要真机或模拟器',
      reasoning: '先找测试文件,再看看运行结果。',
      streaming: true,
    ),
  ];
  return ChatState(
    items: items,
    running: true,
    title: '测试结构',
    loading: false,
    model: const ModelSelection(provider: 'deepseek-official', model: 'deepseek-flash', reasoningEffort: 'low'),
  );
}

/// The same conversation after "本对话都允许": the pending call runs on.
ChatState autoApproveState() {
  final base = conversationState();
  return ChatState(
    items: base.items,
    running: true,
    title: base.title,
    approvals: base.approvals,
    loading: false,
    model: base.model,
    autoApprove: true,
    autoAnswered: {approval.eventId},
  );
}
