import 'package:flutter/material.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';

import 'album_copy.dart';

// The card and rows of a floating menu, as the shelf's long press shows
class MenuCard extends StatelessWidget {
  final List<Widget> children;

  const MenuCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        // Cap width because Positioned leaves it unbounded
        constraints: const BoxConstraints(minWidth: 196, maxWidth: 280),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          gradient: Warm.stoneFill,
          borderRadius: BorderRadius.circular(15),
          boxShadow: Warm.printShadowSmall,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class MenuItem extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool danger;

  const MenuItem(
      {super.key,
      required this.label,
      required this.onTap,
      this.icon,
      this.danger = false});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return PressableScale(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w500,
                  color: !enabled
                      ? Warm.inkFaint
                      : danger
                          ? Warm.warn
                          : Warm.ink,
                ),
              ),
            ),
            if (!enabled)
              const _LaterBadge()
            else if (icon != null)
              Icon(icon, size: 18, color: danger ? Warm.warn : Warm.inkSoft),
          ],
        ),
      ),
    );
  }
}

class _LaterBadge extends StatelessWidget {
  const _LaterBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Warm.wellEmpty,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        AlbumCopy.laterBadge,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
          color: Warm.inkFaint,
        ),
      ),
    );
  }
}

class MenuSeparator extends StatelessWidget {
  const MenuSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      color: Warm.inkGhost,
    );
  }
}
