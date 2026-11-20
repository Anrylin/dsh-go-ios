// A picked image must leave the caret in the composer; a cancelled picker
// must not raise the keyboard.

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadTestFonts);

  Future<void> mountChat(WidgetTester tester, FakePicker picker) async {
    usePhoneView(tester);
    final harness = ChatHarness(session: 's', picker: picker);
    await tester.pumpWidget(
      testApp(
        const ChatScreen(),
        overrides: harness.overrides,
      ),
    );
    await tester.pumpAndSettle(const Duration(seconds: 1));
  }

  Future<void> openGallery(WidgetTester tester) async {
    await tester.tap(find.byType(AttachButton));
    await pumpFrames(tester);
    await tester.tap(find.text('相册'));
    await pumpFrames(tester);
  }

  testWidgets('picking an image returns focus to the composer input', (tester) async {
    final picker = FakePicker()..images = [DraftAttachment.sniff('cat.png', tinyPng)];
    await mountChat(tester, picker);

    expect(find.byType(AttachButton), findsOneWidget);
    expect(picker.calls, isEmpty);
    await openGallery(tester);

    expect(picker.calls, contains('images:9'));

    final input = find.byType(EditableText);
    expect(input, findsOneWidget);
    final editable = tester.widget<EditableText>(input);
    expect(
      FocusManager.instance.primaryFocus,
      same(editable.focusNode),
      reason: 'the caret must be back in the input so typing lands immediately',
    );
    await tester.enterText(input, '配图');
    expect(editable.controller.text, '配图');
  });

  testWidgets('a cancelled picker does not steal focus', (tester) async {
    final picker = FakePicker(); // images empty: the system picker was dismissed.
    await mountChat(tester, picker);

    FocusManager.instance.primaryFocus?.unfocus();
    await pumpFrames(tester);

    await openGallery(tester);

    expect(picker.calls, contains('images:9'));
    final input = find.byType(EditableText);
    if (input.evaluate().isNotEmpty) {
      final editable = tester.widget<EditableText>(input.first);
      expect(FocusManager.instance.primaryFocus, isNot(same(editable.focusNode)));
    }
    expect(find.text('配图'), findsNothing);
  });
}
