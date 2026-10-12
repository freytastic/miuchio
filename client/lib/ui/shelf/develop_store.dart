import 'package:flutter/widgets.dart';
import 'package:miuchio/diagnostics/perf_probe.dart';

// Keeps develop controllers stable across layout remounts
class DevelopStore {
  final TickerProvider vsync;
  final Duration duration;
  final bool Function() visible;
  final Map<String, AnimationController> _by = {};
  final Map<String, int> _unseen = {};
  final Set<String> _waiting = {};

  DevelopStore({
    required this.vsync,
    required this.duration,
    bool Function()? visible,
  }) : visible = visible ?? _always;

  static bool _always() => true;

  Animation<double> sync(String albumId, int unseen) {
    final held = _by[albumId];
    if (held == null) {
      _unseen[albumId] = unseen;
      return _by[albumId] = AnimationController(
        vsync: vsync,
        duration: duration,
        value: unseen > 0 ? 0 : 1,
      );
    }
    final was = _unseen[albumId];
    _unseen[albumId] = unseen;
    if (was == null || was == unseen) return held;
    // Newly unseen prints reset instead of reversing
    if (unseen == 0) {
      _waiting.add(albumId);
      if (visible()) play();
    } else {
      _waiting.remove(albumId);
      if (was == 0) held.value = 0;
    }
    return held;
  }

  // Albums are marked seen as they open, so the shelf develops once shown again
  void play() {
    if (_waiting.isEmpty) return;
    for (final id in _waiting) {
      _by[id]?.forward();
    }
    _waiting.clear();
    PerfProbe.window('shelf.develop', duration);
  }

  Animation<double>? read(String albumId) => _by[albumId];

  // Benchmark only, waiting prints stay undeveloped
  void replay() {
    for (final c in _by.values) {
      if (c.value < 1) continue;
      c.value = 0;
      c.forward();
    }
  }

  void retain(Set<String> albumIds) {
    for (final id in _by.keys.toList()) {
      if (albumIds.contains(id)) continue;
      _by.remove(id)?.dispose();
      _unseen.remove(id);
      _waiting.remove(id);
    }
  }

  void dispose() {
    for (final c in _by.values) {
      c.dispose();
    }
    _by.clear();
    _unseen.clear();
    _waiting.clear();
  }
}
