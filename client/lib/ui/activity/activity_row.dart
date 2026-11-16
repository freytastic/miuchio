import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/album/member_avatars.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/member_face.dart';

import 'activity_copy.dart';

typedef ActivityThumb = Widget Function(MediaRecord record);
// The album's newest photo, null while it is unknown or not yet opened
typedef ActivityAlbumPhoto = Uint8List? Function(String albumId);

class ActivityRow extends StatelessWidget {
  final LineCopy line;
  final Widget face;
  final VoidCallback? onTap;
  final List<MediaRecord> previews;
  final int more;
  final ActivityThumb? thumb;

  const ActivityRow({
    super.key,
    required this.line,
    required this.face,
    this.onTap,
    this.previews = const [],
    this.more = 0,
    this.thumb,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onTap != null,
      label: '${line.lead}${line.rest}, ${line.where}',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        // Read state lives in tab and shelf indicators, not row opacity
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              face,
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: line.lead, style: Warm.acLead),
                            TextSpan(text: line.rest, style: Warm.acLine),
                          ],
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(line.where, style: Warm.acWhere),
                      if (line.aside != null) _Aside(line.aside!, line.warn),
                      if (previews.isNotEmpty)
                        _Strip(previews: previews, more: more, thumb: thumb),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Aside extends StatelessWidget {
  final String text;
  final bool warn;
  const _Aside(this.text, this.warn);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 7),
      padding: const EdgeInsets.only(left: 11),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: warn ? Warm.warn : Warm.inkGhost, width: 1.5),
        ),
      ),
      child: Text(
        text,
        style: warn ? Warm.acAside.copyWith(color: Warm.warn) : Warm.acAside,
      ),
    );
  }
}

class _Strip extends StatelessWidget {
  final List<MediaRecord> previews;
  final int more;
  final ActivityThumb? thumb;
  const _Strip({required this.previews, required this.more, this.thumb});

  static const double _tile = 58;
  static const double _gap = 3;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      // Shrinks on narrow phones rather than overflowing the line
      child: LayoutBuilder(builder: (context, box) {
        final n = previews.length;
        final tile = ((box.maxWidth - _gap * (n - 1)) / n).clamp(0.0, _tile);
        return Row(
          children: [
            for (var i = 0; i < n; i++) ...[
              if (i > 0) const SizedBox(width: _gap),
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: tile,
                  height: tile,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      const ColoredBox(color: Warm.wellEmpty),
                      if (thumb != null) thumb!(previews[i]),
                      if (i == n - 1 && more > 0)
                        ColoredBox(
                          color: const Color(0x85181410),
                          child: Center(
                            child: Text('+$more',
                                style: Warm.acMore.copyWith(fontSize: 12)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        );
      }),
    );
  }
}

// Unresolved sealed names appear only as their stable album colour
class ActivityFace extends StatelessWidget {
  final String? albumId;
  final String? name;
  final String? token;
  final bool alarm;
  // Stands in for a face on events about you
  final IconData? glyph;
  // Stands in for the glyph when the album's own photo is at hand
  final Uint8List? albumPhoto;
  final IconData? mark;
  final bool markWarn;
  const ActivityFace({
    super.key,
    this.albumId,
    this.name,
    this.token,
    this.alarm = false,
    this.glyph,
    this.albumPhoto,
    this.mark,
    this.markWarn = false,
  });

  @override
  Widget build(BuildContext context) {
    final initial = (name == null || name!.isEmpty)
        ? ''
        : name!.characters.first.toUpperCase();
    final t = token;
    final photo = memberPhoto(context, t == null ? null : albumId, t ?? '');
    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          FaceCircle(
            size: 32,
            color: t == null
                ? const Color(0x0F1C1917)
                : MemberAvatars.hueFor(t).withValues(alpha: 0.95),
            // A changed key may be an impostor, so its card never shows a face
            photo: alarm ? null : albumPhoto ?? photo,
            child: glyph != null && albumPhoto == null
                ? Icon(glyph, size: 16, color: Warm.inkSoft)
                : Text(initial, style: Warm.acFace),
          ),
          if (alarm)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                width: 18,
                height: 18,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Warm.warn,
                  border: Border.all(color: const Color(0xFFEFEBE3), width: 2),
                ),
                child: const Icon(Icons.fingerprint_rounded,
                    size: 11, color: Warm.paper),
              ),
            )
          else if (mark != null)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                width: 19,
                height: 19,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: markWarn ? Warm.warn : const Color(0xFFE7E1D7),
                  border: Border.all(color: Warm.ground, width: 2),
                ),
                child: Icon(mark,
                    size: 11, color: markWarn ? Warm.paper : Warm.inkSoft),
              ),
            ),
        ],
      ),
    );
  }
}
