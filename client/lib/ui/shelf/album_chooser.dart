import 'package:flutter/material.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/ui/shelf/album_print.dart';
import 'package:miuchio/ui/shelf/still_print.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

// Where new photos go, as the same prints the shelf shows. Most recent first,
// since that is usually where they belong
class AlbumChooser extends StatelessWidget {
  final List<AlbumModel> albums;

  const AlbumChooser({super.key, required this.albums});

  static const title = 'Add photos to';

  static Future<AlbumModel?> show(
      BuildContext context, List<AlbumModel> albums) {
    final sorted = [...albums]..sort((a, b) =>
        (b.latestActivityAt ?? b.createdAt)
            .compareTo(a.latestActivityAt ?? a.createdAt));
    return showModalBottomSheet<AlbumModel>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Warm.paper,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => AlbumChooser(albums: sorted),
    );
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.78;
    return SizedBox(
      height: height,
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding:
                const EdgeInsets.fromLTRB(Warm.pagePad, 26, Warm.pagePad, 6),
            sliver: SliverToBoxAdapter(
              child: Text(title, style: Warm.pageTitle),
            ),
          ),
          SliverPadding(
            padding:
                const EdgeInsets.fromLTRB(Warm.pagePad, 18, Warm.pagePad, 40),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 22,
                crossAxisSpacing: 18,
                childAspectRatio: 300 / 372,
              ),
              itemCount: albums.length,
              itemBuilder: (context, i) => StillPrint(
                album: albums[i],
                size: PrintSize.small,
                onTap: () => Navigator.of(context).pop(albums[i]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
