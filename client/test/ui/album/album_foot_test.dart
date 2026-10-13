import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/album_foot.dart';
import 'package:miuchio/ui/widgets/foot_bar.dart';

void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            const SizedBox.expand(child: ColoredBox(color: Colors.white)),
            AlbumFoot(
              onSelect: () {},
              onAdd: () {},
              onDownload: () {},
              pill: const Text('pill'),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the upload pill sits clear of the add button', (tester) async {
    await pump(tester);

    expect(find.text(AlbumCopy.select), findsOneWidget);
    expect(find.byType(MakeButton), findsOneWidget);
    expect(find.text(AlbumCopy.download), findsOneWidget);

    expect(tester.getRect(find.text('pill')).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(MakeButton)).top));
  });
}
