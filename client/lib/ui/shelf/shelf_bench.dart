import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:miuchio/diagnostics/perf_probe.dart';
import 'package:miuchio/diagnostics/trace.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

// Replays shelf motion on a fixed script so effect switches compare equal work
class ShelfBench {
  final ScrollController scroll;
  final VoidCallback replayEntry;
  final VoidCallback replayDevelop;
  final bool Function() idle;

  ShelfBench({
    required this.scroll,
    required this.replayEntry,
    required this.replayDevelop,
    required this.idle,
  });

  static const Duration _settle = Duration(seconds: 8);
  static const Duration _rest = Duration(milliseconds: 800);
  static const Duration _entry = Duration(milliseconds: 1200);
  static const Duration _pass = Duration(milliseconds: 1200);
  static const int _rounds = 3;

  Future<void> run() async {
    await Future<void>.delayed(_settle);
    for (var round = 1; round <= _rounds; round++) {
      if (!idle()) {
        Trace.event('bench.skipped', fields: {'round': round});
        return;
      }
      replayEntry();
      PerfProbe.window('bench.entry', _entry);
      await Future<void>.delayed(_entry + _rest);

      replayDevelop();
      PerfProbe.window('bench.develop', Warm.develop);
      await Future<void>.delayed(Warm.develop + _rest);

      if (!scroll.hasClients) continue;
      final extent = scroll.position.maxScrollExtent;
      PerfProbe.window('bench.scroll', _pass * 2,
          fields: {'extent': extent.round()});
      await scroll.animateTo(extent, duration: _pass, curve: Curves.easeInOut);
      await scroll.animateTo(0, duration: _pass, curve: Curves.easeInOut);
      await Future<void>.delayed(_rest);
    }
    Trace.event('bench.done');
  }
}
