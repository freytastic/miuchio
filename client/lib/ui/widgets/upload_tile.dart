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
          if (failed) ...[
            Opacity(opacity: 0.35, child: _image(look.preview)),
            Center(
              child: Icon(
                canRetry ? Icons.refresh_rounded : Icons.block_outlined,
                size: 22,
                color: Warm.ink,
              ),
            ),
          ] else ...[
            _image(look.preview),
            _Develop(value: look.percent / 100),
          ],
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

// The photo develops out of milk as its bytes are sent, with a thin line
// filling along the bottom, and without blur or desaturation since each costs
// a layer per tile
class _Develop extends StatelessWidget {
  final double value;
  const _Develop({required this.value});

  static const _milk = Color(0xFFF3EFE8);

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: value),
      duration: const Duration(milliseconds: 100),
      builder: (context, f, _) => Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: _milk.withValues(alpha: 0.78 * (1 - f))),
          Align(
            alignment: Alignment.bottomLeft,
            child: FractionallySizedBox(
              widthFactor: f,
              child: const SizedBox(
                height: 2,
                child: ColoredBox(color: Warm.cocoa),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
