import 'package:miuchio/e2ee/identity_trust.dart';

// An album's verification at a glance. Counts only people whose code can be
// compared: never yourself, never an invite, which has no key yet
class TrustSummary {
  final int verified;
  final int total;
  // Names of people whose code changed, which outranks any count
  final List<String> changed;

  const TrustSummary({
    required this.verified,
    required this.total,
    this.changed = const [],
  });

  factory TrustSummary.of(Iterable<({String name, TrustState trust})> people) {
    var verified = 0;
    var total = 0;
    final changed = <String>[];
    for (final p in people) {
      total++;
      switch (p.trust) {
        case TrustState.verified:
          verified++;
        case TrustState.changed:
          changed.add(p.name);
        case TrustState.unverified:
          break;
      }
    }
    return TrustSummary(verified: verified, total: total, changed: changed);
  }

  bool get isEmpty => total == 0;
  bool get alarm => changed.isNotEmpty;
  // Only when every comparable person is verified and nothing changed
  bool get allVerified => !alarm && total > 0 && verified == total;

  // The count alone, or the alarm in its place
  String get status {
    if (changed.length == 1) return "${changed.first}'s security code changed";
    if (changed.length > 1) return '${changed.length} security codes changed';
    return '$verified of $total verified';
  }

  // The album header's line: quiet until someone has been compared
  String get label => alarm || verified > 0 ? status : 'Security codes';
}
