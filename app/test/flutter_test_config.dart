import 'package:flutter_test/flutter_test.dart';

import 'support/test_fonts.dart';

/// Runs before every test file in this package: the fonts the UI expects
/// (DshIcons, Material Icons, JetBrains Mono, Noto Sans CJK) must be loaded or
/// the test engine draws boxes for CJK and icon glyphs.
Future<void> testExecutable(Future<void> Function() tests) async {
  await loadTestFonts();
  await tests();
}
