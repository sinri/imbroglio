import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/core/rpc.dart';
import 'package:path/path.dart' as p;

void main() {
  late RpcClient rpc;
  setUp(() async {
    final config =
        jsonDecode(await File('.dart_tool/package_config.json').readAsString())
            as Map;
    final flutter =
        (config['packages'] as List).firstWhere(
              (v) => v['name'] == 'flutter',
            )['rootUri']
            as String;
    final root = p.normalize(
      p.join(Uri.parse(flutter).toFilePath(), '..', '..'),
    );
    final dart = p.join(
      root,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    );
    rpc = RpcClient(await Process.start(dart, ['test/fixtures/rpc_peer.dart']));
  });
  tearDown(() async {
    await rpc.close();
  });
  test(
    'responses correlate by request ID even when completed out of order',
    () async {
      final slow = rpc.call('slow'), fast = rpc.call('fast');
      expect((await fast)['method'], 'fast');
      expect((await slow)['method'], 'slow');
    },
  );
  test('timeout is surfaced and does not block later calls', () async {
    await expectLater(
      rpc.call('hang', {}, const Duration(milliseconds: 50)),
      throwsA(isA<AppFailure>()),
    );
    expect((await rpc.call('fast'))['method'], 'fast');
  });
  test('crashed process fails pending and future requests', () async {
    await expectLater(rpc.call('crash'), throwsA(isA<AppFailure>()));
    await expectLater(rpc.call('fast'), throwsA(isA<AppFailure>()));
  });
}
