// Crockford base32 miuchio_id. Must fold exactly like Normalize in
// server/internal/handle, shared vectors live in handle_test.dart

const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
const handleLength = 8;

// Drops dashes and whitespace, upper cases, folds I and L to 1 and O to 0
String normalizeHandle(String input) {
  final out = StringBuffer();
  for (final rune in input.runes) {
    var c = rune;
    if (c == 0x2D || c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
      continue;
    }
    if (c >= 0x61 && c <= 0x7A) c -= 0x20;
    if (c == 0x49 || c == 0x4C) {
      c = 0x31;
    } else if (c == 0x4F) {
      c = 0x30;
    }
    final ch = String.fromCharCode(c);
    if (!_alphabet.contains(ch)) {
      throw const FormatException('invalid miuchio_id handle');
    }
    out.write(ch);
    if (out.length > handleLength) {
      throw const FormatException('invalid miuchio_id handle');
    }
  }
  if (out.length != handleLength) {
    throw const FormatException('invalid miuchio_id handle');
  }
  return out.toString();
}

// Display only, storage and the wire use the canonical value
String formatHandle(String canonical) {
  if (canonical.length != handleLength) return canonical;
  return '${canonical.substring(0, 4)}-${canonical.substring(4)}';
}
