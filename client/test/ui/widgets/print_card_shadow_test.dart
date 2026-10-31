import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/print_card.dart';

void main() {
  // The onboarding motion waits on this, a bake that never ends would stall it
  testWidgets('warming a print shadow completes, and again from the cache',
      (tester) async {
    const size = Size(220, 273);
    await tester.runAsync(() async {
      await PrintCard.warmShadow(Warm.printShadow, size, 2)
          .timeout(const Duration(seconds: 5));
      await PrintCard.warmShadow(Warm.printShadow, size, 2)
          .timeout(const Duration(milliseconds: 100));
    });
  });
}
