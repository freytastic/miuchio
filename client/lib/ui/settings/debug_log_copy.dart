import 'package:miuchio/diagnostics/debug_log.dart';

abstract class DebugLogCopy {
  static const String title = 'Debug log';
  static const String lead =
      'Errors and events from this phone. Nothing leaves unless you share it.';
  static const String all = 'All';
  static const String problems = 'Problems';
  static const String empty = 'No entries';
  static const String problemsEmpty = 'No problems';
  static const String shareLog = 'Share log';
  static const String send = 'Send to Miuchio';
  static const String soon = 'Soon';
  static const String clear = 'Clear log';
  static const String clearTitle = 'Clear log?';
  static const String clearBody = 'All entries will be deleted.';
  static const String clearCancel = 'Cancel';
  static const String limits =
      'Last 7 days, up to 500 entries. No photos, names, emails or IDs.';

  static const String previewTitle = 'Share log';
  static const String previewLead =
      'This is the exact text that will be shared.';
  static const String previewNoContent = 'No photos, names, emails or IDs';
  static const String previewIncludes =
      'Includes timestamps, app version and phone model';
  static const String share = 'Share';
  static const String copy = 'Copy';
  static const String copied = 'Copied';
  static const String shareSubject = 'Miuchio debug log';

  static String headline(DebugEntry e) => switch (e.event) {
        DebugEvent.appStart => 'App started',
        DebugEvent.appError => 'App error',
        DebugEvent.uploadQueued => 'Photo queued',
        DebugEvent.uploadRetrying => 'Upload retried',
        DebugEvent.uploadPaused => 'Uploads paused for a key update',
        DebugEvent.uploadRecovered => 'Upload succeeded after retry',
        DebugEvent.uploadFailed => 'Upload failed',
        DebugEvent.downloadFailed => e.stage == 'thumb'
            ? 'Preview failed to load'
            : 'Photo failed to load',
        DebugEvent.requestFailed => 'Server request failed',
        DebugEvent.liveConnected => 'Live updates connected',
        DebugEvent.liveDropped => 'Live updates disconnected',
        DebugEvent.keystoreFailed => 'Secure storage error',
        DebugEvent.albumBlocked => 'Album update blocked by a security check',
      };

  // Names a cause only when the recorded reason actually establishes it
  static String? cause(DebugEntry e) {
    final r = e.reason;
    if (r == null) return null;
    bool has(String w) => r == w || r.endsWith('_$w');
    if (['peerreset', 'halfopen', 'abort', 'brokenpipe'].any(has)) {
      return 'Connection dropped';
    }
    if (['dns', 'unreachable', 'noroute'].any(has)) {
      return 'No internet connection';
    }
    if (has('refused')) return 'Server refused the connection';
    // Deadline can be a local timeout, so the server is not named
    if (['conntimeout', 'optimeout', 'deadline'].any(has)) return 'Timed out';
    final status = RegExp(r'^http_(5\d{2})$').firstMatch(r)?.group(1);
    if (status != null) return 'Server error $status';
    return switch (r) {
      'aead_auth_failed' ||
      'sha256_mismatch' ||
      'wrap_auth_failed' =>
        'Integrity check failed',
      'no_mk' => 'Missing album key',
      'wrong_size' => 'Incomplete download',
      'rotation_pending' => 'Album key update in progress',
      'epoch_replay' => 'Album key changed during upload',
      'localKeyMissing' => 'Key missing on this phone',
      'E_KEY_TAMPER' => 'Stored key failed tamper check',
      _ => null,
    };
  }

  static String times(int n) => '$n times';
}
