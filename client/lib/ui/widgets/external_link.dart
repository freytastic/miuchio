import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const kSiteUrl = 'https://www.miuchio.com';

// Copies the link when no app can open it
Future<void> openExternalLink(BuildContext context, String url) async {
  HapticFeedback.selectionClick();
  final uri = Uri.tryParse(url);
  if (uri != null) {
    try {
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
    } catch (_) {}
  }
  if (!context.mounted) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
    const SnackBar(
      content: Text('Link copied'),
      duration: Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
