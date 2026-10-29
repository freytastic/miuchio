import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

// What holds each album's top print to the page
enum AlbumStyle { tape, plain }

extension AlbumStyleCopy on AlbumStyle {
  String get label => switch (this) {
        AlbumStyle.tape => 'Tape',
        AlbumStyle.plain => 'Plain',
      };

  String get detail => switch (this) {
        AlbumStyle.tape => 'A strip of washi tape',
        AlbumStyle.plain => 'Just the prints',
      };
}

// Loaded before the first frame; contains no album or person identifiers
class AlbumStylePreference extends ChangeNotifier {
  static const String _key = 'miuchio.album_style';

  final SharedPreferences _prefs;
  AlbumStyle _style;

  AlbumStylePreference._(this._prefs, this._style);

  static Future<AlbumStylePreference> load(SharedPreferences prefs) async {
    // Stored by name, so reordering the enum can never change someone's look,
    // and a style that no longer exists falls back to tape
    final stored = prefs.getString(_key);
    final style =
        AlbumStyle.values.where((s) => s.name == stored).firstOrNull ??
            AlbumStyle.tape;
    return AlbumStylePreference._(prefs, style);
  }

  AlbumStyle get style => _style;

  Future<void> set(AlbumStyle next) async {
    if (next == _style) return;
    _style = next;
    notifyListeners();
    try {
      await _prefs.setString(_key, next.name);
    } catch (_) {
      // The look still changes for this session
    }
  }
}
