import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'file_pipeline.dart';
import 'jpeg_budget.dart';
import 'jpeg_sanity.dart';
import 'photo_clean.dart';
import 'sealed_cover.dart';

const int _coverDim = 1280;
const int _coverQuality = 84;
const int _coverMinQuality = 60;
const int _coverMinDim = 640;

abstract class CoverImage {
  // Cleaned of metadata first, then sized to fit one padded cover blob
  static Future<Uint8List> prepare(Uint8List picked,
      {ImageTranscoder? transcode}) async {
    final clean = await cleanPhoto(picked, transcode: transcode);
    return Isolate.run(() => _render(clean.jpeg));
  }
}

Uint8List _render(Uint8List cleanJpeg) {
  final decoded = img.decodeJpg(cleanJpeg);
  if (decoded == null) {
    throw const UnprocessableImageException('cover source is not a JPEG');
  }
  final sized = resizeLongEdge(decoded, _coverDim)..exif = img.ExifData();
  final jpeg = encodeJpegUnderBudget(
    sized,
    budget: kCoverMaxJpegBytes,
    quality: _coverQuality,
    minQuality: _coverMinQuality,
    minDim: _coverMinDim,
  );
  final clean = JpegSanity.sanitize(jpeg.bytes);
  if (clean == null || clean.bytes.length > kCoverMaxJpegBytes) {
    throw const UnprocessableImageException('cover did not encode cleanly');
  }
  return clean.bytes;
}
