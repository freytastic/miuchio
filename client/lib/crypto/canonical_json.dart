import 'dart:convert';
import 'dart:typed_data';

// Signed bytes, mirrored by server/internal/crypto/canonical_json.go. Any
// divergence breaks every signature

//   keys sorted by raw UTF-8 bytes, no whitespace, floats rejected
//   strings escape only " \ and control chars, everything else stays raw UTF-8

// No Unicode normalization happens here so both sides stay byte identical
// without depending on Unicode tables. Callers normalize first
abstract class CanonicalJson {
  static Uint8List encode(Object? v) {
    final sb = StringBuffer();
    _writeValue(sb, v);
    return Uint8List.fromList(utf8.encode(sb.toString()));
  }

  static String encodeString(Object? v) {
    final sb = StringBuffer();
    _writeValue(sb, v);
    return sb.toString();
  }

  static void _writeValue(StringBuffer sb, Object? v) {
    if (v == null) {
      sb.write('null');
    } else if (v is bool) {
      sb.write(v ? 'true' : 'false');
    } else if (v is int) {
      sb.write(v.toString());
    } else if (v is double) {
      throw ArgumentError('canonical JSON rejects floats');
    } else if (v is String) {
      _writeString(sb, v);
    } else if (v is List) {
      sb.write('[');
      for (var i = 0; i < v.length; i++) {
        if (i > 0) sb.write(',');
        _writeValue(sb, v[i]);
      }
      sb.write(']');
    } else if (v is Map) {
      final keys = <String>[];
      v.forEach((k, _) {
        if (k is! String) {
          throw ArgumentError(
              'canonical JSON requires string keys, got ${k.runtimeType}');
        }
        keys.add(k);
      });
      keys.sort(_utf8ByteCompare);
      sb.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) sb.write(',');
        _writeString(sb, keys[i]);
        sb.write(':');
        _writeValue(sb, v[keys[i]]);
      }
      sb.write('}');
    } else {
      throw ArgumentError(
          'canonical JSON does not support type ${v.runtimeType}');
    }
  }

  static int _utf8ByteCompare(String a, String b) {
    final ab = utf8.encode(a);
    final bb = utf8.encode(b);
    final n = ab.length < bb.length ? ab.length : bb.length;
    for (var i = 0; i < n; i++) {
      if (ab[i] != bb[i]) return ab[i] - bb[i];
    }
    return ab.length - bb.length;
  }

  static void _writeString(StringBuffer sb, String s) {
    sb.write('"');
    // Surrogate halves are written back as code units, so non BMP characters
    // still come out as raw UTF-8
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      switch (c) {
        case 0x22: // "
          sb.write(r'\"');
          break;
        case 0x5C: // backslash
          sb.write(r'\\');
          break;
        case 0x08:
          sb.write(r'\b');
          break;
        case 0x0C:
          sb.write(r'\f');
          break;
        case 0x0A:
          sb.write(r'\n');
          break;
        case 0x0D:
          sb.write(r'\r');
          break;
        case 0x09:
          sb.write(r'\t');
          break;
        default:
          if (c < 0x20) {
            sb.write('\\u');
            sb.write(c.toRadixString(16).padLeft(4, '0'));
          } else {
            sb.writeCharCode(c);
          }
      }
    }
    sb.write('"');
  }
}
