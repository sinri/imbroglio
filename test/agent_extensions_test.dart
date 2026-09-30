import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/agent_extensions.dart';
import 'package:imbroglio/src/services/store.dart';

void main() {
  late Directory root;
  late Store store;
  late AgentExtensions extensions;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-extensions-');
    store = Store(NativeDatabase.memory());
    await store.init();
    extensions = AgentExtensions('${root.path}/workspace', store);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  Future<List<Json>> install({
    String body = 'read input\nprintf "%s" "\$input"',
    int timeout = 2,
  }) async {
    final dir = Directory('${root.path}/source');
    await dir.create(recursive: true);
    await File('${dir.path}/manifest.json').writeAsString(
      jsonEncode({
        'id': 'test.local',
        'name': 'Local',
        'version': '1',
        'kind': 'agent',
        'protocol': 1,
        'prompt': 'Test',
        'tools': [],
        'scripts': [
          {
            'id': 'test',
            'path': 'test.sh',
            'interpreter': '/bin/sh',
            'timeoutSeconds': timeout,
          },
        ],
      }),
    );
    await File('${dir.path}/test.sh').writeAsString(body);
    return extensions.importDirectory(dir.path);
  }

  test(
    'imports a collection, resolves SKILL.md and blocks disabled skills',
    () async {
      final imported = await extensions.importDirectory(
        'examples/agent-bundle',
      );
      expect(imported.length, 2);
      final agent = imported.firstWhere((d) => d['kind'] == 'agent');
      final definitions = await extensions.resolve(agent);
      expect(definitions.last['prompt'], contains('文本统计'));
      final skill = definitions.last;
      await store.put('packages', skill['id'], {...skill, 'enabled': false});
      await expectLater(extensions.resolve(agent), throwsA(isA<AppFailure>()));
    },
  );
  test(
    'scripts are disabled by default and cannot start without opt-in',
    () async {
      final owner = (await install()).single;
      expect(await extensions.scriptsEnabled, false);
      final runner = LocalScriptRunner(
        allowed: () => extensions.scriptsEnabled,
      );
      await expectLater(
        runner.run(owner, object(owner['scripts'][0]), '{}'),
        throwsA(isA<AppFailure>()),
      );
      await extensions.setScriptsEnabled(true);
      final result = await runner.run(
        owner,
        object(owner['scripts'][0]),
        '{"hello":"world"}',
      );
      expect(result['exitCode'], 0);
      expect(result['stdout'], '{"hello":"world"}');
      await extensions.setScriptsEnabled(false);
      await expectLater(
        runner.run(owner, object(owner['scripts'][0]), '{}'),
        throwsA(isA<AppFailure>()),
      );
    },
    skip: Platform.isWindows,
  );
  test(
    'installed files are snapshots and modified scripts are rejected',
    () async {
      final owner = (await install()).single;
      await File('${root.path}/source/test.sh').writeAsString('exit 9');
      await extensions.setScriptsEnabled(true);
      final runner = LocalScriptRunner(
        allowed: () => extensions.scriptsEnabled,
      );
      expect(
        (await runner.run(
          owner,
          object(owner['scripts'][0]),
          '{}',
        ))['exitCode'],
        0,
      );
      await File('${owner['directory']}/test.sh').writeAsString('exit 9');
      await expectLater(
        runner.run(owner, object(owner['scripts'][0]), '{}'),
        throwsA(isA<AppFailure>()),
      );
    },
    skip: Platform.isWindows,
  );
  test('timeout and cancellation stop the launched process', () async {
    final owner = (await install(
      body: 'while :; do :; done',
      timeout: 1,
    )).single;
    await extensions.setScriptsEnabled(true);
    final script = object(owner['scripts'][0]);
    final runner = LocalScriptRunner(allowed: () => extensions.scriptsEnabled);
    expect((await runner.run(owner, script, '{}'))['timedOut'], true);
    final next = LocalScriptRunner(allowed: () => extensions.scriptsEnabled);
    final future = next.run(owner, {...script, 'timeoutSeconds': 10}, '{}');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    next.cancel();
    expect((await future)['cancelled'], true);
  }, skip: Platform.isWindows);
  test('output limit terminates an unbounded producer', () async {
    final owner = (await install(
      body: 'while :; do echo abcdefghijklmnopqrstuvwxyz; done',
    )).single;
    await extensions.setScriptsEnabled(true);
    final result = await LocalScriptRunner(
      allowed: () => extensions.scriptsEnabled,
    ).run(owner, object(owner['scripts'][0]), '{}');
    expect(result['outputLimited'], true);
    expect((result['stdout'] as String).length, lessThanOrEqualTo(128 * 1024));
  }, skip: Platform.isWindows);
  test(
    'symlinks and missing skills do not activate partial imports',
    () async {
      final dir = Directory('${root.path}/bad');
      await dir.create();
      await Link('${dir.path}/escape').create(root.path);
      await expectLater(
        extensions.importDirectory(dir.path),
        throwsFormatException,
      );
      expect(await store.list('packages'), isEmpty);
      await Link('${dir.path}/escape').delete();
      await File('${dir.path}/manifest.json').writeAsString(
        jsonEncode({
          'id': 'test.bad',
          'name': 'Bad',
          'version': '1',
          'kind': 'agent',
          'protocol': 1,
          'prompt': '',
          'tools': [],
          'skills': ['missing.skill'],
        }),
      );
      await expectLater(
        extensions.importDirectory(dir.path),
        throwsFormatException,
      );
      expect(await store.list('packages'), isEmpty);
    },
    skip: Platform.isWindows,
  );
}
