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
            AlbumFoot(onAdd: () {}, pill: const Text('pill')),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the add button sits bottom right, as on Home', (tester) async {
    await pump(tester);

    final add = tester.getRect(find.byType(MakeButton));
    final screen = tester.getRect(find.byType(Scaffold));
    expect(screen.right - add.right, 18);
    expect(find.text(AlbumCopy.select), findsNothing);
    expect(find.text('Download'), findsNothing);
  });

  testWidgets('the upload pill sits clear of the add button', (tester) async {
    await pump(tester);

    expect(tester.getRect(find.text('pill')).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(MakeButton)).top));
  });
}
