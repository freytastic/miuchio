import 'dart:math';

import 'trace.dart';

// Filters log metadata through approved codes, route words, format checks
// and numeric limits before it enters a log entry
abstract class DebugLogAllowlist {
  static const Set<String> _reasons = {
    // FileDecryptError
    'no_mk', 'wrap_auth_failed', 'sha256_mismatch', 'aead_auth_failed',
    'unknown_ver', 'http_failed', 'wrong_size',
    // UploadStageException
    'bad_album_id', 'epoch_replay', 'no_account', 'outbox_write',
    'rotation_pending', 'sealed_missing', 'source_missing', 'transport',
    'undecodable', 'unknown',
    // EpochBlockReason
    'selfSignerMismatch', 'signerMismatch', 'unknownSigner', 'localKeyMissing',
    'replayRejected', 'wrapUnavailable', 'verificationFailed',
    // Server and keystore error codes
    'E_ACCOUNT_DELETING', 'E_ALBUM_FULL', 'E_AUTH', 'E_CONFLICT',
    'E_DELETION_ACCEPTED', 'E_DELETION_PLAN_STALE',
    'E_EPOCH_PENDING_ROTATION', 'E_EPOCH_REPLAY', 'E_FORBIDDEN',
    'E_IDENTITY_ALREADY_SET', 'E_INTERNAL', 'E_INVITE_CONSUMED',
    'E_INVITE_EXPIRED', 'E_KEY_NOT_FOUND', 'E_KEY_TAMPER',
    'E_MANIFEST_TAMPER', 'E_MEMBER_REVOKED', 'E_NATIVE', 'E_NOT_FOUND',
    'E_NOT_IMPLEMENTED', 'E_NOT_MEMBER', 'E_OPK_EXHAUSTED', 'E_RATE_LIMITED',
    'E_SIG_INVALID', 'E_STORE_UNINITIALIZED', 'E_UNAVAILABLE', 'E_UNKNOWN',
    'E_VALIDATION',
    // RealtimeService
    'closed',
  };

  static const Set<String> _stages = {
    'flutter', 'async', 'thumb', 'file', 'confirm',
    'get', 'post', 'put', 'patch', 'delete',
    // UploadPhase
    'queued', 'preparing', 'reserving', 'sendingFile', 'sendingThumb',
    'confirming', 'done', 'failed', 'canceling',
    // AndroidKeystore methods
    'initialize', 'getOnce', 'list', 'putMany', 'wipeAll', 'probe',
  };

  static const Set<String> _routeWords = {
    'abandon',
    'account-deletions',
    'albums',
    'avatar',
    'avatars',
    'by-handle',
    'confirm',
    'count',
    'deletion',
    'download-url',
    'epoch',
    'existing-user',
    'invite',
    'invites',
    'joins',
    'keys',
    'me',
    'media',
    'members',
    'opks',
    'pending',
    'prekey-bundle',
    'profile-ct',
    'spk',
    'upload-url',
    'users',
    'wrap',
    'ws-ticket',
  };

  static final RegExp _http = RegExp(r'^http_[1-5]\d\d$');
  // Exception class names are code identifiers, never user data
  static final RegExp _errorType =
      RegExp(r'^_?[A-Z][A-Za-z0-9]{0,40}(Error|Exception)$');
  static final RegExp _opShape = RegExp(r'^[0-9a-f]{8}\.[0-9]{1,9}$');
  static final RegExp _versionShape = RegExp(r'^[0-9][0-9A-Za-z.+-]{0,23}$');

  // Known codes, http statuses and Trace.reasonOf output, anything else is
  // stored as "other"
  static String? reason(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    if (_reasons.contains(raw) || _http.hasMatch(raw)) return raw;
    final words = Trace.reasonWords.toSet()..add('deadline');
    if (words.contains(raw)) return raw;
    final cut = raw.lastIndexOf('_');
    final type = cut > 0 && words.contains(raw.substring(cut + 1))
        ? raw.substring(0, cut)
        : raw;
    return _errorType.hasMatch(type) ? raw : 'other';
  }

  static String? stage(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return _stages.contains(raw) ? raw : 'other';
  }

  // Any path segment outside the known API words becomes {id}, so IDs,
  // handles and invite codes never survive
  static String? route(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final segments = raw.split('?').first.split('/').where((s) => s.isNotEmpty);
    if (segments.isEmpty) return 'other';
    return segments
        .take(8)
        .map((s) => _routeWords.contains(s) ? '/$s' : '/{id}')
        .join();
  }

  static String? op(String? raw) =>
      raw != null && _opShape.hasMatch(raw) ? raw : null;

  static String? version(String? raw) =>
      raw != null && _versionShape.hasMatch(raw) ? raw : null;

  static int? count(Object? raw) =>
      raw is int && raw >= 0 ? min(raw, 1 << 30) : null;
}
