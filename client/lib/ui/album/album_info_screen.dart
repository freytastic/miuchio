import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';
import 'package:miuchio/ui/widgets/member_face.dart';

import 'album_copy.dart';
import 'album_stats.dart';

// Returns null until the member name is decrypted
typedef MemberNameLookup = String? Function(String memberToken);

// What the album should do once this screen closes
enum AlbumInfoExit { leave, delete }

class AlbumInfoScreen extends StatelessWidget {
  final String? albumId;
  final String albumName;
  final DateTime createdAt;
  final AlbumStats stats;
  final MemberNameLookup nameOf;
  final String? madeBy;
  // The ending this viewer may choose: owners delete, everyone else leaves.
  // Null shows neither
  final AlbumInfoExit? exit;

  const AlbumInfoScreen({
    super.key,
    this.albumId,
    required this.albumName,
    required this.createdAt,
    required this.stats,
    required this.nameOf,
    this.madeBy,
    this.exit,
  });

  @override
  Widget build(BuildContext context) {
    final made = madeBy;
    // One sentence instead of "Made by" and "Created" rows
    final origin = made == null
        ? 'Started on ${_formatDate(createdAt)}'
        : made == AlbumCopy.madeByYou
            ? 'You started it on ${_formatDate(createdAt)}'
            : '$made started it on ${_formatDate(createdAt)}';
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          bottom: false,
          child: ListView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            padding: const EdgeInsets.fromLTRB(
                Warm.pagePad - 8, 16, Warm.pagePad - 8, 56),
            children: [
              const Align(alignment: Alignment.centerLeft, child: WarmBack()),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 22, 8, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(albumName, style: Warm.pageTitle),
                    const SizedBox(height: 6),
                    Text(origin, style: Warm.rowValue),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _Totals(stats: stats),
              const SizedBox(height: 32),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(AlbumCopy.infoStorage.toUpperCase(),
                    style: Warm.sectionLabel),
              ),
              const SizedBox(height: 12),
              if (stats.perUploader.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(AlbumCopy.infoStorageEmpty, style: Warm.note),
                )
              else
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  decoration: BoxDecoration(
                    color: Warm.groundLift,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Column(
                    children: [
                      for (final entry in stats.byWeight)
                        _UploaderRow(
                          albumId: albumId,
                          token: entry.key,
                          name: nameOf(entry.key),
                          tally: entry.value,
                          share: stats.totalBytes == 0
                              ? 0
                              : entry.value.bytes / stats.totalBytes,
                        ),
                    ],
                  ),
                ),
              const SizedBox(height: 18),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.lock_outline_rounded,
                          size: 14, color: Warm.inkFaint),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                        child: Text('${AlbumCopy.infoKey}.', style: Warm.note)),
                  ],
                ),
              ),
              // The way out sits at the end of the facts, a step past the
              // album itself, so it is never a stray tap away
              if (exit != null) ...[
                const SizedBox(height: 36),
                _ExitRow(
                  exit: exit!,
                  onTap: () => Navigator.of(context).pop(exit),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June', //
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

// The numbers lead and their units sit quietly under them, so nothing
// needs a "Photos:" label in front
class _Totals extends StatelessWidget {
  final AlbumStats stats;

  const _Totals({required this.stats});

  @override
  Widget build(BuildContext context) {
    final photos = stats.photoCount;
    final people = stats.peopleCount;
    final size = AlbumStats.formatBytes(stats.totalBytes);
    return Container(
      decoration: BoxDecoration(
        color: Warm.groundLift,
        borderRadius: BorderRadius.circular(18),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            _Total(value: '$photos', unit: photos == 1 ? 'photo' : 'photos'),
            const VerticalDivider(
                width: 1,
                thickness: 1,
                indent: 16,
                endIndent: 16,
                color: Warm.inkGhost),
            _Total(value: size, unit: 'stored'),
            const VerticalDivider(
                width: 1,
                thickness: 1,
                indent: 16,
                endIndent: 16,
                color: Warm.inkGhost),
            _Total(value: '$people', unit: people == 1 ? 'person' : 'people'),
          ],
        ),
      ),
    );
  }
}

class _Total extends StatelessWidget {
  final String value;
  final String unit;

  const _Total({required this.value, required this.unit});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        label: '$value $unit',
        excludeSemantics: true,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Column(
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.6,
                  height: 1.1,
                  color: Warm.ink,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 3),
              Text(unit,
                  style: const TextStyle(fontSize: 12.5, color: Warm.inkSoft)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ExitRow extends StatelessWidget {
  final AlbumInfoExit exit;
  final VoidCallback onTap;

  const _ExitRow({required this.exit, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final leave = exit == AlbumInfoExit.leave;
    return Material(
      color: Warm.paper,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        key: Key(leave ? 'album-info-leave' : 'album-info-delete'),
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Icon(leave ? Icons.logout_rounded : Icons.delete_outline_rounded,
                  size: 20, color: Warm.warn),
              const SizedBox(width: 12),
              Text(
                leave ? AlbumCopy.leaveAlbum : AlbumCopy.deleteAlbum,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Warm.warn),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Who the space belongs to, said as "4 photos · 1.2 MB" rather than a bare
// count, with each person's share drawn in their own colour
class _UploaderRow extends StatelessWidget {
  final String? albumId;
  final String token;
  final String? name;
  final UploaderTally tally;
  final double share;

  const _UploaderRow({
    required this.albumId,
    required this.token,
    required this.name,
    required this.tally,
    required this.share,
  });

  @override
  Widget build(BuildContext context) {
    final photos = '${tally.photos} ${tally.photos == 1 ? 'photo' : 'photos'}';
    final percent = '${(share * 100).round()}%';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          MemberFace(
            albumId: albumId,
            token: token,
            name: name,
            size: 36,
            style: Warm.acFace.copyWith(fontSize: 13),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        // Never show member tokens as names
                        name ?? AlbumCopy.unknownMember,
                        overflow: TextOverflow.ellipsis,
                        style: Warm.rowTitle,
                      ),
                    ),
                    Text(
                      percent,
                      style: Warm.rowValue.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text('$photos · ${AlbumStats.formatBytes(tally.bytes)}',
                    style: Warm.rowValue.copyWith(color: Warm.inkFaint)),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: share.clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: Warm.wellEmpty,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(faceHue(token, name)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
