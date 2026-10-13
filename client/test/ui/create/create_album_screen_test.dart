
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/ui/create/create_album_screen.dart';
import 'package:miuchio/ui/create/create_copy.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: CreateAlbumScreen()));
    await tester.pumpAndSettle();
  }

  Future<void> nameIt(WidgetTester tester, String name) async {
    await tester.enterText(
        find.widgetWithText(TextField, CreateCopy.namePlaceholder), name);
    await tester.pump();
  }

  Future<void> addId(WidgetTester tester, String id) async {
    await tester.tap(find.text(CreateCopy.addPerson));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, CreateCopy.idPlaceholder), id);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  WarmButton cta(WidgetTester tester) =>
      tester.widget<WarmButton>(find.byType(WarmButton));

  testWidgets('the album cannot be created without a name', (tester) async {
    await pump(tester);

    expect(cta(tester).onTap, isNull);

    await nameIt(tester, 'Lisbon');

    expect(cta(tester).onTap, isNotNull);
  });

  testWidgets('whitespace alone is not a name', (tester) async {
    await pump(tester);
    await nameIt(tester, '   ');

    expect(cta(tester).onTap, isNull);
  });

  testWidgets('the call to action absorbs what the skip button used to say',
      (tester) async {
    await pump(tester);
    await nameIt(tester, 'Lisbon');

    expect(find.text(CreateCopy.createOnly), findsOneWidget);

    await addId(tester, 'ABCD2345');

    expect(find.text(CreateCopy.createAndInvite(1)), findsOneWidget);

    await addId(tester, 'WXYZ6789');

    expect(find.text(CreateCopy.createAndInvite(2)), findsOneWidget);
  });

}
