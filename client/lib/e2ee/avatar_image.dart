import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'file_pipeline.dart';
import 'jpeg_budget.dart';
import 'jpeg_sanity.dart';
import 'sealed_avatar.dart';

const int kAvatarDim = 512;
const int _avatarQuality = 86;
const int _avatarMinQuality = 60;
const int _avatarMinDim = 256;

class AvatarCrop {
  final int x;
  final int y;
  final int side;
  const AvatarCrop({required this.x, required this.y, required this.side});
}

abstract class AvatarImage {
  static Future<Uint8List> prepare(Uint8List picked,
      {ImageTranscoder? transcode}) async {
    final clean = await cleanPhoto(picked, transcode: transcode);
    return clean.jpeg;
  }

  // The square, scaled to kAvatarDim and small enough to pad into one blob
  static Future<Uint8List> render(Uint8List cleanJpeg, AvatarCrop crop) =>
      Isolate.run(() => _render(cleanJpeg, crop));

  // A quiet head and shoulders for someone who has not chosen a photo, so
  // nobody is left as a bare letter. The seed picks one of a few palettes
  static Future<Uint8List> generic(int seed) =>
      Isolate.run(() => _generic(seed));
}

// Top, bottom and figure, in the app's warm paper tones
const List<(int, int, int)> _genericPalettes = [
  (0xF8DCBC, 0xEDB98A, 0xC98F62), // peach
  (0xE1E9D8, 0xBFD0B0, 0x92A882), // sage
  (0xDFE9F1, 0xB9CFE0, 0x8AA6BE), // sky
  (0xEDE3F1, 0xD2C0DE, 0xA892BA), // lilac
  (0xF3EBDD, 0xDCCDB2, 0xB3A07F), // sand
];

Uint8List _generic(int seed) {
  // Drawn at twice the size and scaled down, which smooths the edges
  const n = kAvatarDim * 2;
  final (top, bottom, figure) =
      _genericPalettes[seed.abs() % _genericPalettes.length];
  int ch(int rgb, int shift) => (rgb >> shift) & 0xFF;
  final image = img.Image(width: n, height: n);
  for (var y = 0; y < n; y++) {
    final t = y / (n - 1);
    int mix(int shift) =>
        (ch(top, shift) + (ch(bottom, shift) - ch(top, shift)) * t).round();
    img.fillRect(image,
        x1: 0,
        y1: y,
        x2: n - 1,
        y2: y,
        color: img.ColorRgb8(mix(16), mix(8), mix(0)));
  }
  final ink = img.ColorRgb8(ch(figure, 16), ch(figure, 8), ch(figure, 0));
  // Head, then shoulders rising from below the frame
  img.fillCircle(image,
      x: n ~/ 2,
      y: (n * 0.41).round(),
      radius: (n * 0.17).round(),
      color: ink,
      antialias: true);
  img.fillCircle(image,
      x: n ~/ 2,
      y: (n * 1.1).round(),
      radius: (n * 0.4).round(),
      color: ink,
      antialias: true);
  final square = img.copyResize(image,
      width: kAvatarDim,
      height: kAvatarDim,
      interpolation: img.Interpolation.average);
  final jpeg = encodeJpegUnderBudget(
    square,
    budget: kAvatarMaxJpegBytes,
    quality: _avatarQuality,
    minQuality: _avatarMinQuality,
    minDim: _avatarMinDim,
  );
  final clean = JpegSanity.sanitize(jpeg.bytes);
  if (clean == null || clean.bytes.length > kAvatarMaxJpegBytes) {
    throw const UnprocessableImageException('avatar did not encode cleanly');
  }
  return clean.bytes;
}

Uint8List _render(Uint8List cleanJpeg, AvatarCrop crop) {
  final decoded = img.decodeJpg(cleanJpeg);
  if (decoded == null) {
    throw const UnprocessableImageException('avatar source is not a JPEG');
  }
  final side = crop.side.clamp(
      1, decoded.width < decoded.height ? decoded.width : decoded.height);
  final x = crop.x.clamp(0, decoded.width - side);
  final y = crop.y.clamp(0, decoded.height - side);
  var square = img.copyCrop(decoded, x: x, y: y, width: side, height: side);
  square = resizeLongEdge(square, kAvatarDim);
  square.exif = img.ExifData();
  final jpeg = encodeJpegUnderBudget(
    square,
    budget: kAvatarMaxJpegBytes,
    quality: _avatarQuality,
    minQuality: _avatarMinQuality,
    minDim: _avatarMinDim,
  );
  final clean = JpegSanity.sanitize(jpeg.bytes);
  if (clean == null || clean.bytes.length > kAvatarMaxJpegBytes) {
    throw const UnprocessableImageException('avatar did not encode cleanly');
  }
  return clean.bytes;
}
