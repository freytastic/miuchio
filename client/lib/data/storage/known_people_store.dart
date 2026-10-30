import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/wire_format.dart';

// Someone this phone invited: the Miuchio ID typed for them, the identity
// key it resolved to, and the album place it was pinned at, so their name
// and face can be found again in any album they joined
class KnownPerson {
  final String handle;
  final String ikPub;
  final String albumId;
  final String memberToken;
  final DateTime invitedAt;

  const KnownPerson({
    required this.handle,
    required this.ikPub,
    required this.albumId,
    required this.memberToken,
    required this.invitedAt,
  });

  Map<String, dynamic> toJson() => {
        'h': handle,
        'k': ikPub,
        'a': albumId,
        't': memberToken,
        'at': invitedAt.millisecondsSinceEpoch,
      };

  static KnownPerson? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      return KnownPerson(
        handle: raw['h'] as String,
        ikPub: raw['k'] as String,
        albumId: raw['a'] as String,
        memberToken: raw['t'] as String,
        invitedAt:
            DateTime.fromMillisecondsSinceEpoch((raw['at'] as num).toInt()),
      );
    } catch (_) {
      return null;
    }
  }
}

// The Miuchio IDs this phone has invited, sealed under the device cache key.
// The server never learns this list, and other members never see it
class KnownPeopleStore extends ChangeNotifier {
  final File _file;
  final Uint8List _cacheKey;
  // Keyed by identity key, so one person is one entry however often invited
  final Map<String, KnownPerson> _people = {};
  Future<void> _inFlight = Future.value();

  static final Uint8List _aad =
      Uint8List.fromList('miuchio.known-people-v1'.codeUnits);

  KnownPeopleStore._(this._file, this._cacheKey);

  static Future<KnownPeopleStore> open({
    File? file,
    required Uint8List cacheRootKey,
  }) async {
    final f = file ??
        File(p.join((await getApplicationSupportDirectory()).path,
            'miuchio_known_people.kec'));
    final s = KnownPeopleStore._(f, cacheRootKey);
    await s._load();
    return s;
  }

  // Most recently invited first
  List<KnownPerson> get people => _people.values.toList()
    ..sort((a, b) => b.invitedAt.compareTo(a.invitedAt));

  Future<void> remember({
    required String handle,
    required Uint8List ikPub,
    required String albumId,
    required String memberToken,
    DateTime? at,
  }) {
    final ik = base64.encode(ikPub);
    _people[ik] = KnownPerson(
      handle: handle,
      ikPub: ik,
      albumId: albumId,
      memberToken: memberToken,
      invitedAt: at ?? DateTime.now(),
    );
    notifyListeners();
    return _flush();
  }

  Future<void> clear() async {
    _people.clear();
    notifyListeners();
    await _inFlight;
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }

  Future<void> _load() async {
    try {
      if (!await _file.exists()) return;
      final wire = await _file.readAsBytes();
      final pt = await Aead.decrypt(wire: wire, key: _cacheKey, aad: _aad);
      final list = jsonDecode(utf8.decode(pt)) as List<dynamic>;
      for (final raw in list) {
        final person = KnownPerson.tryFromJson(raw);
        if (person != null) _people[person.ikPub] = person;
      }
    } catch (_) {
      // Missing, corrupt or another key, start empty
      _people.clear();
    }
  }

  Future<void> _flush() {
    _inFlight = _inFlight.then((_) => _write());
    return _inFlight;
  }

  Future<void> _write() async {
    try {
      final pt = Uint8List.fromList(utf8.encode(
          jsonEncode([for (final person in _people.values) person.toJson()])));
      final sealed = await Aead.encrypt(
          version: kVerAesGcm, key: _cacheKey, plaintext: pt, aad: _aad);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsBytes(sealed, flush: true);
      await tmp.rename(_file.path);
    } catch (_) {
      // The list only saves typing; a failed write costs one retype
    }
  }
}
