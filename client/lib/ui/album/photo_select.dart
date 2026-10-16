import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

class PhotoSelection extends ChangeNotifier {
  bool _active = false;
  Set<String> _ids = const {};

  bool get active => _active;
  Set<String> get ids => _ids;
  bool contains(String id) => _ids.contains(id);

  void start() {
    if (_active) return;
    _active = true;
    notifyListeners();
  }

  void end() {
    if (!_active && _ids.isEmpty) return;
    _active = false;
    _ids = const {};
    notifyListeners();
  }

  void toggle(String id) {
    final next = {..._ids};
    if (!next.remove(id)) next.add(id);
    replace(next);
  }

  void replace(Set<String> ids) {
    _ids = ids;
    _active = true;
    notifyListeners();
  }
}

// Marks a selectable tile so a drag can find it with one hit test
class PhotoMark {
  final String id;
  const PhotoMark(this.id);
}

// A sideways slide that starts on a photo selects the run under the thumb,
// in or out of select mode; up and down stay with the scroll view. The run
// selects or clears depending on the photo it started on
class PhotoDragSelect extends StatefulWidget {
  final PhotoSelection selection;
  final ScrollController scroll;
  final List<String> Function() order;
  final double bottomEdge;
  final Widget child;

  const PhotoDragSelect({
    super.key,
    required this.selection,
    required this.scroll,
    required this.order,
    required this.bottomEdge,
    required this.child,
  });

  @override
  State<PhotoDragSelect> createState() => _PhotoDragSelectState();
}

class _PhotoDragSelectState extends State<PhotoDragSelect>
    with SingleTickerProviderStateMixin {
  // Leaves the iOS back swipe its edge
  static const _backEdge = 24.0;
  static const _topEdge = 72.0;
  static const _maxSpeed = 1400.0;

  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;

  List<String> _order = const [];
  Set<String> _base = const {};
  bool _adding = true;
  int _anchor = -1;
  int _reach = -1;
  Offset? _pointer;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_autoScroll);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  String? _idAt(Offset global) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    final result = BoxHitTestResult();
    box.hitTest(result, position: box.globalToLocal(global));
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is PhotoMark) {
        return (target.metaData as PhotoMark).id;
      }
    }
    return null;
  }

  bool _allowStart(Offset global) =>
      global.dx > _backEdge && _idAt(global) != null;

  void _onStart(DragStartDetails d) {
    final id = _idAt(d.globalPosition);
    _order = widget.order();
    _anchor = id == null ? -1 : _order.indexOf(id);
    if (_anchor < 0) return;
    final selection = widget.selection;
    _base = selection.active ? selection.ids : const {};
    _adding = !_base.contains(id);
    _reach = -1;
    _pointer = d.globalPosition;
    _apply(_anchor);
    _lastTick = Duration.zero;
    _ticker.start();
  }

  void _onUpdate(DragUpdateDetails d) {
    if (_anchor < 0) return;
    _pointer = d.globalPosition;
    _track();
  }

  void _onEnd() {
    _anchor = -1;
    _pointer = null;
    if (_ticker.isActive) _ticker.stop();
  }

  void _track() {
    final pointer = _pointer;
    if (pointer == null) return;
    final id = _idAt(pointer);
    if (id == null) return;
    final i = _order.indexOf(id);
    if (i >= 0) _apply(i);
  }

  void _apply(int reach) {
    if (reach == _reach) return;
    _reach = reach;
    final from = reach < _anchor ? reach : _anchor;
    final to = reach < _anchor ? _anchor : reach;
    final run = _order.sublist(from, to + 1);
    final next = {..._base};
    if (_adding) {
      next.addAll(run);
    } else {
      next.removeAll(run);
    }
    HapticFeedback.selectionClick();
    widget.selection.replace(next);
  }

  // Scrolls while the thumb rests near the top or the foot bar
  void _autoScroll(Duration now) {
    final dt = (now - _lastTick).inMicroseconds / 1e6;
    _lastTick = now;
    final pointer = _pointer;
    final box = context.findRenderObject();
    final scroll = widget.scroll;
    if (pointer == null || box is! RenderBox || !scroll.hasClients) return;
    final y = box.globalToLocal(pointer).dy;
    final top = MediaQuery.paddingOf(context).top + _topEdge;
    final bottom = box.size.height - widget.bottomEdge;
    double pull = 0;
    if (y < top) {
      pull = -((top - y) / _topEdge).clamp(0.0, 1.0);
    } else if (y > bottom) {
      pull = ((y - bottom) / widget.bottomEdge).clamp(0.0, 1.0);
    }
    if (pull == 0 || dt <= 0 || dt > 0.1) return;
    final position = scroll.position;
    final target = (position.pixels + pull * _maxSpeed * dt)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return;
    position.jumpTo(target);
    _track();
  }

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        _SideSlide: GestureRecognizerFactoryWithHandlers<_SideSlide>(
          () => _SideSlide(_allowStart),
          (r) => r
            ..dragStartBehavior = DragStartBehavior.down
            ..onStart = _onStart
            ..onUpdate = _onUpdate
            ..onEnd = ((_) => _onEnd())
            ..onCancel = _onEnd,
        ),
      },
      child: widget.child,
    );
  }
}

class _SideSlide extends HorizontalDragGestureRecognizer {
  final bool Function(Offset global) allowStart;

  _SideSlide(this.allowStart);

  @override
  bool isPointerAllowed(PointerEvent event) =>
      allowStart(event.position) && super.isPointerAllowed(event);
}

class SelectMark extends StatelessWidget {
  final bool on;

  const SelectMark({super.key, required this.on});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: Warm.quick,
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: on ? Warm.cta : const Color(0x33000000),
        border: Border.all(color: const Color(0xF2FFFFFF), width: 1.5),
      ),
      child: on
          ? const Icon(Icons.check_rounded, size: 15, color: Warm.ctaInk)
          : null,
    );
  }
}
