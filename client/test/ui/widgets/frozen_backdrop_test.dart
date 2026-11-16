import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/ui/widgets/frozen_backdrop.dart';
import 'package:miuchio/ui/widgets/peek_route.dart';

// Fails on the second capture
class _FailingBoundary extends RenderRepaintBoundary {
  ui.Image? first;

  @override
  ui.Image toImageSync({double pixelRatio = 1.0}) {
    if (first != null) throw StateError('second capture failed');
    return first = super.toImageSync(pixelRatio: pixelRatio);
  }
}

class _Boundary extends SingleChildRenderObjectWidget {
  const _Boundary({super.key, super.child});

  @override
  _FailingBoundary createRenderObject(BuildContext context) =>
      _FailingBoundary();
}

class _BehindRoute extends PageRouteBuilder<void> {
  final GlobalKey boundary;

  _BehindRoute(this.boundary)
      : super(
            pageBuilder: (_, __, ___) => _Boundary(
                key: boundary, child: const ColoredBox(color: Colors.green)));

  @override
  BuildContext? get subtreeContext => boundary.currentContext;
}

void main() {
  testWidgets('a failed capture frees the first snapshot and stays live',
      (tester) async {
    final nav = GlobalKey<NavigatorState>();
    final boundary = GlobalKey();
    await tester
        .pumpWidget(MaterialApp(navigatorKey: nav, home: const SizedBox()));
    nav.currentState!.push(_BehindRoute(boundary));
    await tester.pumpAndSettle();
    nav.currentState!.push(PeekRoute<void>(
      transitionDuration: const Duration(milliseconds: 200),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      builder: (_, a, __) => FrozenBackdrop(
          sigma: 18,
          saturation: .9,
          color: const Color(0x55000000),
          opacity: a),
    ));
    await tester.pumpAndSettle();

    final first =
        (boundary.currentContext!.findRenderObject()! as _FailingBoundary)
            .first;
    expect(first, isNotNull);
    expect(first!.debugDisposed, isTrue);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(_Boundary), findsOneWidget,
        reason: 'the route behind must keep painting without a snapshot');
  });
}
