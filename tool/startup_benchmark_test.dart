// Run with IMBROGLIO_STARTUP_SNAPSHOT pointing to a consistent SQLite backup:
// flutter test tool/startup_benchmark_test.dart --reporter expanded
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/services/workspace.dart';

class OfflineWorkspace extends Workspace {
  @override
  void tick({DateTime? at}) {} // Never connect accounts in a benchmark.
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final source = Platform.environment['IMBROGLIO_STARTUP_SNAPSHOT'];
  test(
    'measure local workspace startup on disposable snapshot copies',
    () async {
      final dir = await Directory.systemTemp.createTemp('imbroglio-startup-');
      try {
        await File(source!).copy('${dir.path}/imbroglio.sqlite');
        for (var run = 0; run < 5; run++) {
          final w = OfflineWorkspace();
          try {
            await w.initialize(directory: dir.path);
            expect(w.fatal, isNull);
            expect(w.ready, isTrue);
            // ignore: avoid_print
            print(jsonEncode({'run': run, ...w.startupTrace.toJson()}));
          } finally {
            if (w.ready) await w.close();
          }
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
    skip: source == null ? 'Set IMBROGLIO_STARTUP_SNAPSHOT to a backup' : false,
  );
}
