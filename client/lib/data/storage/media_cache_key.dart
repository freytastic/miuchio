// epoch_tag is part of the key so a row reencrypted under a new epoch never
// reads back old plaintext

enum CacheAsset { file, thumb }

class MediaCacheKey {
  final String albumId;
  final String mediaId;
  final int epochTag;
  final CacheAsset asset;

  const MediaCacheKey({
    required this.albumId,
    required this.mediaId,
    required this.epochTag,
    required this.asset,
  });

  // No epoch_tag, disk blobs are one per media_id and the epoch lives on the row
  String get diskFilename =>
      asset == CacheAsset.thumb ? '$mediaId.thumb.kec' : '$mediaId.kec';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaCacheKey &&
          albumId == other.albumId &&
          mediaId == other.mediaId &&
          epochTag == other.epochTag &&
          asset == other.asset;

  @override
  int get hashCode => Object.hash(albumId, mediaId, epochTag, asset);
}
