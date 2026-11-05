// WorkBuddy 积分/余额：读你自己面板上的一个只读接口，点宠物时显示。
//
// 地址与令牌存在 Keychain（flutter_secure_storage）：卸载重装之后还在，
// 开关这类非敏感项留在 SharedPreferences。
//
// 面板接口是 `GET {base}/api/accounts/credits-snapshot`，只回面板已经登记下来的
// 余额（不触发上游查询），用只读 API Token（`wbt_…`）调用即可，所以这个凭据
// 泄露也只能读积分。令牌和地址都存在本机 SharedPreferences 里，不进日志、
// 不进对话。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class CreditsConfig {
  const CreditsConfig({this.enabled = false, this.baseUrl = '', this.token = ''});

  final bool enabled;
  final String baseUrl;
  final String token;

  bool get configured => enabled && baseUrl.trim().isNotEmpty && token.trim().isNotEmpty;

  CreditsConfig copyWith({bool? enabled, String? baseUrl, String? token}) =>
      CreditsConfig(enabled: enabled ?? this.enabled, baseUrl: baseUrl ?? this.baseUrl, token: token ?? this.token);
}

/// One account's registered balance.
@immutable
class CreditsRow {
  const CreditsRow({required this.uid, required this.credits, required this.known});

  final String uid;
  final int credits;

  /// The account still exists on the panel (removed ones keep a history row).
  final bool known;

  /// Last four characters of the uid, enough to tell rows apart.
  String get label => uid.length <= 4 ? uid : uid.substring(uid.length - 4);
}

@immutable
class CreditsSnapshot {
  const CreditsSnapshot({required this.total, required this.knownCount, required this.rows, required this.at});

  /// Sum over the accounts the panel still knows.
  final int total;
  final int knownCount;
  final List<CreditsRow> rows;

  /// When the panel registered these numbers.
  final DateTime at;
}

class CreditsConfigController extends Notifier<CreditsConfig> {
  static const _kEnabled = 'credits.enabled';
  // Keychain: survives a reinstall, which the app container does not.
  static const _kBase = 'credits.baseUrl';
  static const _kToken = 'credits.token';
  static const _vault = FlutterSecureStorage();

  @override
  CreditsConfig build() {
    unawaited(_load());
    return const CreditsConfig();
  }

  Future<void> _load() async {
    final store = await SharedPreferences.getInstance();
    String base = '';
    String token = '';
    try {
      base = await _vault.read(key: _kBase) ?? '';
      token = await _vault.read(key: _kToken) ?? '';
    } on Object {
      // No Keychain (tests, other platforms): fall back to the old place so an
      // install that already had them keeps working.
      base = store.getString(_kBase) ?? '';
      token = store.getString(_kToken) ?? '';
    }
    final enabled = store.getBool(_kEnabled) ?? (base.isNotEmpty && token.isNotEmpty);
    final next = CreditsConfig(enabled: enabled, baseUrl: base, token: token);
    if (next != state) state = next;
  }

  Future<void> setEnabled(bool on) => _save(state.copyWith(enabled: on));

  Future<void> setSource({String? baseUrl, String? token}) =>
      _save(state.copyWith(baseUrl: baseUrl?.trim(), token: token?.trim()));

  Future<void> _save(CreditsConfig next) async {
    state = next;
    final store = await SharedPreferences.getInstance();
    await store.setBool(_kEnabled, next.enabled);
    try {
      await _vault.write(key: _kBase, value: next.baseUrl);
      await _vault.write(key: _kToken, value: next.token);
    } on Object {
      await store.setString(_kBase, next.baseUrl);
      await store.setString(_kToken, next.token);
    }
  }
}

final creditsConfigProvider = NotifierProvider<CreditsConfigController, CreditsConfig>(CreditsConfigController.new);

/// One client for the app's lifetime: a fresh `http.get` per tap pays a new
/// TCP/TLS handshake every time, which is most of what "刷新很慢" felt like.
final _client = http.Client();

/// Reads the panel's snapshot. Throws a short message the sheet can show.
///
/// [onSent] fires when the request actually goes out, so the card can show how
/// long the panel took instead of an open-ended spinner.
Future<CreditsSnapshot> fetchCredits(CreditsConfig config, {void Function()? onSent}) async {
  final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.parse('$base/api/accounts/credits-snapshot');
  onSent?.call();
  // One retry: the panel is behind a home connection, and a dropped keep-alive
  // socket fails instantly while the second attempt succeeds.
  late http.Response response;
  for (var attempt = 0; ; attempt++) {
    try {
      response = await _client
          .get(uri, headers: {'Authorization': 'Bearer ${config.token.trim()}'})
          .timeout(const Duration(seconds: 8));
      break;
    } on Object catch (error) {
      if (attempt >= 1) {
        throw CreditsError(error is CreditsError ? error.message : '网络不通（${error.runtimeType}）');
      }
    }
  }
  if (response.statusCode != 200) {
    // A 404 is almost always the wrong address: the panel lives on its own port,
    // and port 80 answers a different app with a 404 for /api/...
    throw CreditsError(
      response.statusCode == 404
          ? 'HTTP 404（地址不对？要带端口，例如 http://IP:7864）'
          : 'HTTP ${response.statusCode}',
    );
  }
  final Object? decoded = jsonDecode(utf8.decode(response.bodyBytes));
  if (decoded is! Map<String, Object?>) throw const CreditsError('格式不对');
  final raw = decoded['accounts'];
  final rows = <CreditsRow>[
    if (raw is List)
      for (final item in raw)
        if (item is Map)
          if (_row(item) case final row?) row,
  ];
  final known = rows.where((r) => r.known).toList();
  final at = decoded['snapshot_at'];
  return CreditsSnapshot(
    total: known.fold(0, (sum, r) => sum + r.credits),
    knownCount: decoded['known_count'] is int ? decoded['known_count']! as int : known.length,
    rows: known..sort((a, b) => b.credits.compareTo(a.credits)),
    at: DateTime.fromMillisecondsSinceEpoch(at is int ? at * 1000 : DateTime.now().millisecondsSinceEpoch),
  );
}

CreditsRow? _row(Map<Object?, Object?> item) {
  final uid = item['uid'];
  final credits = item['credits'];
  if (uid is! String || credits is! num) return null;
  return CreditsRow(uid: uid, credits: credits.round(), known: item['known'] != false);
}

class CreditsError implements Exception {
  const CreditsError(this.message);
  final String message;
  @override
  String toString() => message;
}
