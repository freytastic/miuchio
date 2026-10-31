import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/ui/people/album_people.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/settings/settings_page.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

// What security codes are, from You. Comparing happens inside an album,
// because each code belongs to one album, so this page only explains and
// points at albums where a code changed
class SecurityCodesPage extends StatefulWidget {
  final Future<void> Function(AlbumModel album) onOpenAlbum;
  final AlbumService? service;

  const SecurityCodesPage({super.key, required this.onOpenAlbum, this.service});

  @override
  State<SecurityCodesPage> createState() => _SecurityCodesPageState();
}

class _SecurityCodesPageState extends State<SecurityCodesPage> {
  List<AlbumModel>? _changed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final changed = await albumsToCheck(context, service: widget.service);
    if (mounted) setState(() => _changed = changed);
  }

  Future<void> _open(AlbumModel album) async {
    HapticFeedback.selectionClick();
    await widget.onOpenAlbum(album);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final changed = _changed;
    return SettingsPage(
      title: 'Security codes',
      glyph: Icons.verified_user_outlined,
      children: [
        const SettingsLead('Optional. A way to be sure no one is in between '
            'you and the people you share with.'),
        const SettingsFacts([
          (
            Icons.lock_outline_rounded,
            'Your photos are encrypted on this phone before they leave it, '
                'whether or not you compare codes.'
          ),
          (
            Icons.photo_album_outlined,
            'Each album has its own code for each person in it. To compare, '
                'you both open the same album and tap Security codes under '
                'its people.'
          ),
          (
            Icons.smartphone_outlined,
            "When every digit matches, it's saved on this phone only. "
                "Miuchio isn't told."
          ),
        ]),
        if (changed != null && changed.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('ALBUMS TO CHECK', style: Warm.sectionLabel),
          const SizedBox(height: 6),
          for (final a in changed)
            _AlbumRow(
              key: ValueKey('check-${a.id}'),
              name: state.albumDisplayName(a.id) ?? 'Album',
              onTap: () => _open(a),
            ),
        ] else if (changed != null)
          const SettingsSoft('No security codes have changed.'),
      ],
    );
  }
}

class _AlbumRow extends StatelessWidget {
  final String name;
  final VoidCallback onTap;

  const _AlbumRow({super.key, required this.name, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$name, a security code changed',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name,
                        style: Warm.rowTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 1),
                    Text('A security code changed',
                        style: Warm.rowValue.copyWith(color: Warm.warn)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 17, color: Warm.inkGhost),
            ],
          ),
        ),
      ),
    );
  }
}
