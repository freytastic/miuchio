import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/e2ee/media_record.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/encrypted_thumbnail.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';
import 'package:miuchio/ui/widgets/warm_button.dart';

import 'album_copy.dart';

// The album's own photos to choose a cover from. Pops the chosen media id
class CoverPicker extends StatelessWidget {
  final List<MediaRecord> photos;
  final MediaCacheManager cache;
  final String? current;

  const CoverPicker({
    super.key,
    required this.photos,
    required this.cache,
    this.current,
  });

  static Future<String?> show(
    BuildContext context, {
    required List<MediaRecord> photos,
    required MediaCacheManager cache,
    String? current,
  }) =>
      Navigator.of(context).push(MaterialPageRoute<String>(
        builder: (_) =>
            CoverPicker(photos: photos, cache: cache, current: current),
      ));

  @override
  Widget build(BuildContext context) {
    // The server only takes a photo whose thumbnail it holds
    final usable = photos.where((r) => r.hasThumb).toList();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Warm.overlayOnGround,
      child: Scaffold(
        backgroundColor: Warm.ground,
        body: SafeArea(
          bottom: false,
          child: CustomScrollView(
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            slivers: [
              const SliverPadding(
                padding: EdgeInsets.fromLTRB(Warm.pagePad - 8, 16, 0, 0),
                sliver: SliverToBoxAdapter(
                  child:
                      Align(alignment: Alignment.centerLeft, child: WarmBack()),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                    Warm.pagePad, 22, Warm.pagePad, 18),
                sliver: SliverToBoxAdapter(
                  child: Text(AlbumCopy.coverFromAlbum, style: Warm.pageTitle),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                    Warm.pagePad, 0, Warm.pagePad, 40),
                sliver: SliverGrid.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 6,
                    crossAxisSpacing: 6,
                  ),
                  itemCount: usable.length,
                  itemBuilder: (context, i) {
                    final r = usable[i];
                    final on = r.id == current;
                    return PressableScale(
                      onTap: () => Navigator.of(context).pop(r.id),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Warm.wellEmpty,
                          borderRadius: BorderRadius.circular(6),
                          border:
                              on ? Border.all(color: Warm.ink, width: 2) : null,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: EncryptedThumbnail(record: r, cache: cache),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
