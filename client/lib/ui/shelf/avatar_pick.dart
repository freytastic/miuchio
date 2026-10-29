import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'package:miuchio/data/native/image_transcoder.dart';
import 'package:miuchio/data/storage/picked_file.dart';
import 'package:miuchio/e2ee/avatar_image.dart';
import 'package:miuchio/ui/shelf/avatar_crop_screen.dart';

// Picks a photo, cleans it of metadata before anything shows it, and lets
// the person square it up. Null when they back out or it cannot be used
Future<Uint8List?> pickAvatarPhoto(
  BuildContext context, {
  ValueChanged<bool>? onPreparing,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
  if (picked == null || !context.mounted) return null;
  onPreparing?.call(true);
  Uint8List? clean;
  try {
    clean = await AvatarImage.prepare(await picked.readAsBytes(),
        transcode: platformImageTranscoder);
  } catch (_) {
    messenger.showSnackBar(const SnackBar(
      content: Text("This photo couldn't be used. Try another one."),
      behavior: SnackBarBehavior.floating,
    ));
  } finally {
    unawaited(pickerCacheRoots()
        .then((roots) => discardPickedFile(picked.path, roots)));
    onPreparing?.call(false);
  }
  if (clean == null || !context.mounted) return null;
  return AvatarCropScreen.show(context, clean);
}
