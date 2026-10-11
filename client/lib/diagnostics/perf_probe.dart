import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'fx.dart';
import 'trace.dart';

class _Mark {
  final int at;
  final String name;
  bool shown = false;

  _Mark(this.at, this.name);
}

abstract class PerfProbe {
  static bool _started = false;
  static bool _clocked = false;
  static final List<_Mark> _marks = [];
  static final Expando<String> _names = Expando();
  static final Map<String, int> _builds = {};
  static final RegExp _screenType =
      RegExp(r'(Screen|Page|Peek|Shell|Sheet|Dialog)$');
  static const Set<String> _wrappers = {
    'ModalBottomSheet',
    'BottomSheet',
    'Dialog',
    'DisplayFeatureSubScreen',
  };

  static final NavigatorObserver observer = _ScreenObserver();

  static void count(String key) {
    if (!_started) return;
    _builds[key] = (_builds[key] ?? 0) + 1;
  }

  static void _enter(Route<dynamic> route) {
    if (!_started) return;
    final at = Timeline.now;
    final known = _names[route];
    if (known != null) {
      _mark(at, known);
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final name = _nameOf(route);
      _names[route] = name;
      _mark(at, name);
    });
  }

  static void _mark(int at, String name) {
    final i = _marks.lastIndexWhere((m) => m.at <= at) + 1;
    _marks.insert(i, _Mark(at, name));
    if (_marks.length > 64) _marks.removeAt(0);
    Trace.event('screen', fields: {'name': name});
  }

  static String _nameOf(Route<dynamic> route) {
    final root = route is ModalRoute ? route.subtreeContext : null;
    String? found;
    var budget = 800;
    void visit(Element e) {
      if (found != null || budget-- <= 0) return;
      final type = e.widget.runtimeType
          .toString()
          .split('<')
          .first
          .replaceFirst(RegExp(r'^_+'), '');
      if (_screenType.hasMatch(type) && !_wrappers.contains(type)) {
        found = type;
        return;
      }
      e.visitChildElements(visit);
    }

    if (root is Element) visit(root);
    return found ??
        route.settings.name ??
        route.runtimeType.toString().split('<').first;
  }

  static String _screenAt(int us) {
    var name = 'startup';
    for (final m in _marks) {
      if (m.at > us) break;
      name = m.name;
    }
    return name;
  }

  static void start() {
    if (_started || !Trace.enabled) return;
    _started = true;
    Trace.event('app.main');
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    unawaited(WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      Trace.event('app.firstFrame');
      _device();
      unawaited(_probeKeystore());
    }));
  }

  static void _device() {
    final display = PlatformDispatcher.instance.displays.firstOrNull;
    final view = PlatformDispatcher.instance.views.firstOrNull;
    Trace.event('device', fields: {
      'cores': Platform.numberOfProcessors,
      'hz': display?.refreshRate.toStringAsFixed(0),
      'dpr': view?.devicePixelRatio.toStringAsFixed(2),
      'px': view == null
          ? null
          : '${view.physicalSize.width.round()}x${view.physicalSize.height.round()}',
      'fx': Fx.value.isEmpty ? 'none' : Fx.value,
    });
  }

  // Retry while the wrapper key is unavailable
  static Future<void> _probeKeystore() async {
    if (!Platform.isAndroid) return;
    const channel = MethodChannel('miuchio/keystore');
    for (var i = 0; i < 60; i++) {
      try {
        final r = await channel.invokeMethod<Map>('probe');
        if (r != null && r['initialized'] == true) {
          final loads = (r['loadMs'] as List).cast<num>();
          Trace.event('keystore.probe', fields: {
            'level': r['level'],
            'bytes': r['envelopeBytes'],
            'entries': r['entries'],
            'load_ms': loads.map((v) => v.toStringAsFixed(1)).join(','),
          });
          return;
        }
      } catch (e) {
        Trace.event('keystore.probe', fields: {'error': Trace.reasonOf(e)});
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 10));
    }
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (timings.isEmpty) return;
    final hz =
        PlatformDispatcher.instance.displays.firstOrNull?.refreshRate ?? 60;
    final budgetUs = 1e6 / (hz <= 0 ? 60 : hz);
    if (!_clocked) {
      _clocked = true;
      final last =
          timings.last.timestampInMicroseconds(FramePhase.rasterFinish);
      Trace.event('frames.clock', fields: {'skew': _ms(Timeline.now - last)});
    }
    for (final m in _marks) {
      if (m.shown) continue;
      final first = timings
          .where(
              (t) => t.timestampInMicroseconds(FramePhase.vsyncStart) >= m.at)
          .firstOrNull;
      if (first == null) continue;
      m.shown = true;
      Trace.event('screen.first', fields: {
        'name': m.name,
        'wait':
            _ms(first.timestampInMicroseconds(FramePhase.rasterFinish) - m.at),
        'build': _ms(first.buildDuration.inMicroseconds),
        'raster': _ms(first.rasterDuration.inMicroseconds),
      });
    }
    final byScreen = <String, List<FrameTiming>>{};
    for (final t in timings) {
      final at = t.timestampInMicroseconds(FramePhase.vsyncStart);
      byScreen.putIfAbsent(_screenAt(at), () => []).add(t);
    }
    byScreen.forEach((screen, group) => _report(screen, group, budgetUs));
    if (_builds.isNotEmpty) {
      Trace.event('builds', fields: {
        'screen': _marks.isEmpty ? 'startup' : _marks.last.name,
        ..._builds,
      });
      _builds.clear();
    }
  }

  static void _report(
      String screen, List<FrameTiming> timings, double budgetUs) {
    final build = [for (final t in timings) t.buildDuration.inMicroseconds]
      ..sort();
    final raster = [for (final t in timings) t.rasterDuration.inMicroseconds]
      ..sort();
    final total = [for (final t in timings) t.totalSpan.inMicroseconds]..sort();
    Trace.event('frames', fields: {
      'screen': screen,
      'n': timings.length,
      'late': total.where((us) => us > budgetUs).length,
      'budget': _ms(budgetUs.round()),
      'build50': _ms(_pct(build, .5)),
      'build90': _ms(_pct(build, .9)),
      'buildMax': _ms(build.last),
      'raster50': _ms(_pct(raster, .5)),
      'raster90': _ms(_pct(raster, .9)),
      'rasterMax': _ms(raster.last),
      'total90': _ms(_pct(total, .9)),
    });
  }

  static int _pct(List<int> sorted, double p) =>
      sorted[((sorted.length - 1) * p).round()];

  static String _ms(int us) => (us / 1000).toStringAsFixed(1);
}

class _ScreenObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      PerfProbe._enter(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) PerfProbe._enter(previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null && previousRoute.isCurrent) {
      PerfProbe._enter(previousRoute);
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute != null) PerfProbe._enter(newRoute);
  }
}
