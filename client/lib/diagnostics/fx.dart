abstract class Fx {
  static const String value = String.fromEnvironment('MIUCHIO_FX');

  static final Set<String> _on = value.split(',').map((s) => s.trim()).toSet();

  static final bool noShadow = _on.contains('noshadow');
  static final bool noTilt = _on.contains('notilt');
  static final bool noBacks = _on.contains('nobacks');
  static final bool noBlur = _on.contains('noblur');
}
