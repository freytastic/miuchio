import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:miuchio/domain/upload/upload_item.dart';
import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:provider/provider.dart';

typedef _Look = ({
  UploadPhase phase,
  int percent,
  bool retryable,
  Uint8List? preview,
});

class UploadTile extends StatelessWidget {
  final String itemId;
  final VoidCallback? onRetry;

  const UploadTile({
    super.key,
    required this.itemId,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    // Every snapshot recreates its items, so compare values not objects
    final look = context.select<UploadQueueModel, _Look?>((model) {
      final item = model.item(itemId);
      if (item == null) return null;
      return (
        phase: item.phase,
        percent:
            item.fraction <= 0 ? 0 : math.max(1, (item.fraction * 100).round()),
        retryable: item.failure?.retryable ?? false,
        preview: model.preview(item.mediaId),
      );
    });
    if (look == null) return const ColoredBox(color: Warm.wellEmpty);
    final failed = look.phase == UploadPhase.failed;
    // Undecodable bytes are not retryable
    final canRetry = failed && look.retryable;
    return GestureDetector(
      onTap: canRetry ? onRetry : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(color: Warm.wellEmpty),
          Opacity(opacity: failed ? 0.35 : 0.62, child: _image(look.preview)),
          if (failed)
            Center(
              child: Icon(
                canRetry ? Icons.refresh_rounded : Icons.block_outlined,
                size: 22,
                color: Warm.ink,
              ),
            )
          else
            Positioned(
              right: 5,
              bottom: 5,
              child: _Ring(value: look.percent / 100),
            ),
        ],
      ),
    );
  }

  // Never decode the original camera file for a pending tile
  Widget _image(Uint8List? preview) {
    if (preview == null) return const SizedBox.shrink();
    return Image.memory(preview, fit: BoxFit.cover, gaplessPlayback: true);
  }
}

class _Ring extends StatelessWidget {
  final double value;
  const _Ring({required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: Warm.shadow(0.35), blurRadius: 2)],
        ),
        child: CircularProgressIndicator(
          value: value <= 0 ? null : value,
          strokeWidth: 2.4,
          backgroundColor: Colors.white24,
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
        ),
      ),
    );
  }
}
