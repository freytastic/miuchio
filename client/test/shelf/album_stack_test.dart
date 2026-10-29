import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:miuchio/ui/shelf/album_stack.dart';

void main() {
  Future<void> pump(WidgetTester tester,
      {int unseen = 0, int photos = 7, bool small = false}) async {
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 300,
          child: AlbumStack(
            albumId: 'a',
            title: 'Lake weekend',
            mediaCount: photos,
            unseen: unseen,
            lastActivity: null,
            members: const [],
            totalMembers: 0,
            nameOf: (_) => null,
            develop: const AlwaysStoppedAnimation(1),
            small: small,
          ),
        ),
      ),
    ));
  }

  testWidgets('the name and photo count sit under the pile', (tester) async {
    await pump(tester);
    expect(find.text('Lake weekend'), findsOneWidget);
    expect(find.text('7 photos'), findsOneWidget);
    expect(find.text('new'), findsNothing);
  });

  testWidgets('new photos put a sticker on the pile', (tester) async {
    await pump(tester, unseen: 3);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('new'), findsOneWidget);
  });

  testWidgets('an empty album says so', (tester) async {
    await pump(tester, photos: 0);
    expect(find.text('No photos yet'), findsOneWidget);
  });

  testWidgets('its height is what the shelf plans for', (tester) async {
    for (final small in [false, true]) {
      await pump(tester, small: small);
      expect(tester.getSize(find.byType(AlbumStack)).height,
          closeTo(AlbumStack.heightFor(300, small: small), 0.5));
    }
  });
}
