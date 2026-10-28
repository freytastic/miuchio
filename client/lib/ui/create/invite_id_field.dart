import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/e2ee/handle.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';

import 'create_copy.dart';

// Edits, validates and normalizes invite IDs
class InviteIdField extends StatefulWidget {
  final List<String> ids;
  final ValueChanged<List<String>> onChanged;
  final bool enabled;

  const InviteIdField({
    super.key,
    required this.ids,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<InviteIdField> createState() => _InviteIdFieldState();
}

class _InviteIdFieldState extends State<InviteIdField> {
  final _controller = _IdMaskController();
  final _focus = FocusNode();
  bool _entering = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _openEntry() {
    setState(() {
      _entering = true;
      _error = null;
    });
    _focus.requestFocus();
  }

  void _submit() {
    final String handle;
    try {
      handle = normalizeHandle(_controller.text);
    } on FormatException {
      setState(() => _error = CreateCopy.idInvalid);
      return;
    }
    if (widget.ids.contains(handle)) {
      setState(() => _error = CreateCopy.idDuplicate);
      return;
    }
    widget.onChanged([...widget.ids, handle]);
    _controller.clear();
    setState(() {
      _entering = false;
      _error = null;
    });
  }

  void _remove(String id) => widget.onChanged([...widget.ids]..remove(id));

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(CreateCopy.invitePeople, style: _sectionLabel),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final id in widget.ids)
              _InviteChip(
                id: id,
                onRemove: widget.enabled ? () => _remove(id) : null,
              ),
            if (!_entering)
              _AddPersonButton(onTap: widget.enabled ? _openEntry : null),
          ],
        ),
        if (_entering) ...[
          const SizedBox(height: 10),
          _IdEntryRow(
            controller: _controller,
            focusNode: _focus,
            enabled: widget.enabled,
            onSubmit: _submit,
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!,
              style: const TextStyle(fontSize: 12.5, color: Warm.warnGlass)),
        ],
        const SizedBox(height: 12),
        Text(
          widget.ids.isEmpty
              ? CreateCopy.privacyEmpty
              : CreateCopy.privacyWithInvites,
          style: const TextStyle(
              fontSize: 12.5, height: 1.45, color: Warm.glassInkSoft),
        ),
      ],
    );
  }

  static const _sectionLabel = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.2,
    color: Warm.glassInkFaint,
  );
}

class _InviteChip extends StatelessWidget {
  final String id;
  final VoidCallback? onRemove;

  const _InviteChip({required this.id, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final display = formatHandle(id);
    return Container(
      height: 34,
      padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
      decoration: BoxDecoration(
        color: Warm.glassFill,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: Warm.glassHairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(display,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: Warm.glassInk,
              )),
          const SizedBox(width: 2),
          PressableScale(
            onTap: onRemove,
            child: Tooltip(
              message: '${CreateCopy.removePerson} $display',
              child: const SizedBox(
                width: 24,
                height: 24,
                child: Icon(Icons.close_rounded,
                    size: 14, color: Warm.glassInkSoft),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AddPersonButton extends StatelessWidget {
  final VoidCallback? onTap;

  const _AddPersonButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(17),
          border: Border.all(color: Warm.glassHairlineStrong),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 15, color: Warm.glassInkSoft),
            SizedBox(width: 7),
            Text(CreateCopy.addPerson,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Warm.glassInkSoft)),
          ],
        ),
      ),
    );
  }
}

class _IdEntryRow extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final VoidCallback onSubmit;

  const _IdEntryRow({
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            enabled: enabled,
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            inputFormatters: [_IdDashFormatter()],
            style: const TextStyle(
                fontSize: 15, letterSpacing: 1.2, color: Warm.glassInk),
            decoration: InputDecoration(
              isDense: true,
              labelText: CreateCopy.idPlaceholder,
              floatingLabelBehavior: FloatingLabelBehavior.always,
              labelStyle: const TextStyle(color: Warm.glassInkFaint),
              filled: true,
              fillColor: Warm.glassFill,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
        ),
        const SizedBox(width: 8),
        PressableScale(
          onTap: enabled ? onSubmit : null,
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Text('Add',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Warm.glassInk)),
          ),
        ),
      ],
    );
  }
}

// Draws the untyped rest of the ID faintly after the text, so the dash and
// remaining X's stay visible. Flutter ignores taps that land on that part
class _IdMaskController extends TextEditingController {
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    const mask = CreateCopy.idHint;
    return TextSpan(style: style, children: [
      TextSpan(text: text),
      if (text.length < mask.length)
        TextSpan(
          text: mask.substring(text.length),
          style: const TextStyle(color: Warm.glassInkFaint),
        ),
    ]);
  }
}

// Keeps the dash after the fourth character while typing, pasting or editing
class _IdDashFormatter extends TextInputFormatter {
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
