part of 'profile_screen.dart';

enum _PhotoChoice { pick, remove }

class _PhotoSheet extends StatelessWidget {
  final Uint8List? photo;

  const _PhotoSheet({required this.photo});

  static Future<_PhotoChoice?> show(BuildContext context,
          {required Uint8List? photo}) =>
      showModalBottomSheet<_PhotoChoice>(
        context: context,
        backgroundColor: Warm.ground,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        builder: (_) => _PhotoSheet(photo: photo),
      );

  @override
  Widget build(BuildContext context) {
    final hasPhoto = photo != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 12, 22, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            const SizedBox(height: 12),
            Row(
              children: [
                _Face(photo: photo, size: 58, iconSize: 26),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Profile photo',
                          style: Warm.cardTitle.copyWith(letterSpacing: -0.3)),
                      const SizedBox(height: 2),
                      Text('Only people in your albums can see it.',
                          style: Warm.rowValue.copyWith(color: Warm.inkFaint)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                _SheetAction(
                  icon: Icons.photo_outlined,
                  label: hasPhoto ? 'New photo' : 'Choose photo',
                  onTap: () => Navigator.of(context).pop(_PhotoChoice.pick),
                ),
                if (hasPhoto) ...[
                  const SizedBox(width: 10),
                  _SheetAction(
                    icon: Icons.delete_outline_rounded,
                    label: 'Remove',
                    warn: true,
                    onTap: () => Navigator.of(context).pop(_PhotoChoice.remove),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool warn;
  final VoidCallback onTap;

  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.warn = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = warn ? Warm.warn : Warm.ink;
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: PressableScale(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 16, 8, 14),
            decoration: BoxDecoration(
              color: Warm.groundLift,
              borderRadius: BorderRadius.circular(16),
              boxShadow: Warm.stoneShadow,
            ),
            child: Column(
              children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(height: 7),
                Text(label,
                    style: Warm.rowTitle.copyWith(fontSize: 14, color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NameSheet extends StatefulWidget {
  final String name;

  const _NameSheet({required this.name});

  static Future<String?> show(BuildContext context, String name) =>
      showModalBottomSheet<String>(
        context: context,
        backgroundColor: Warm.ground,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        builder: (_) => _NameSheet(name: name),
      );

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final TextEditingController _draft =
      TextEditingController(text: widget.name);

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  String get _clean => _draft.text.trim();

  bool get _ready => _clean.isNotEmpty && _clean != widget.name.trim();

  void _save() {
    if (_ready) Navigator.of(context).pop(_clean);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(26, 12, 26, 22 + inset),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            const SizedBox(height: 16),
            Text('Your name', style: Warm.sheetTitle),
            const SizedBox(height: 16),
            WarmField(
              controller: _draft,
              label: 'Name',
              maxLength: 28,
              autofocus: true,
              autofillHints: const [AutofillHints.name],
              textInputAction: TextInputAction.done,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _save(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(2, 10, 2, 0),
              child: Text('Only people in your albums can see it.',
                  style: Warm.pageSoft),
            ),
            const SizedBox(height: 22),
            WarmButton(label: 'Save', onTap: _ready ? _save : null),
            const SizedBox(height: 6),
            Center(
              child: WarmTextButton(
                label: 'Cancel',
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Grip extends StatelessWidget {
  const _Grip();

  @override
  Widget build(BuildContext context) => Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Warm.inkGhost,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );
}
