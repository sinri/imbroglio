import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/services/startup.dart';
import 'package:imbroglio/src/services/workspace.dart';

class LoadingWorkspace extends Workspace {
  final events = <String>[];
  final initialized = Completer<void>();
  @override
  Future<void> initialize({String? directory}) async {
    events.add('database');
    await initialized.future;
    ready = true;
  }
}

void main() {
  test(
    'window is shown before database work, optional desktop work runs last',
    () async {
      final w = LoadingWorkspace();
      final shown = Completer<void>();
      final started = startWorkspace(
        w,
        showWindow: () async {
          w.events.add('show');
          await shown.future;
        },
        initializeDesktop: () async {
          w.events.add('desktop');
        },
      );
      expect(w.events, ['show']);
      shown.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(w.events, ['show', 'database']);
      expect(w.ready, false);
      w.initialized.complete();
      await started;
      expect(w.events, ['show', 'database', 'desktop']);
    },
  );
}
