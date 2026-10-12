import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:miuchio/diagnostics/debug_log.dart';

// Model names only, never a serial, Android ID or advertising ID
class DeviceSummary {
  final String app;
  final String os;
  final String model;

  const DeviceSummary({
    required this.app,
    required this.os,
    required this.model,
  });

  static Future<DeviceSummary> load() async {
    var app = 'unknown';
    var os = Platform.operatingSystem;
    var model = 'unknown';
    try {
      final info = await PackageInfo.fromPlatform();
      app = '${info.version} (${info.buildNumber})';
    } catch (_) {}
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        os = 'Android ${a.version.release} (SDK ${a.version.sdkInt})';
        model = '${a.manufacturer} ${a.model}';
      } else if (Platform.isIOS) {
        final i = await plugin.iosInfo;
        os = 'iOS ${i.systemVersion}';
        model = i.utsname.machine;
      }
    } catch (_) {}
    return DeviceSummary(app: app, os: os, model: model);
  }
}

// Copy and Share both send exactly this text, which the preview shows first
String buildDebugLogExport(
  List<DebugEntry> entries,
  DeviceSummary device, {
  required DateTime now,
}) {
  final b = StringBuffer()
    ..writeln('Miuchio debug log')
    ..writeln('App ${device.app}')
    ..writeln('${device.os}, ${device.model}')
    ..writeln('Exported ${_stamp(now)} (UTC${_offset(now)})')
    ..writeln('${entries.length} entries, oldest first')
    ..writeln();
  for (final e in entries) {
    b.writeln(debugLine(e));
  }
  return b.toString();
}

String debugLine(DebugEntry e) {
  final b = StringBuffer()
    ..write(_stamp(e.first))
    ..write('  ')
    ..write(e.level.name.padRight(5))
    ..write('  ')
    ..write(e.event.code);
  void field(String k, Object? v) {
    if (v != null) b.write(' $k=$v');
  }

  field('reason', e.reason);
  field('stage', e.stage);
  field('route', e.route);
  field('attempt', e.attempt);
  field('ms', e.ms);
  field('op', e.op);
  field('version', e.version);
  if (e.count > 1) b.write(' x${e.count} until ${_clock(e.last)}');
  return b.toString();
}

String _two(int n) => n.toString().padLeft(2, '0');

String _clock(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String _stamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_clock(t)}';

String _offset(DateTime t) {
  final m = t.timeZoneOffset.inMinutes;
  final sign = m < 0 ? '-' : '+';
  return '$sign${_two(m.abs() ~/ 60)}:${_two(m.abs() % 60)}';
}
