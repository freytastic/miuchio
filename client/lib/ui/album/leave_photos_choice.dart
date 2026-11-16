import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

import 'album_copy.dart';

// Keep or delete the photos someone added, picked when leaving and in settings
class LeavePhotosChoice extends StatelessWidget {
  final bool delete;
  final ValueChanged<bool>? onChanged;
  final bool short;

  const LeavePhotosChoice({
    super.key,
    required this.delete,
    required this.onChanged,
    this.short = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Option(
          key: const Key('leave-photos-keep'),
          title: AlbumCopy.keepPhotos,
          note: short ? AlbumCopy.keepPhotosShort : AlbumCopy.keepPhotosNote,
          on: !delete,
          onTap: onChanged == null ? null : () => onChanged!(false),
        ),
        _Option(
          key: const Key('leave-photos-delete'),
          title: AlbumCopy.deletePhotos,
          note:
              short ? AlbumCopy.deletePhotosShort : AlbumCopy.deletePhotosNote,
          on: delete,
          onTap: onChanged == null ? null : () => onChanged!(true),
        ),
      ],
    );
  }
}

class _Option extends StatelessWidget {
  final String title;
  final String note;
  final bool on;
  final VoidCallback? onTap;

  const _Option({
    super.key,
    required this.title,
    required this.note,
    required this.on,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: on,
      enabled: onTap != null,
      label: title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap == null || on
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Warm.rowTitle),
                    const SizedBox(height: 3),
                    Text(note, style: Warm.pageSoft),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              AnimatedContainer(
                duration: Warm.quick,
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: on ? Warm.cocoa : Colors.transparent,
                  border:
                      on ? null : Border.all(color: Warm.inkGhost, width: 1.6),
                ),
                child: on
                    ? const Icon(Icons.check_rounded,
                        size: 15, color: Warm.ground)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// A slice of an album with your photos marked, which Delete takes out, using
// real photos where the phone has them and bundled ones where not
class LeavePhotosPreview extends StatelessWidget {
  final bool delete;
  final List<Widget> yours;
  final List<Widget> others;

  const LeavePhotosPreview({
    super.key,
    required this.delete,
    this.yours = const [],
    this.others = const [],
  });

  static const _yours = {1, 5};
  static const _stockYours = [
    'lib/assets/leave/moon.jpg',
    'lib/assets/leave/city.jpg',
  ];
  static const _stockOthers = [
    'lib/assets/onboarding/picnic_1.jpg',
    'lib/assets/leave/graduation.jpg',
    'lib/assets/onboarding/picnic_2.jpg',
    'lib/assets/onboarding/picnic_3.jpg',
  ];

  Widget _stock(BuildContext context, String asset) => Image.asset(
        asset,
        fit: BoxFit.cover,
        cacheWidth: (120 * MediaQuery.devicePixelRatioOf(context)).round(),
      );

  @override
  Widget build(BuildContext context) {
    var y = 0, o = 0;
    Widget next(bool mine) {
      if (mine) {
        final i = y++;
        return i < yours.length ? yours[i] : _stock(context, _stockYours[i]);
      }
      final i = o++;
      return i < others.length ? others[i] : _stock(context, _stockOthers[i]);
    }

    return ExcludeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 3,
              crossAxisSpacing: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                for (var i = 0; i < 6; i++)
                  _yours.contains(i)
                      ? _YourTile(gone: delete, photo: next(true))
                      : _Tile(photo: next(false)),
              ],
            ),
            const SizedBox(height: 9),
            Text(delete ? AlbumCopy.leaveGoneSay : AlbumCopy.leaveKeptSay,
                style: Warm.pageSoft.copyWith(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final Widget photo;

  const _Tile({required this.photo});

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: Warm.wellEmpty, child: photo),
            // Steps back like half opacity, without a layer of its own
            ColoredBox(color: Warm.ground.withValues(alpha: 0.5)),
          ],
        ),
      );
}

class _YourTile extends StatelessWidget {
  final bool gone;
  final Widget photo;

  const _YourTile({required this.gone, required this.photo});

  static const _move = Duration(milliseconds: 400);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: Warm.inkGhost, width: 1.5),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedOpacity(
            duration: _move,
            curve: Warm.easeOut,
            opacity: gone ? 0 : 1,
            child: AnimatedScale(
              duration: _move,
              curve: Warm.easeOut,
              scale: gone ? 0.86 : 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: ColoredBox(color: Warm.wellEmpty, child: photo),
              ),
            ),
          ),
          Positioned(
            left: 4,
            bottom: 4,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 300),
              opacity: gone ? 0.45 : 1,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Warm.groundLift.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: Text(AlbumCopy.leaveYours,
                    style: Warm.sectionLabel.copyWith(
                        letterSpacing: 0,
                        fontWeight: FontWeight.w600,
                        fontVariations: const [FontVariation('wght', 650)],
                        color: Warm.ink)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
