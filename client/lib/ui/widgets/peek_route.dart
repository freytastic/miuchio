import 'package:flutter/widgets.dart';

// Remembers the route underneath so a backdrop can reuse its last frame
mixin RouteBehind<T> on ModalRoute<T> {
  ModalRoute<dynamic>? behind;
  bool _hidesBehind = false;

  // Routes behind stop painting until this route starts leaving
  set hidesBehind(bool value) {
    if (_hidesBehind == value) return;
    _hidesBehind = value;
    _syncOpaque();
  }

  // Runs after TransitionRoute's own listener, which resets the entry
  void _syncOpaque() {
    final status = animation?.status;
    if (status == null || !status.isForwardOrCompleted) return;
    if (overlayEntries.isEmpty) return;
    overlayEntries.first.opaque =
        _hidesBehind || (status.isCompleted && opaque);
  }

  @override
  void install() {
    super.install();
    animation!.addStatusListener((_) => _syncOpaque());
  }

  @override
  void didChangePrevious(Route<dynamic>? previousRoute) {
    behind = previousRoute is ModalRoute ? previousRoute : null;
    super.didChangePrevious(previousRoute);
  }
}

class PeekRoute<T> extends PopupRoute<T> with RouteBehind<T> {
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

class GlassRoute<T> extends PageRouteBuilder<T> with RouteBehind<T> {
  GlassRoute({
    required super.pageBuilder,
    super.transitionsBuilder,
    super.transitionDuration,
    super.reverseTransitionDuration,
    super.barrierColor,
  }) : super(opaque: false);
}
