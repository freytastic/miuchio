import 'package:flutter/material.dart';

import 'package:miuchio/domain/account/account_deletion.dart' show TerminalWipe;
import 'package:miuchio/ui/navigation/screen_route.dart';

import 'account_conflict_screens.dart';

// Shared confirmation path for every irreversible local wipe
Future<void> confirmAndEraseInstallation(
  BuildContext context,
  TerminalWipe wipe,
) async {
  final navigator = Navigator.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Erase Miuchio on this phone?'),
      content: const Text(
          'Everything the other account saved on this phone is removed. Their '
          'account isn’t affected. This can’t be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Erase'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;

  // The screen reports wipe failure and owns retry
  await navigator.pushAndRemoveUntil(
    screenRoute<void>(EraseInstallationScreen(wipe: wipe.run)),
    (_) => false,
  );
}
