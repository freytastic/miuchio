import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:miuchio/app/key_recovery.dart';

const _album = 'a1';

class _Harness {
  int gen = 0;
  int passes = 0;
  final List<String> gaveUp = [];
  // Each pass runs the next step, the last one repeats
  final List<Future<void> Function()> steps;
  late final KeyRecovery recovery = KeyRecovery(
    catchUp: (_) {
      final step = steps[passes < steps.length ? passes : steps.length - 1];
      passes++;
      return step();
    },
    generation: (_) => gen,
    onGaveUp: gaveUp.add,
    delays: const [Duration.zero, Duration.zero, Duration.zero],
  );
  _Harness(this.steps);
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('a pass that installs one epoch then fails still retries', () async {
    late _Harness h;
    h = _Harness([
      () async {
        h.gen++;
        throw StateError('epoch 1 fetch failed');
      },
      () async => h.gen++,
    ]);

    h.recovery.request(_album);
    await _settle();

    expect(h.passes, 2, reason: 'an install in a failed pass is not success');
    expect(h.gaveUp, isEmpty);
  });

  test('a report during a successful pass runs another pass', () async {
    late _Harness h;
    final release = Completer<void>();
    h = _Harness([
      () async {
        h.gen++;
        await release.future;
      },
      () async => h.gen++,
    ]);

    h.recovery.request(_album);
    await _settle();
    h.recovery.request(_album);
    release.complete();
    await _settle();

    expect(h.passes, 2,
        reason: 'a photo needing a later epoch reported mid run');
    expect(h.gaveUp, isEmpty);
  });

  test('passes that install nothing give up once, without looping', () async {
    final h = _Harness([() async {}]);

    h.recovery.request(_album);
    await _settle();

    expect(h.passes, 4, reason: 'one try plus three delayed retries');
    expect(h.gaveUp, [_album]);
  });

  test('reports from a whole grid share one run', () async {
    late _Harness h;
    h = _Harness([() async => h.gen++]);

    for (var i = 0; i < 20; i++) {
      h.recovery.request(_album);
    }
    await _settle();

    expect(h.passes, 2, reason: 'reports mid run queue one more pass');
  });

  test('a report after a run ends starts a new run', () async {
    late _Harness h;
    h = _Harness([() async => h.gen++]);

    h.recovery.request(_album);
    await _settle();
    h.recovery.request(_album);
    await _settle();

    expect(h.passes, 2);
  });
}
