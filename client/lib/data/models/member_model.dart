import 'package:miuchio/data/models/avatar_ref.dart';

class MemberProfile {
  final String? ikPub;
  // Needed by the X3DH responder, null only from very old servers
  final String? lkPub;
  // Sealed under the album MK, null until the member publishes a name
  final String? nameCt;
  final AvatarRef? avatar;

  MemberProfile({this.ikPub, this.lkPub, this.nameCt, this.avatar});

  factory MemberProfile.fromJson(Map<String, dynamic> json) => MemberProfile(
        ikPub: json['ik_pub'] as String?,
        lkPub: json['lk_pub'] as String?,
        nameCt: json['name_ct'] as String?,
        avatar: AvatarRef.tryFromJson(json['avatar']),
      );
}

class AlbumMember {
  final String memberToken;
  final String role;
  final bool revoked;
  final DateTime joinedAt;
  final MemberProfile profile;
  // The membership's join count, a rejoin on the same token raises it
  final int generation;
  // Proved the album key installed, only then can they take the album over
  final bool joined;

  AlbumMember({
    required this.memberToken,
    required this.role,
    required this.revoked,
    required this.joinedAt,
    required this.profile,
    this.generation = 1,
    this.joined = false,
  });

  factory AlbumMember.fromJson(Map<String, dynamic> json) => AlbumMember(
        memberToken: json['member_token'] as String,
        role: json['role'] as String,
        revoked: json['revoked'] as bool? ?? false,
        joinedAt: DateTime.parse(json['joined_at'] as String),
        profile: MemberProfile.fromJson(
            json['profile'] as Map<String, dynamic>? ?? {}),
        generation: (json['generation'] as num?)?.toInt() ?? 1,
        joined: json['joined'] as bool? ?? false,
      );
}
