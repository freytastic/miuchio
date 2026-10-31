import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:miuchio/crypto/uuid_bytes.dart';
import 'package:miuchio/data/api/album_api.dart';
import 'package:miuchio/data/models/album_model.dart';
import 'package:miuchio/e2ee/identity.dart';
import 'package:miuchio/e2ee/identity_trust.dart';
import 'package:miuchio/e2ee/invite.dart';
import 'package:miuchio/ui/album/add_people_sheet.dart';
import 'package:miuchio/ui/album/album_copy.dart';
import 'package:miuchio/ui/album/member_avatars.dart';
import 'package:miuchio/ui/people/people_screen.dart';
import 'package:miuchio/ui/providers/app_state.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';
import 'package:miuchio/ui/widgets/member_face.dart';
import 'package:miuchio/ui/widgets/safety_number_sheet.dart';
import 'package:miuchio/ui/navigation/screen_route.dart';

// One album's people. Safety numbers are per album, so everything here, from
// the roster to the digits and the verification, uses this one album
class _Roster {
  final AppState state;
  final IdentityTrust trust;
  final IdentityService identity;
  final AlbumService svc;
  final AlbumModel album;

  final Map<String, ({Uint8List ik, TrustState trust})> peers = {};
  final List<AvatarMember> avatars = [];

  _Roster(BuildContext context, this.album, {AlbumService? service})
      : state = context.read<AppState>(),
        trust = context.read<IdentityTrust>(),
        identity = context.read<IdentityService>(),
        svc = service ?? AlbumService();

  // Runs the same reconcile the album runs on open, so a changed key alarms
  // here too
  Future<List<PersonEntry>> load() async {
    peers.clear();
    avatars.clear();
    final albumBytes = uuidToBytes(album.id);
    if (albumBytes == null) return const [];
    final mine = base64.encode(await identity.currentIkPub());
    final invites = <PersonEntry>[];
    final roster = <PeerIdentity>[];
    for (final m in await svc.listMembers(album.id)) {
      if (m.revoked) continue;
      final self = m.memberToken == album.memberToken;
      final pending = m.profile.nameCt == null && !self;
      avatars.add(AvatarMember(
        token: m.memberToken,
        name: state.memberDisplayName(album.id, m.memberToken),
        pending: pending,
        self: self,
      ));
      if (self) continue;
      if (pending) {
        invites.add(PersonEntry(
          id: 'invite-${m.memberToken}',
          name: AlbumCopy.invitedShort,
          face: const SizedBox(),
          invited: true,
          detail: "Hasn't joined yet",
        ));
        continue;
      }
      final ik = m.profile.ikPub;
      if (ik == null || ik.isEmpty) continue;
      final bytes = base64.decode(base64.normalize(ik));
      if (bytes.length != 32) continue;
      roster.add(PeerIdentity(memberToken: m.memberToken, ikPub: bytes));
    }
    final states = roster.isEmpty
        ? const <String, TrustState>{}
        : await trust.reconcile(albumBytes, roster,
            myMemberToken: album.memberToken);
    return [
      for (final p in roster)
        if (states[p.memberToken] ?? TrustState.unverified case final s
            // A stranger's row carrying our key only matters as an alarm
            when base64.encode(p.ikPub) != mine || s == TrustState.changed)
          _entry(p, s),
      ...invites,
    ];
  }

  PersonEntry _entry(PeerIdentity p, TrustState s) {
    peers[p.memberToken] = (ik: p.ikPub, trust: s);
    final name = state.memberDisplayName(album.id, p.memberToken);
    return PersonEntry(
      id: p.memberToken,
      name: name ?? AlbumCopy.unknownMember,
      face: _face(album.id, p.memberToken, name, 40),
      trust: s,
    );
  }

  Future<void> open(BuildContext context, PersonEntry entry) async {
    final peer = peers[entry.id];
    final albumBytes = uuidToBytes(album.id);
    if (peer == null || albumBytes == null) return;
    final digits =
        await trust.safetyNumber(albumId: albumBytes, peerIkPub: peer.ik);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Warm.ground,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (_) => SafetyNumberSheet(
        displayName: entry.name,
        digits: digits,
        state: peer.trust,
        albumName: state.albumDisplayName(album.id) ?? 'this album',
        face: _face(album.id, entry.id,
            state.memberDisplayName(album.id, entry.id), 46),
        // Bound to the key on screen, even if the roster moves meanwhile
        onVerify: () => trust.markVerified(
            albumId: albumBytes, memberToken: entry.id, peerIkPub: peer.ik),
      ),
    );
  }
}

// The album's people and their security codes, from the album's header or
// the shelf menu
Future<void> openAlbumPeople(BuildContext context, AlbumModel album,
    {AlbumService? service}) async {
  final state = context.read<AppState>();
  final roster = _Roster(context, album, service: service);
  final title = state.albumDisplayName(album.id) ?? 'This album';

  Future<void> add() async {
    final albumBytes = uuidToBytes(album.id);
    if (albumBytes == null) return;
    final initiator = context.read<InviteInitiator>();
    await AddPeopleSheet.show(
      context,
      albumId: album.id,
      albumTitle: title,
      members: [
        for (final a in roster.avatars)
          if (!a.pending) a
      ],
      myMiuchioId: state.miuchioId,
      onInvite: (miuchioId) => initiator.inviteExistingUser(
          miuchioId: miuchioId, albumId: albumBytes),
    );
  }

  final admin = state.isAdminOf(album.id);
  await Navigator.of(context).push(screenRoute<void>(
    PeopleScreen(
      title: AlbumCopy.people,
      subtitle: title,
      intro: AlbumCopy.peopleIntro,
      load: roster.load,
      onOpen: (e) => roster.open(context, e),
      onAdd: admin ? add : null,
      note: admin ? null : 'Only the owner can add people.',
    ),
  ));
}

// Albums where someone's code changed, each needing its own comparison
Future<List<AlbumModel>> albumsToCheck(BuildContext context,
    {AlbumService? service}) async {
  final rosters = [
    for (final a in context.read<AppState>().albums)
      _Roster(context, a, service: service)
  ];
  final out = <AlbumModel>[];
  for (final r in rosters) {
    try {
      final people = await r.load();
      if (people.any((p) => p.trust == TrustState.changed)) out.add(r.album);
    } catch (_) {
      // One album failing to load must not hide the others
    }
  }
  return out;
}

Widget _face(String albumId, String token, String? name, double size) =>
    MemberFace(
      albumId: albumId,
      token: token,
      name: name,
      size: size,
      style: Warm.acFace.copyWith(fontSize: size * 0.36),
    );
