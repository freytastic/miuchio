import 'package:flutter/material.dart';
import 'package:miuchio/ui/providers/upload_queue_model.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/pressable_scale.dart';
import 'package:provider/provider.dart';

import 'upload_sheet.dart';

// Keeps app scoped uploads reachable outside the album screen
class UploadPill extends StatelessWidget {
  // The open album's hooks, offered only for that album's own batch so a
  // replacement pick can never land in another album
  final String? albumId;
  final VoidCallback? onPickMore;
  final Future<void> Function(String batchId)? onDismiss;

  const UploadPill({super.key, this.albumId, this.onPickMore, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final model = context.watch<UploadQueueModel>();
    // Failed batches stay reachable for retry or removal
    final live = model.state.batches
        .where((b) => !b.settled || b.failedCount > 0)
        .toList();
    if (live.isEmpty) return const SizedBox.shrink();
    final batch = live.last;
    final failed = batch.settled;
    final here = albumId != null && batch.albumId == albumId;

    return Semantics(
      button: true,
      label: 'Upload details',
      child: PressableScale(
        onTap: () => UploadSheet.show(context,
            batchId: batch.batchId,
            onPickMore: here ? onPickMore : null,
            onDismiss: here ? onDismiss : null),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
          decoration: BoxDecoration(
            color: Warm.paper,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Warm.shadow(0.10), blurRadius: 12)],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (failed)
                const Icon(Icons.error_outline, size: 16, color: Warm.warn)
              else
                SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    value: batch.fraction <= 0 ? null : batch.fraction,
                    strokeWidth: 2,
                    backgroundColor: Warm.wellEmpty,
                    valueColor: const AlwaysStoppedAnimation<Color>(Warm.cta),
                  ),
                ),
              const SizedBox(width: 9),
              Text(
                failed
                    ? '${batch.failedCount} didn’t send'
                    : '${batch.doneCount + batch.failedCount + 1}'
                        '/${batch.totalCount}',
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Warm.ink,
                    fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
