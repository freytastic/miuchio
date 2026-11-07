import 'dart:convert';
import 'dart:typed_data';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/data/api/safety_api.dart';
import 'package:miuchio/data/storage/media_cache_manager.dart';
import 'package:miuchio/domain/safety/moderation_key.dart';
import 'package:miuchio/e2ee/album_keys.dart';
import 'package:miuchio/e2ee/file_decryptor.dart';
import 'package:miuchio/e2ee/media_record.dart';

enum ReportReason {
  sexual('sexual'),
  violence('violence'),
  harassment('harassment'),
  childSafety('child_safety'),
  other('other');

  final String code;
  const ReportReason(this.code);
}

class ReportDraft {
  final ReportReason reason;
  final String note;

  const ReportDraft(this.reason, {this.note = ''});
}

// Sends what this phone can already see, sealed to the moderation key. Album
// keys never leave, only the one photo's own thumbnail key
class Reporter {
  final SafetyApi api;
  final AlbumKeyStore aks;
  final MediaCacheManager cache;
  final String publicKey;

  Reporter({
    required this.api,
    required this.aks,
    required this.cache,
    this.publicKey = kModerationPublicKey,
  });

  Future<void> photo(MediaRecord r, ReportDraft draft) async {
    Uint8List? thumb;
    Uint8List? thumbKey;
    if (r.hasThumb) {
      thumb = await cache.getDecrypted(r, thumb: true);
      thumbKey = await FileDecryptor.unwrapThumbDek(aks: aks, record: r);
    }
    try {
      await api.report(r.albumId,
          kind: 'photo',
          mediaId: r.id,
          sealed: _seal({
            ..._base('photo', r.albumId, draft),
            'media_id': r.id,
            if (thumb != null) 'thumb': base64Encode(thumb),
            if (thumbKey != null) 'thumb_key': base64Encode(thumbKey),
          }));
    } finally {
      thumbKey?.fillRange(0, thumbKey.length, 0);
    }
  }

  Future<void> person(
      String albumId, String memberToken, ReportDraft draft) async {
    await api.report(albumId,
        kind: 'person',
        memberToken: memberToken,
        sealed: _seal({
          ..._base('person', albumId, draft),
          'member_token': memberToken,
        }));
  }

  // Mirrored in server/cmd/mod/main.go
  static Map<String, dynamic> _base(
          String kind, String albumId, ReportDraft draft) =>
      {
        'v': 1,
        'kind': kind,
        'reason': draft.reason.code,
        'note': draft.note.trim(),
        'album_id': albumId,
      };

  Uint8List _seal(Map<String, dynamic> payload) {
    if (publicKey.isEmpty) throw StateError('moderation key not set');
    return SealedBox.seal(Uint8List.fromList(utf8.encode(jsonEncode(payload))),
        base64Decode(publicKey));
  }
}
