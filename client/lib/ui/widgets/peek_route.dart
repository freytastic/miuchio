import 'package:flutter/widgets.dart';

class PeekRoute<T> extends PopupRoute<T> {
  final RoutePageBuilder builder;

  @override
  final Duration transitionDuration;

  @override
  final Duration reverseTransitionDuration;

  PeekRoute({
    required this.builder,
    required this.transitionDuration,
    required this.reverseTransitionDuration,
  });

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => false;

  @override
  String? get barrierLabel => null;

  @override
  bool get allowSnapshotting => false;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      builder(context, animation, secondaryAnimation);
}
