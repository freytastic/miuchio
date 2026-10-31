import 'dart:typed_data';

import 'package:miuchio/e2ee/sealed_cover.dart';

// Null while the album has no key installed on this phone yet
typedef SealCover = Future<SealedCover?> Function(
    String albumId, Uint8List jpeg);
typedef UploadCover = Future<void> Function(String albumId, SealedCover cover);
// Null mediaId goes back to the newest photo
typedef ChooseCoverPhoto = Future<void> Function(
    String albumId, String? mediaId);
typedef RememberCover = Future<void> Function(
    String albumId, String coverId, Uint8List jpeg);

// The owner's three ways to set an album's cover. The server checks the
// caller is the owner, this only seals and sends
class CoverSetter {
  final SealCover _seal;
  final UploadCover _upload;
  final ChooseCoverPhoto _choose;
  final RememberCover _remember;

  CoverSetter({
    required SealCover seal,
    required UploadCover upload,
    required ChooseCoverPhoto choose,
    required RememberCover remember,
  })  : _seal = seal,
        _upload = upload,
        _choose = choose,
        _remember = remember;

  Future<void> useNewest(String albumId) => _choose(albumId, null);

  Future<void> usePhoto(String albumId, String mediaId) =>
      _choose(albumId, mediaId);

  // False while the album key is missing, nothing was sent
  Future<bool> useImage(String albumId, Uint8List jpeg) async {
    final sealed = await _seal(albumId, jpeg);
    if (sealed == null) return false;
    await _upload(albumId, sealed);
    await _remember(albumId, sealed.coverId, jpeg);
    return true;
  }
}
