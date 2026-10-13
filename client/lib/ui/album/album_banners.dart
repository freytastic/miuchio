import 'dart:async';
import 'package:flutter/material.dart';
import 'package:miuchio/data/models/member_model.dart';
import 'package:miuchio/e2ee/epoch_processor.dart';
import 'package:miuchio/e2ee/rotation_recovery.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

class AlbumSyncingBanner extends StatelessWidget {
  const AlbumSyncingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Warm.ground,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.5),
          ),
          const SizedBox(width: 10),
          Text('Getting the album ready…',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Warm.inkSoft)),
        ],
      ),
    );
  }
}

class AlbumStaleBanner extends StatelessWidget {
  final Future<void> Function() onRetry;
  const AlbumStaleBanner({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Warm.ground,
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          const Icon(Icons.cloud_off_outlined, size: 14, color: Warm.inkSoft),
          const SizedBox(width: 8),
          Expanded(
            child: Text('You’re offline. Showing photos saved on this phone.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Warm.inkSoft)),
          ),
          TextButton(
              onPressed: () => onRetry(), child: const Text('Try again')),
        ],
      ),
    );
  }
}

class KeyChangeBanner extends StatelessWidget {
  final List<AlbumMember> members;
  final String Function(AlbumMember) nameOf;
  final void Function(AlbumMember) onTap;

  const KeyChangeBanner({
    super.key,
    required this.members,
    required this.nameOf,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFF87171);
    final names = members.map(nameOf).toList();
    final who = names.length == 1
        ? '${names.first}’s security code changed'
        : '${names.length} people’s security codes changed';
    return InkWell(
      onTap: () => onTap(members.first),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: red.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: red.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 16, color: red),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$who. Check it with them in person.',
                style: const TextStyle(
                    color: Warm.ink, fontSize: 12, height: 1.35),
              ),
            ),
            const Icon(Icons.chevron_right, size: 16, color: Warm.inkFaint),
          ],
        ),
      ),
    );
  }
}

class RotationBanner extends StatelessWidget {
  final RotationStatus status;
  final Future<void> Function() onRetry;

  const RotationBanner(
      {super.key, required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    const amber = Color(0xFFF59E0B);
    final text = switch (status.phase) {
      RotationPhase.rotating => 'Locking out the person who left…',
      RotationPhase.failed =>
        status.failure == RotationFailure.identityUnconfirmed
            ? 'New photos are paused. Miuchio couldn’t confirm someone’s '
                'security code. Check codes with the people in this album, '
                'then try again.'
            : 'New photos are paused. Try again in a moment.',
      _ => 'New photos are paused until the owner opens Miuchio.',
    };
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: amber.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (status.phase == RotationPhase.rotating)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              else
                const Icon(Icons.lock_outline, size: 16, color: amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                      color: Warm.ink, fontSize: 12, height: 1.35),
                ),
              ),
            ],
          ),
          if (status.phase == RotationPhase.failed)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onRetry,
                child: const Text('Try again', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }
}

class KeyBlockBanner extends StatelessWidget {
  final EpochBlocked block;
  final VoidCallback onVerify;
  final VoidCallback onRetry;

  const KeyBlockBanner({
    super.key,
    required this.block,
    required this.onVerify,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    const red = Color(0xFFF87171);
    // Only peer identity failures can be resolved by comparing safety numbers
    final verifiable = block.reason == EpochBlockReason.signerMismatch ||
        block.reason == EpochBlockReason.unknownSigner;
    const text = 'New photos are paused. Something about this album’s '
        'security didn’t check out.';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: red.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.gpp_maybe_outlined, size: 16, color: red),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                      color: Warm.ink, fontSize: 12, height: 1.35),
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: verifiable
                ? TextButton(
                    onPressed: onVerify,
                    child: const Text('Check security codes',
                        style: TextStyle(fontSize: 12)),
                  )
                : TextButton(
                    onPressed: onRetry,
                    child:
                        const Text('Try again', style: TextStyle(fontSize: 12)),
                  ),
          ),
        ],
      ),
    );
  }
}
