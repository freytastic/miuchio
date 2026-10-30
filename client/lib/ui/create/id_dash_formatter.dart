import 'package:flutter/services.dart';
import 'package:miuchio/e2ee/handle.dart';

// Keeps the dash after the fourth character while typing, pasting or editing
class IdDashFormatter extends TextInputFormatter {
  static final _separators = RegExp(r'[\s-]');

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    var raw = newValue.text.replaceAll(_separators, '');
    if (raw.length > handleLength) raw = raw.substring(0, handleLength);
    final end = newValue.selection.baseOffset;
    final caret = (end < 0
            ? raw.length
            : newValue.text
                .substring(0, end)
                .replaceAll(_separators, '')
                .length)
        .clamp(0, raw.length);
    // Keeps a dash the person typed themselves after the fourth character
    if (raw.length == 4 && newValue.text.endsWith('-')) {
      return TextEditingValue(
          text: '$raw-', selection: const TextSelection.collapsed(offset: 5));
    }
    if (raw.length <= 4) {
      return TextEditingValue(
          text: raw, selection: TextSelection.collapsed(offset: caret));
    }
    return TextEditingValue(
      text: '${raw.substring(0, 4)}-${raw.substring(4)}',
      selection: TextSelection.collapsed(offset: caret > 4 ? caret + 1 : caret),
    );
  }
}
