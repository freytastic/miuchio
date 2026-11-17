import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';

// The peek's glass tray: one flat card, no clip, blur or shadow, so it costs
// what the old dock did on the fill-bound phones

class PeekDock extends StatelessWidget {
  final bool owner;
  final VoidCallback onHeart;
  final VoidCallback onSave;
  final VoidCallback onDelete;
  final VoidCallback onSay;

  const PeekDock({
    super.key,
    required this.owner,
    required this.onHeart,
    required this.onSave,
    required this.onDelete,
    required this.onSay,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      decoration: BoxDecoration(
        color: Warm.glassFill,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Warm.glassHairline),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _TrayAction(
                key: const Key('photo-peek-heart'),
                label: AlbumCopy.heart,
                icon: Icons.favorite_border_rounded,
                onTap: onHeart,
              ),
              const _TrayDivider(),
              _TrayAction(
                key: const Key('photo-peek-save'),
                label: AlbumCopy.save,
                icon: Icons.download_rounded,
                onTap: onSave,
              ),
              if (owner) ...[
                const _TrayDivider(),
                _TrayAction(
                  key: const Key('photo-peek-delete'),
                  label: AlbumCopy.delete,
                  icon: Icons.delete_outline_rounded,
                  color: Warm.warnGlassSoft,
                  onTap: onDelete,
                ),
              ],
            ],
          ),
          _SayRow(onTap: onSay),
        ],
      ),
    );
  }
}

const _trayInk = Color(0xE0FFFFFF);
const _trayLine = Color(0x1FFFFFFF);

class _TrayAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _TrayAction({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.color = _trayInk,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: PressableScale(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 13, 4, 11),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 21, color: color),
                const SizedBox(height: 5),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrayDivider extends StatelessWidget {
  const _TrayDivider();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      width: 1,
      height: 41,
      child: ColoredBox(color: _trayLine),
    );
  }
}

class _SayRow extends StatelessWidget {
  final VoidCallback onTap;

  const _SayRow({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return PressableScale(
      key: const Key('photo-peek-say'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(15, 12, 10, 12),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: _trayLine)),
        ),
        child: const Row(
          children: [
            Icon(Icons.chat_bubble_outline_rounded,
                size: 17, color: Warm.glassInkFaint),
            SizedBox(width: 9),
            Expanded(
              child: Text(
                AlbumCopy.sayPlaceholder,
                style: TextStyle(fontSize: 13.5, color: Warm.glassInkFaint),
              ),
            ),
            _LaterPill(),
          ],
        ),
      ),
    );
  }
}

class _LaterPill extends StatelessWidget {
  const _LaterPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Warm.glassFill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        AlbumCopy.laterBadge,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: Warm.glassInkFaint,
        ),
      ),
    );
  }
}

class PeekRoundButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool quiet;
  final VoidCallback onTap;

  const PeekRoundButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.quiet = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: PressableScale(
        onTap: onTap,
        child: Container(
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            color: quiet ? const Color(0x14FFFFFF) : Warm.glassFill,
            shape: BoxShape.circle,
            border: Border.all(color: Warm.glassHairline),
          ),
          child: Icon(icon,
              size: 21,
              color: quiet ? const Color(0x9EFFFFFF) : const Color(0xD9FFFFFF)),
        ),
      ),
    );
  }
}

class PeekNote extends StatelessWidget {
  final String text;

  const PeekNote({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      decoration: BoxDecoration(
        color: const Color(0xE62A2622),
        borderRadius: BorderRadius.circular(18),
      ),
      // The note sits outside the peek's Material and needs its own text style
      child: Material(
        type: MaterialType.transparency,
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
