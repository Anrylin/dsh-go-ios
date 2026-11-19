import 'dart:io';

// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_fonts.dart';

/// Runs before every test file in this package: the fonts the UI expects
/// (DshIcons, Material Icons, JetBrains Mono, Noto Sans CJK) must be loaded or
/// the test engine draws boxes for CJK and icon glyphs.
Future<void> testExecutable(Future<void> Function() tests) async {
  await loadTestFonts();
  // A plain `flutter test` process has no plugin registrant, so the real
  // path_provider method channel never answers and a durable store waiting on
  // the support directory would hang forever. Every lookup gets a private temp
  // directory, so one test's durable send cannot replay into the next.
  PathProviderPlatform.instance = _TestPathProvider();
  await tests();
}

/// Stand-in for the missing plugin registrant: durable stores only need a
/// writable directory. A fresh directory per lookup keeps tests isolated.
final class _TestPathProvider extends PathProviderPlatform {
  Directory _fresh() => Directory.systemTemp.createTempSync('dsh-test-support-');

  @override
  Future<String?> getApplicationSupportPath() async => _fresh().path;

  @override
  Future<String?> getTemporaryPath() async => _fresh().path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _fresh().path;

  @override
  Future<String?> getApplicationCachePath() async => _fresh().path;
}
