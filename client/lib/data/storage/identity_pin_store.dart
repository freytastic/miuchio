import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:miuchio/crypto/primitives.dart';
import 'package:miuchio/crypto/wire_format.dart';

class AuthorityNotSaved implements Exception {
  const AuthorityNotSaved();
}

// Keeps roster and signer trust separate and sealed under the device cache key
// Trust survives logout so substituted keys cannot become a new first sight
class IdentityPinStore {
  final File _file;
  final Uint8List _cacheKey;
  final Map<String, String> _pins = {}; // 'albumId:token' -> base64 ik_pub
  final Map<String, int> _verified = {}; // 'b64(myIk)|b64(peerIk)' -> unix s
  // Epoch signing authority, deliberately separate from roster pins. Written
  // only after a first join signature verifies or an out of band comparison
  final Map<String, String> _signers = {}; // 'albumId:token' -> base64 ik_pub
  // Albums created here whose epoch 0 has not installed. Until then only this
  // device may sign: the marker is flushed immediately to narrow the crash
  // window between album creation and bootstrap
  final Set<String> _creating = {};
  // albumId -> the admin keys this device trusts, as JSON. Where an album's
  // signing authority starts, so it shares the fate of the signer bindings
  final Map<String, String> _authority = {};
  Timer? _flushTimer;
  int _gen = 0;
  Future<void> _inFlight = Future.value();

  static final Uint8List _aad =
      Uint8List.fromList('miuchio.identity-pins-v1'.codeUnits);

  IdentityPinStore._(this._file, this._cacheKey);

  static Future<IdentityPinStore> open({
    File? file,
    required Uint8List cacheRootKey,
  }) async {
    final f = file ??
        File(p.join(
            (await getApplicationSupportDirectory()).path, 'miuchio_pins.kec'));
    final s = IdentityPinStore._(f, cacheRootKey);
    await s._load();
    return s;
  }

  Uint8List? pinnedIk(String albumId, String memberToken) {
    final b64 = _pins[_pinKey(albumId, memberToken)];
    return b64 == null ? null : base64.decode(b64);
  }

  Uint8List? signerIk(String albumId, String memberToken) {
    final b64 = _signers[_pinKey(albumId, memberToken)];
    return b64 == null ? null : base64.decode(b64);
  }

  void pinSigner(String albumId, String memberToken, Uint8List ikPub) {
    final k = _pinKey(albumId, memberToken);
    final v = base64.encode(ikPub);
    if (_signers[k] == v) return;
    _signers[k] = v;
    _scheduleFlush();
  }

  // Only what reached disk, so a failed save never authorizes a key install
  // While a save is in flight readers keep the value saved before it
  String? authority(String albumId) => _savingAuthority.containsKey(albumId)
      ? _savingAuthority[albumId]
      : _authority[albumId];

  // Last value known on disk, held while a save of a newer one is in flight
  final Map<String, String?> _savingAuthority = {};
  final Map<String, Future<void>> _authorityQueue = {};

  // Durable before returning: keys must never install without their anchor
  // Saves of one album run one at a time, so a failure rolls back to the last
  // value that reached disk and never to one from before an earlier success
  Future<void> saveAuthority(String albumId, String json) {
    final run = (_authorityQueue[albumId] ?? Future<void>.value())
        .then((_) => _saveAuthority(albumId, json));
    final tail = run.then<void>((_) {}, onError: (_) {});
    _authorityQueue[albumId] = tail;
    tail.then((_) {
      if (identical(_authorityQueue[albumId], tail)) {
        _authorityQueue.remove(albumId);
      }
    });
    return run;
  }

  Future<void> _saveAuthority(String albumId, String json) async {
    if (_authority[albumId] == json) return;
    final saved = _authority[albumId];
    _savingAuthority[albumId] = saved;
    _authority[albumId] = json;
    try {
      await flush();
      if (!_writeFailed) return;
      // A wipe of the album meanwhile already dropped both values
      if (!_savingAuthority.containsKey(albumId)) {
        throw const AuthorityNotSaved();
      }
      if (saved == null) {
        _authority.remove(albumId);
      } else {
        _authority[albumId] = saved;
      }
      throw const AuthorityNotSaved();
    } finally {
      _savingAuthority.remove(albumId);
    }
  }

  bool isCreating(String albumId) => _creating.contains(albumId);

  // Exposed for boot time cleanup of markers left after epoch 0 installed
  List<String> get creatingAlbums => _creating.toList();

  // Bypass the debounce so successful writes survive a crash during bootstrap
  Future<void> markCreating(String albumId) async {
    if (!_creating.add(albumId)) return;
    await flush();
  }

  Future<void> clearCreating(String albumId) async {
    if (!_creating.remove(albumId)) return;
    await flush();
  }

  void pin(String albumId, String memberToken, Uint8List ikPub) {
    final k = _pinKey(albumId, memberToken);
    final v = base64.encode(ikPub);
    if (_pins[k] == v) return;
    _pins[k] = v;
    _scheduleFlush();
  }

  bool isVerified({required Uint8List myIkPub, required Uint8List peerIkPub}) =>
      _verified.containsKey(_vKey(myIkPub, peerIkPub));

  void markVerified(
      {required Uint8List myIkPub,
      required Uint8List peerIkPub,
      DateTime? at}) {
    final k = _vKey(myIkPub, peerIkPub);
    if (_verified.containsKey(k)) return;
    _verified[k] = (at ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    _scheduleFlush();
  }

  DateTime? verifiedAt(
      {required Uint8List myIkPub, required Uint8List peerIkPub}) {
    final s = _verified[_vKey(myIkPub, peerIkPub)];
    return s == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(s * 1000, isUtc: true);
  }

  // Revoke, leave, or delete: drop album scoped roster pins, signer bindings,
  // and creator state. Verification claims remain because they are not scoped
  // to an album
  Future<void> clearAlbum(String albumId) async {
    final prefix = '$albumId:';
    final before =
        _pins.length + _signers.length + _creating.length + _authority.length;
    _pins.removeWhere((k, _) => k.startsWith(prefix));
    _signers.removeWhere((k, _) => k.startsWith(prefix));
    _creating.remove(albumId);
    _authority.remove(albumId);
    _savingAuthority.remove(albumId);
    // A failed earlier write may still hold these pins on disk
    if (_pins.length + _signers.length + _creating.length + _authority.length ==
            before &&
        !_writeFailed) {
      return;
    }
    _gen++;
    _flushTimer?.cancel();
    try {
      await _inFlight;
    } catch (_) {}
    await flush();
  }

  // Full account reset only : NOT called on a normal logout (see class note)
  Future<void> clear() async {
    _gen++;
    _flushTimer?.cancel();
    _pins.clear();
    _verified.clear();
    _signers.clear();
    _creating.clear();
    _authority.clear();
    _savingAuthority.clear();
    try {
      await _inFlight;
    } catch (_) {}
    await _delete(_file);
    await _delete(File('${_file.path}.tmp'));
  }

  Future<void> _load() async {
    try {
      if (!await _file.exists()) return;
      final wire = await _file.readAsBytes();
      final pt = await Aead.decrypt(wire: wire, key: _cacheKey, aad: _aad);
      final map = jsonDecode(utf8.decode(pt)) as Map<String, dynamic>;
      _pins.clear();
      _verified.clear();
      _signers.clear();
      _creating.clear();
      _authority.clear();
      (map['a'] as Map<String, dynamic>? ?? {})
          .forEach((k, v) => _authority[k] = v as String);
      (map['p'] as Map<String, dynamic>? ?? {})
          .forEach((k, v) => _pins[k] = v as String);
      (map['v'] as Map<String, dynamic>? ?? {})
          .forEach((k, v) => _verified[k] = v as int);
      (map['s'] as Map<String, dynamic>? ?? {})
          .forEach((k, v) => _signers[k] = v as String);
      for (final a in (map['c'] as List<dynamic>? ?? const [])) {
        _creating.add(a as String);
      }
    } catch (_) {
      // Missing, corrupt, or wrong key state is not trustworthy. Peer signed
      // updates on established albums fail closed without a signer binding: a
      // genuine first join may establish TOFU. Nothing is treated as verified
      _pins.clear();
      _verified.clear();
      _signers.clear();
      _creating.clear();
      _authority.clear();
    }
  }

  bool _writeFailed = false;
  // Display tolerates a failed flush; verification must not claim persistence
  bool get lastWriteFailed => _writeFailed;

  // Album removal treats a failed write as pins possibly still on disk
  bool holdsAlbum(String albumId) {
    final prefix = '$albumId:';
    return _writeFailed ||
        _creating.contains(albumId) ||
        _authority.containsKey(albumId) ||
        _pins.keys.any((k) => k.startsWith(prefix)) ||
        _signers.keys.any((k) => k.startsWith(prefix));
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(flush());
    });
  }

  Future<void> flush() {
    _flushTimer?.cancel();
    final gen = _gen;
    _inFlight = _inFlight.then((_) => _write(gen));
    return _inFlight;
  }

  Future<void> _write(int gen) async {
    if (gen != _gen) return;
    try {
      final pt = Uint8List.fromList(utf8.encode(jsonEncode({
        'p': _pins,
        'v': _verified,
        's': _signers,
        'c': _creating.toList(),
        'a': _authority,
      })));
      final sealed = await Aead.encrypt(
          version: kVerAesGcm, key: _cacheKey, plaintext: pt, aad: _aad);
      if (gen != _gen) return;
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsBytes(sealed, flush: true);
      if (gen != _gen) {
        await _delete(tmp);
        return;
      }
      await tmp.rename(_file.path);
      _writeFailed = false;
    } catch (_) {
      // Keep the last durable snapshot: in memory updates may be lost on restart
      _writeFailed = true;
    }
  }

  Future<void> _delete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static String _pinKey(String albumId, String memberToken) =>
      '$albumId:$memberToken';

  static String _vKey(Uint8List myIkPub, Uint8List peerIkPub) =>
      '${base64.encode(myIkPub)}|${base64.encode(peerIkPub)}';
}
