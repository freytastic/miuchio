import 'dart:typed_data';

import 'package:miuchio/e2ee/album_authority.dart';
import 'package:miuchio/e2ee/expected_ik_resolver.dart';
import 'package:miuchio/e2ee/identity.dart';

// Who a rotation wraps the new key for, and under which identity key. Both
// come from notes an admin this device trusts signed, never from the roster
// the server lists, so a member the server made up is never handed a key
class RotationRoster {
  final AlbumAuthority _authority;
  final IdentityService _identity;
  final SelfTokenLookup _selfToken;
  final Map<String, Map<String, MemberKeys>> _verified = {};

  RotationRoster({
    required AlbumAuthority authority,
    required IdentityService identity,
    required SelfTokenLookup selfToken,
  })  : _authority = authority,
        _identity = identity,
        _selfToken = selfToken;

  // Refetched per rotation. A member whose note does not verify stays in the
  // list so expectedIk refuses the whole rotation instead of dropping them
  Future<List<Uint8List>> activeTokens(Uint8List albumId) async {
    final roster = await _authority.verifiedRoster(albumId);
    _verified[AlbumAuthority.tokenHex(albumId)] = roster.members;
    return [
      for (final hex in [...roster.members.keys, ...roster.unverified])
        _unhex(hex),
    ];
  }

  Future<Uint8List> expectedIk(Uint8List albumId, Uint8List memberToken) async {
    final self = _selfToken(albumId);
    if (self != null && _eq(self, memberToken)) return _identity.currentIkPub();
    final keys = _verified[AlbumAuthority.tokenHex(albumId)]
        ?[AlbumAuthority.tokenHex(memberToken)];
    if (keys == null) throw MissingIdentityPinException(memberToken);
    return keys.ikPub;
  }

  static Uint8List _unhex(String s) => Uint8List.fromList([
        for (var i = 0; i < s.length; i += 2)
          int.parse(s.substring(i, i + 2), radix: 16),
      ]);

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
