import 'package:cryptography/cryptography.dart' as cg;
import 'package:cryptography_flutter/cryptography_flutter.dart';

// Mirrors the plugin's routing so traces name the path a payload takes
String aesPath(int length) {
  final algo = cg.AesGcm.with256bits();
  if (algo is! FlutterAesGcm) return algo.runtimeType.toString();
  return algo.isSupportedPlatform && algo.channelPolicy.matches(length: length)
      ? 'plugin'
      : 'fallback';
}
