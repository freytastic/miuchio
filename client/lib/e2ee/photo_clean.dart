import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:miuchio/diagnostics/trace.dart';

import 'jpeg_budget.dart';
import 'jpeg_sanity.dart';

// Every photo is re encoded so EXIF and GPS never upload. The bounded native
// codec runs first, the Dart decoder only when the platform can't read the
// format, and native output is re checked by JpegSanity. Any failure throws
// UnprocessableImageException instead of passing the original bytes through

// Sized for a three column grid while staying below the server limit
const int _thumbMaxDim = 640;
const int _thumbJpegQuality = 82;
// Leaves headroom below the 500 KB thumbnail limit
const int _thumbByteBudget = 420 * 1024;
const int _thumbMinQuality = 60;
const int _thumbMinDim = 320;

// One native decode produces metadata free full and thumbnail JPEGs
class TranscodedPhoto {
  final Uint8List jpeg;
  final Uint8List thumb;
  final int width;
  final int height;
  const TranscodedPhoto({
    required this.jpeg,
    required this.thumb,
    required this.width,
    required this.height,
  });
}

class CleanPhoto {
  final Uint8List jpeg;
  final Uint8List thumb;
  const CleanPhoto({required this.jpeg, required this.thumb});
}

// Rejection must not fall back to the uncapped Dart decoder
sealed class TranscodeOutcome {
  const TranscodeOutcome();
}

class TranscodeDone extends TranscodeOutcome {
  final TranscodedPhoto photo;
  const TranscodeDone(this.photo);
}

// The bridge could not identify the format, so Dart may try
class TranscodeUnavailable extends TranscodeOutcome {
  const TranscodeUnavailable();
}

// The bridge read the header but could not decode safely
class TranscodeRejected extends TranscodeOutcome {
  final String reason;
  const TranscodeRejected(this.reason);
}

// Injected because the Dart fallback isolate has no binary messenger
typedef ImageTranscoder = Future<TranscodeOutcome> Function(Uint8List bytes);

class UnprocessableImageException implements Exception {
  final String message;
  const UnprocessableImageException(this.message);
  @override
  String toString() => 'UnprocessableImageException($message)';
}

Future<CleanPhoto> cleanPhoto(
  Uint8List plaintext, {
  ImageTranscoder? transcode,
  Map<String, Object?> traceFields = const {},
}) async {
  final outcome = transcode == null
      ? const TranscodeUnavailable()
      : await Trace.measure<TranscodeOutcome>(
          'media.imageTranscode',
          () => transcode(plaintext),
          fields: {...traceFields, 'bytes': plaintext.length},
          endFields: (result) => switch (result) {
            TranscodeDone(:final photo) => {
                'transcoded': true,
                'file_bytes': photo.jpeg.length,
                'thumb_bytes': photo.thumb.length,
                'width': photo.width,
                'height': photo.height,
              },
            TranscodeRejected(:final reason) => {
                'transcoded': false,
                'refused': reason,
              },
            TranscodeUnavailable() => {
                'transcoded': false,
                'refused': 'unavailable',
              },
          },
        );

  switch (outcome) {
    case TranscodeDone(:final photo):
      // A worker failure throws here, so the original bytes never upload
      final checked = await _sanitizeInWorker(photo.jpeg, photo.thumb);
      Trace.replay('media.jpegSanitize', checked.fileMs,
          fields: {...traceFields, 'bytes': photo.jpeg.length});
      Trace.replay('media.jpegSanitizeThumb', checked.thumbMs,
          fields: {...traceFields, 'bytes': photo.thumb.length});
      final file = checked.file;
      final thumb = checked.thumb;
      if (file == null || thumb == null) {
        // Log only the marker where validation stopped
        Trace.event('media.imageSanitizeRefused', fields: {
          ...traceFields,
          'file': checked.fileRefusal ?? 'ok',
          'thumb': checked.thumbRefusal ?? 'ok',
        });
        throw const UnprocessableImageException(
            'transcoded photo is not a whole JPEG');
      }
      Trace.event('media.imageSanitize', fields: {
        ...traceFields,
        'stripped': _markerList(file.stripped),
        'thumb_stripped': _markerList(thumb.stripped),
      });
      return CleanPhoto(jpeg: file.bytes, thumb: thumb.bytes);
    case TranscodeRejected(:final reason):
      throw UnprocessableImageException('platform refused it: $reason');
    case TranscodeUnavailable():
      final stripped = await Trace.measure<_StrippedAndThumb?>(
        'media.imageWork',
        () => _stripExifAndThumb(plaintext),
        fields: {...traceFields, 'bytes': plaintext.length},
        endFields: (result) => {'decoded': result != null},
      );
      if (stripped == null) {
        throw const UnprocessableImageException(
            'photo could not be decoded to strip metadata');
      }
      _emitImageSpans(stripped, plaintext.length, traceFields);
      return CleanPhoto(jpeg: stripped.cleanJpeg, thumb: stripped.thumb);
  }
}

class _StrippedAndThumb {
  final Uint8List cleanJpeg;
  final Uint8List thumb;
  final int decodeMs;
  final int encodeMs;
  final int resizeMs;
  final int thumbEncodeMs;
  final int width;
  final int height;
  final int thumbWidth;
  final int thumbHeight;
  final int thumbQuality;

  const _StrippedAndThumb({
    required this.cleanJpeg,
    required this.thumb,
    required this.decodeMs,
    required this.encodeMs,
    required this.resizeMs,
    required this.thumbEncodeMs,
    required this.width,
    required this.height,
    required this.thumbWidth,
    required this.thumbHeight,
    required this.thumbQuality,
  });
}

Future<_StrippedAndThumb?> _stripExifAndThumb(Uint8List bytes) =>
    Isolate.run(() => _stripExifAndThumbSync(bytes));

_StrippedAndThumb? _stripExifAndThumbSync(Uint8List bytes) {
  final watch = Stopwatch()..start();
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } catch (_) {
    // Some decoders throw on malformed input instead of returning null
    decoded = null;
  }
  final decodeMs = watch.elapsedMilliseconds;
  if (decoded == null) return null;

  // package:image writes decoded EXIF back unless it is cleared. XMP and IPTC
  // are dropped by the re encode itself
  decoded.exif = img.ExifData();

  watch.reset();
  final cleanJpeg =
      img.encodeJpg(decoded, quality: 90, chroma: img.JpegChroma.yuv420);
  final encodeMs = watch.elapsedMilliseconds;

  watch.reset();
  final thumbImg = resizeLongEdge(decoded, _thumbMaxDim);
  final resizeMs = watch.elapsedMilliseconds;

  // Default 4:4:4 chroma keeps edge color in small thumbnails
  watch.reset();
  final thumb = _encodeThumbUnderBudget(thumbImg);
  final thumbEncodeMs = watch.elapsedMilliseconds;

  return _StrippedAndThumb(
    cleanJpeg: cleanJpeg,
    thumb: thumb.bytes,
    decodeMs: decodeMs,
    encodeMs: encodeMs,
    resizeMs: resizeMs,
    thumbEncodeMs: thumbEncodeMs,
    width: decoded.width,
    height: decoded.height,
    thumbWidth: thumb.width,
    thumbHeight: thumb.height,
    thumbQuality: thumb.quality,
  );
}

BudgetedJpeg _encodeThumbUnderBudget(img.Image src) => encodeJpegUnderBudget(
      src,
      budget: _thumbByteBudget,
      quality: _thumbJpegQuality,
      minQuality: _thumbMinQuality,
      minDim: _thumbMinDim,
    );

// Replays isolate timings on the caller trace
void _emitImageSpans(
    _StrippedAndThumb work, int inputBytes, Map<String, Object?> fields) {
  if (!Trace.enabled) return;
  Trace.replay('media.imageDecode', work.decodeMs,
      fields: {...fields, 'bytes': inputBytes},
      endFields: {'decoded': true, 'width': work.width, 'height': work.height});
  Trace.replay('media.imageEncode', work.encodeMs,
      fields: fields,
      endFields: {'bytes': work.cleanJpeg.length, 'quality': 90});
  Trace.replay('media.thumbResize', work.resizeMs,
      fields: fields,
      endFields: {'width': work.thumbWidth, 'height': work.thumbHeight});
  Trace.replay('media.thumbEncode', work.thumbEncodeMs,
      fields: fields,
      endFields: {'bytes': work.thumb.length, 'quality': work.thumbQuality});
}

String _markerList(List<int> markers) => markers.isEmpty
    ? 'none'
    : markers.map((m) => '0x${m.toRadixString(16)}').join(',');

typedef _Sanitized = ({
  SanitizedJpeg? file,
  SanitizedJpeg? thumb,
  String? fileRefusal,
  String? thumbRefusal,
  int fileMs,
  int thumbMs,
});

// Separate from cleanPhoto so the worker captures only these two buffers
Future<_Sanitized> _sanitizeInWorker(Uint8List jpeg, Uint8List thumb) =>
    Isolate.run(() => _sanitizeBoth(jpeg, thumb));

_Sanitized _sanitizeBoth(Uint8List jpeg, Uint8List thumbJpeg) {
  final watch = Stopwatch()..start();
  final file = JpegSanity.sanitize(jpeg);
  final fileMs = watch.elapsedMilliseconds;
  watch.reset();
  final thumb = JpegSanity.sanitize(thumbJpeg);
  return (
    file: file,
    thumb: thumb,
    fileRefusal: file == null ? JpegSanity.describe(jpeg) : null,
    thumbRefusal: thumb == null ? JpegSanity.describe(thumbJpeg) : null,
    fileMs: fileMs,
    thumbMs: watch.elapsedMilliseconds,
  );
}
