// 今日 token 用量：按本地日累加每个会话的输入/输出 token。
//
// 数据来源是主机推来的 `UsageChunk`（每个回合结束一次），我们只做累加和展示:
// 不做估算、不回溯历史——从装上这版那天开始计。
//
// 存在 SharedPreferences 里，按日期分键，跨天自动从零开始；旧的键不删，
// 留给以后做「近 7 天」。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class TokenUsage {
  const TokenUsage({
    required this.input,
    required this.output,
    required this.bySession,
    this.lastAt,
  });

  static const empty = TokenUsage(input: 0, output: 0, bySession: {});

  /// 最近一次收到 usage 的时间；null = 这一版还没收到过。
  final DateTime? lastAt;

  final int input;
  final int output;

  /// token 总数，按会话。
  final Map<String, int> bySession;

  int get total => input + output;

  bool get isEmpty => total == 0;
}

class TokenUsageController extends Notifier<TokenUsage> {
  static String _key(DateTime day) =>
      'tokens.${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  String? _loadedKey;

  @override
  TokenUsage build() {
    unawaited(_load());
    return TokenUsage.empty;
  }

  Future<void> _load() async {
    final day = DateTime.now();
    final key = _key(day);
    final store = await SharedPreferences.getInstance();
    final raw = store.getString(key);
    _loadedKey = key;
    if (raw == null) {
      if (state != TokenUsage.empty) state = TokenUsage.empty;
      return;
    }
    try {
      final map = jsonDecode(raw) as Map<String, Object?>;
      final sessions = <String, int>{};
      final by = map['sessions'];
      if (by is Map) {
        for (final entry in by.entries) {
          final value = entry.value;
          if (lastKey(entry.key) case final id?) {
            if (value is num) sessions[id] = value.round();
          }
        }
      }
      final last = (map['lastAt'] as num?)?.toInt();
      state = TokenUsage(
        input: (map['input'] as num?)?.toInt() ?? 0,
        output: (map['output'] as num?)?.toInt() ?? 0,
        bySession: sessions,
        lastAt: last == null ? null : DateTime.fromMillisecondsSinceEpoch(last),
      );
    } on Object {
      state = TokenUsage.empty;
    }
  }

  static String? lastKey(Object? key) => key is String && key.isNotEmpty ? key : null;

  /// 一个回合结束时调用。[input]/[output] 来自主机的 usage。
  Future<void> record(String sessionId, int input, int output) async {
    if (input <= 0 && output <= 0) return;
    final now = DateTime.now();
    // 跨天:先落盘旧的一天，再从零开始。
    if (_key(now) != _loadedKey) {
      await _load();
    }
    final sessions = Map<String, int>.of(state.bySession);
    sessions[sessionId] = (sessions[sessionId] ?? 0) + input + output;
    state = TokenUsage(input: state.input + input, output: state.output + output, bySession: sessions);
    await _save(now);
  }

  Future<void> _save(DateTime day) async {
    final store = await SharedPreferences.getInstance();
    await store.setString(
      _key(day),
      jsonEncode({
        'input': state.input,
        'output': state.output,
        'sessions': state.bySession,
        'lastAt': state.lastAt?.millisecondsSinceEpoch,
      }),
    );
  }
}

final tokenUsageProvider = NotifierProvider<TokenUsageController, TokenUsage>(TokenUsageController.new);

/// 12345 → 12.3k，给概览卡那种一行位置用。
String formatTokens(int tokens) {
  if (tokens < 1000) return '$tokens';
  if (tokens < 1000000) return '${(tokens / 1000).toStringAsFixed(1)}k';
  return '${(tokens / 1000000).toStringAsFixed(2)}M';
}
