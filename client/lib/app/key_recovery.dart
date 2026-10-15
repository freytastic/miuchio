import 'dart:async';

// One run per album fetches a missing key for every waiting photo. A report
// during a run queues another pass for epochs still missing
class KeyRecovery {
  final Future<void> Function(String albumId) _catchUp;
  final int Function(String albumId) _generation;
  final void Function(String albumId) _onGaveUp;
  final List<Duration> _delays;

  // albumId -> reported again while the current pass was running
  final Map<String, bool> _running = {};

  KeyRecovery({
    required Future<void> Function(String albumId) catchUp,
    required int Function(String albumId) generation,
    required void Function(String albumId) onGaveUp,
    List<Duration> delays = const [
      Duration(seconds: 5),
      Duration(seconds: 20),
      Duration(minutes: 1),
    ],
  })  : _catchUp = catchUp,
        _generation = generation,
        _onGaveUp = onGaveUp,
        _delays = delays;

  void request(String albumId) {
    if (_running.containsKey(albumId)) {
      _running[albumId] = true;
      return;
    }
    _running[albumId] = false;
    unawaited(_run(albumId));
  }

  Future<void> _run(String albumId) async {
    var failures = 0;
    while (true) {
      _running[albumId] = false;
      final gen = _generation(albumId);
      var ok = true;
      try {
        await _catchUp(albumId);
      } catch (_) {
        ok = false;
      }
      // Done only on a clean pass that installed something. Failed passes
      // and passes that installed nothing count toward the limit, so no
      // report can loop
      if (ok && _generation(albumId) != gen) {
        if (_running[albumId] == true) continue;
        // No await between the check and removal, so no report is lost
        _running.remove(albumId);
        return;
      }
      if (failures == _delays.length) break;
      await Future<void>.delayed(_delays[failures++]);
    }
    _running.remove(albumId);
    _onGaveUp(albumId);
  }
}
