part of 'profile_screen.dart';

enum _PhotoChoice { pick, remove }

class _PhotoSheet extends StatelessWidget {
  final bool hasPhoto;

  const _PhotoSheet({required this.hasPhoto});

  static Future<_PhotoChoice?> show(BuildContext context,
          {required bool hasPhoto}) =>
      showModalBottomSheet<_PhotoChoice>(
        context: context,
        backgroundColor: Warm.ground,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        builder: (_) => _PhotoSheet(hasPhoto: hasPhoto),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            const SizedBox(height: 10),
            _SheetRow(
              icon: Icons.photo_outlined,
              label: hasPhoto ? 'Choose a new photo' : 'Choose a photo',
              onTap: () => Navigator.of(context).pop(_PhotoChoice.pick),
            ),
            if (hasPhoto)
              _SheetRow(
                icon: Icons.delete_outline_rounded,
                label: 'Remove photo',
                warn: true,
                onTap: () => Navigator.of(context).pop(_PhotoChoice.remove),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
              child: Text('Only people in your albums can see it.',
                  style: Warm.pageSoft),
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool warn;
  final VoidCallback onTap;

  const _SheetRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.warn = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = warn ? Warm.warn : Warm.ink;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        height: 54,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              Icon(icon, size: 20, color: color),
              const SizedBox(width: 14),
              Text(label, style: Warm.sheetRow.copyWith(color: color)),
            ],
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

// How the albums page holds each pile down, shown as it would look
class _StyleSheet extends StatelessWidget {
  final AlbumStyle current;

  const _StyleSheet({required this.current});

  static Future<AlbumStyle?> show(BuildContext context, AlbumStyle current) =>
      showModalBottomSheet<AlbumStyle>(
        context: context,
        backgroundColor: Warm.ground,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
        builder: (_) => _StyleSheet(current: current),
      );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _Grip(),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text('Album style', style: Warm.sheetTitle),
            ),
            const SizedBox(height: 10),
            for (final style in AlbumStyle.values)
              Semantics(
                button: true,
                selected: style == current,
                label: style.label,
                excludeSemantics: true,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => Navigator.of(context).pop(style),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    child: Row(
                      children: [
                        AlbumStylePreview(style: style),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(style.label, style: Warm.sheetRow),
                              const SizedBox(height: 2),
                              Text(style.detail, style: Warm.rowValue),
                            ],
                          ),
                        ),
                        AnimatedOpacity(
                          opacity: style == current ? 1 : 0,
                          duration: Warm.quick,
                          child: const Icon(Icons.check_rounded,
                              size: 22, color: Warm.ink),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
