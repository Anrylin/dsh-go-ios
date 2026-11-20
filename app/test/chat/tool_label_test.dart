import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/chat_alerts.dart';
import 'package:dsh_app/ui/chat/step_detail_page.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/approval_card.dart';
import 'package:dsh_app/ui/common/tool_glyph.dart';

ToolChatItem _tool(
  String name, {
  ToolStatus status = ToolStatus.succeeded,
  Map<String, Object?> args = const {},
}) => ToolChatItem(
      callId: 'call-$name',
      name: name,
      arguments: jsonEncode(args),
      status: status,
    );

void expectLanguage(Locale locale, void Function() checks) {
  addTearDown(() => AppLocale.use(AppLocale.zhCN));
  AppLocale.use(locale);
  checks();
}

Map<String, dynamic> _readArb(String path) => jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

void main() {
  test('tool labels are localized in Chinese', () {
    expectLanguage(AppLocale.zhCN, () {
      expect(ToolGlyphs.labelFor('list_agents'), '列出子代理');
      expect(ToolGlyphs.labelFor('list_subagent_models'), '列出子代理模型');
      expect(ToolGlyphs.labelFor('mcp__x__y'), '连接器 · y');
      expect(ToolGlyphs.labelFor('codex.command'), '运行');
      expect(ToolGlyphs.labelFor('codex.subagent'), '子代理');
      expect(ToolGlyphs.labelFor('codex.webSearch'), '联网搜索');
      expect(ToolGlyphs.labelFor('codex.image'), '查看图片');
      expect(ToolGlyphs.labelFor('codex.reviewMode'), '审阅模式');
      expect(ToolGlyphs.labelFor('codex.fileChange'), '修改文件');
      expect(ToolGlyphs.labelFor('codex.compaction'), '调用工具');
      expect(ToolGlyphs.labelFor('codex.mcpToolCall'), '连接器');
      expect(ToolGlyphs.labelFor('codex.unknownThing'), '调用工具');
      expect(ToolGlyphs.labelFor('mystery_tool'), '调用工具');
    });
  });

  test('tool labels are localized in English', () {
    expectLanguage(AppLocale.en, () {
      expect(ToolGlyphs.labelFor('list_agents'), 'List subagents');
      expect(ToolGlyphs.labelFor('list_subagent_models'), 'List subagent models');
      expect(ToolGlyphs.labelFor('mcp__x__y'), 'Connector · y');
      expect(ToolGlyphs.labelFor('codex.command'), 'Run');
      expect(ToolGlyphs.labelFor('codex.subagent'), 'Subagent');
      expect(ToolGlyphs.labelFor('codex.webSearch'), 'Web search');
      expect(ToolGlyphs.labelFor('codex.image'), 'View image');
      expect(ToolGlyphs.labelFor('codex.reviewMode'), 'Review mode');
      expect(ToolGlyphs.labelFor('codex.fileChange'), 'Edit file');
      expect(ToolGlyphs.labelFor('codex.compaction'), 'Call tool');
      expect(ToolGlyphs.labelFor('codex.mcpToolCall'), 'Connector');
      expect(ToolGlyphs.labelFor('codex.unknownThing'), 'Call tool');
      expect(ToolGlyphs.labelFor('mystery_tool'), 'Call tool');
    });
  });

  test('compaction verb distinguishes running, success and failed states', () {
    expectLanguage(AppLocale.zhCN, () {
      expect(ToolView.of(_tool('codex.compaction', status: ToolStatus.running)).verb, '优化对话');
      expect(ToolView.of(_tool('codex.compaction', status: ToolStatus.succeeded)).verb, '已优化对话');
      expect(ToolView.of(_tool('codex.compaction', status: ToolStatus.failed)).verb, '调用工具');
      // step_detail_page uses this helper, not labelFor, so the row agrees.
      expect(toolStepVerb(_tool('codex.compaction', status: ToolStatus.succeeded)), '已优化对话');
      expect(toolStepVerb(_tool('codex.compaction', status: ToolStatus.failed)), '调用工具');
    });
    expectLanguage(AppLocale.en, () {
      expect(ToolView.of(_tool('codex.compaction', status: ToolStatus.running)).verb, 'Optimizing conversation');
      expect(ToolView.of(_tool('codex.compaction', status: ToolStatus.succeeded)).verb, 'Conversation optimized');
      expect(ToolView.of(_tool('codex.compaction', status: ToolStatus.failed)).verb, 'Call tool');
      expect(toolStepVerb(_tool('codex.compaction', status: ToolStatus.succeeded)), 'Conversation optimized');
    });
  });

  test('compaction labelFor is neutral and approval text agrees with the card', () {
    const request = ApprovalRequest(eventId: 'e-compaction', sessionId: 's', toolName: 'codex.compaction');
    expectLanguage(AppLocale.zhCN, () {
      expect(ToolGlyphs.labelFor('codex.compaction'), '调用工具');
      expect(approvalText(request), appL10n.stateAlertApprovalAction(appL10n.stateAlertUseTool('调用工具')));
      final awaiting = ToolView.of(_tool('codex.compaction', status: ToolStatus.awaitingApproval));
      expect(approvalCardTitle(request, awaiting), '允许使用「调用工具」？');
      expect(approvalCardTitle(request, null), '允许使用「调用工具」？');
    });
    expectLanguage(AppLocale.en, () {
      expect(ToolGlyphs.labelFor('codex.compaction'), 'Call tool');
      expect(approvalText(request), appL10n.stateAlertApprovalAction(appL10n.stateAlertUseTool('Call tool')));
      final awaiting = ToolView.of(_tool('codex.compaction', status: ToolStatus.awaitingApproval));
      expect(approvalCardTitle(request, awaiting), 'Allow “Call tool”?');
      expect(approvalCardTitle(request, null), 'Allow “Call tool”?');
    });
  });

  test('command and MCP tool names keep their special verbs', () {
    expectLanguage(AppLocale.zhCN, () {
      expect(ToolView.of(_tool('codex.command', args: {'command': 'ls'})).verb, '运行');
      expect(
        ToolView.of(_tool('codex.mcpToolCall', args: {'name': 'filesystem.read'})).verb,
        '连接器 · filesystem.read',
      );
      expect(ToolView.of(_tool('codex.mcpToolCall')).verb, '连接器');
    });
    expectLanguage(AppLocale.en, () {
      expect(ToolView.of(_tool('codex.command', args: {'command': 'ls'})).verb, 'Run');
      expect(
        ToolView.of(_tool('codex.mcpToolCall', args: {'name': 'filesystem.read'})).verb,
        'Connector · filesystem.read',
      );
      expect(ToolView.of(_tool('codex.mcpToolCall')).verb, 'Connector');
    });
  });

  test('approval card title uses the same localized verb', () {
    const request = ApprovalRequest(eventId: 'e', sessionId: 's', toolName: 'codex.mcpToolCall');
    final view = ToolView.of(_tool('codex.mcpToolCall', args: {'name': 'search'}));
    expectLanguage(AppLocale.zhCN, () {
      expect(approvalCardTitle(request, view), '允许使用「连接器 · search」？');
      expect(approvalCardTitle(request, null), '允许使用「连接器」？');
    });
    expectLanguage(AppLocale.en, () {
      expect(approvalCardTitle(request, view), 'Allow “Connector · search”?');
      expect(approvalCardTitle(request, null), 'Allow “Connector”?');
    });
  });

  test('ARB parts, merged ARBs and generated l10n stay in sync', () {
    const keys = [
      'activityCompactRunning',
      'activityCompactDone',
      'activityConnectorTool',
      'activityConnector',
      'activityEditFile',
      'activityReviewMode',
      'activityCommand',
      'botsGlyphListAgents',
    ];
    for (final area in ['activity', 'bots']) {
      for (final lang in ['zh', 'en']) {
        final part = _readArb('lib/l10n/parts/${area}_$lang.arb');
        final merged = _readArb('lib/l10n/app_$lang.arb');
        for (final entry in part.entries) {
          if (entry.key.startsWith('@')) continue;
          expect(merged[entry.key], entry.value, reason: '$area/$lang: ${entry.key}');
        }
      }
    }
    for (final lang in ['zh', 'en']) {
      final merged = _readArb('lib/l10n/app_$lang.arb');
      for (final key in keys) {
        expect(merged.containsKey(key), isTrue, reason: 'app_$lang.arb missing $key');
      }
    }
    final gen = File('lib/l10n/gen/app_localizations.dart').readAsStringSync();
    final genZh = File('lib/l10n/gen/app_localizations_zh.dart').readAsStringSync();
    final genEn = File('lib/l10n/gen/app_localizations_en.dart').readAsStringSync();
    // Plain keys are getters; keys with placeholders become methods.
    bool declares(String source, String key) =>
        source.contains('String get $key =>') ||
        source.contains('String get $key;') ||
        source.contains('String $key(');
    for (final key in keys) {
      expect(declares(gen, key), isTrue, reason: 'abstract gen missing $key');
      expect(declares(genZh, key), isTrue, reason: 'zh gen missing $key');
      expect(declares(genEn, key), isTrue, reason: 'en gen missing $key');
    }
    expect(_readArb('lib/l10n/app_zh.arb')['activityThinking'], '思考');
    expect(_readArb('lib/l10n/app_en.arb')['activityThinking'], 'Thinking');
    expect(_readArb('lib/l10n/app_zh.arb')['botsGlyphListModels'], '列出子代理模型');
    expect(_readArb('lib/l10n/app_en.arb')['botsGlyphListModels'], 'List subagent models');
  });
}
