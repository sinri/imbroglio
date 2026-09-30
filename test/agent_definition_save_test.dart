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
    root = await Directory.systemTemp.createTemp('definition-save-');
    store = Store(NativeDatabase.memory());
    await store.init();
    extensions = AgentExtensions(root.path, store);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  Json definition(String id, {String kind = 'agent'}) => {
    'id': id,
    'name': '测试定义',
    'version': '1.0.0',
    'kind': kind,
    'protocol': 1,
    'prompt': '指令',
    'tools': ['search'],
  };
  test(
    'creates skill and agent directly, writes coherent snapshots and preserves opt-in',
    () async {
      final skill = await extensions.saveDefinition(
        definition('test.skill', kind: 'skill'),
        {},
      );
      expect(await File('${skill['directory']}/SKILL.md').readAsString(), '指令');
      final agent = await extensions.saveDefinition(
        {
          ...definition('test.agent'),
          'skills': ['test.skill'],
          'mcpServers': [],
          'scripts': [
            {
              'id': 'hello',
              'path': 'scripts/hello.py',
              'interpreter': 'python3',
            },
          ],
        },
        {'scripts/hello.py': 'print("hello")'},
      );
      expect((await extensions.resolve(agent)).length, 2);
      expect(await extensions.scriptsEnabled, false);
      expect(
        (await extensions.scriptSources(agent))['scripts/hello.py'],
        'print("hello")',
      );
      expect(
        jsonDecode(
          await File('${agent['directory']}/manifest.json').readAsString(),
        )['mcpServers'],
        isEmpty,
      );
    },
  );
  test(
    'editing built-in definitions retains identity and disabled state',
    () async {
      final original = {
        ...definition('imbroglio.assistant'),
        'builtin': true,
        'enabled': false,
        'workflow': ['retrieve'],
      };
      await store.put('packages', original['id'], original);
      final saved = await extensions.saveDefinition(
        {...original, 'prompt': '新指令', 'builtin': false, 'enabled': true},
        {},
        expected: original,
      );
      expect(saved['builtin'], true);
      expect(saved['enabled'], false);
      expect(saved['workflow'], ['retrieve']);
      expect(saved['prompt'], '新指令');
      await expectLater(
        extensions.saveDefinition(
          {...saved, 'id': 'test.other'},
          {},
          expected: saved,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'duplicate IDs, stale edits and missing references cannot replace saved definitions',
    () async {
      final saved = await extensions.saveDefinition(
        definition('test.agent'),
        {},
      );
      await expectLater(
        extensions.saveDefinition(definition('test.agent'), {}),
        throwsA(isA<AppFailure>()),
      );
      final updated = await extensions.saveDefinition(
        {...saved, 'prompt': '新版本'},
        {},
        expected: saved,
      );
      await expectLater(
        extensions.saveDefinition(
          {...saved, 'prompt': '旧窗口'},
          {},
          expected: saved,
        ),
        throwsA(isA<AppFailure>()),
      );
      expect(
        (await store.get('packages', saved['id']))!['directory'],
        updated['directory'],
      );
      await expectLater(
        extensions.saveDefinition({
          ...definition('test.bad'),
          'skills': ['missing.skill'],
        }, {}),
        throwsFormatException,
      );
      expect(await store.get('packages', 'test.bad'), isNull);
    },
  );
  test(
    'editing an imported definition preserves assets and updates script hashes',
    () async {
      final imported = await extensions.importDirectory(
        'examples/agent-bundle',
      );
      final skill = imported.firstWhere((v) => v['kind'] == 'skill');
      final source = await extensions.scriptSources(skill);
      final edited = await extensions.saveDefinition(
        {...skill, 'prompt': '更新后的技能指令'},
        {for (final path in source.keys) path: 'print("edited")'},
        expected: skill,
      );
      expect(edited['directory'], isNot(skill['directory']));
      expect(await extensions.scriptSources(edited), {
        'scripts/count.py': 'print("edited")',
      });
      expect(
        await File('${edited['directory']}/SKILL.md').readAsString(),
        '更新后的技能指令',
      );
      expect(
        await File('${skill['directory']}/scripts/count.py').readAsString(),
        source['scripts/count.py'],
      );
    },
  );
  test(
    'script traversal, reserved files and out-of-band modifications are rejected',
    () async {
      for (final path in [
        '../escape.py',
        '/tmp/escape.py',
        'manifest.json',
        'SKILL.md',
      ]) {
        await expectLater(
          extensions.saveDefinition(
            {
              ...definition('test.bad'),
              'scripts': [
                {'id': 'bad', 'path': path, 'interpreter': 'python3'},
              ],
            },
            {path: 'print(1)'},
          ),
          throwsFormatException,
        );
      }
      final saved = await extensions.saveDefinition(
        {
          ...definition('test.script'),
          'scripts': [
            {'id': 'run', 'path': 'run.py', 'interpreter': 'python3'},
          ],
        },
        {'run.py': 'print(1)'},
      );
      await File('${saved['directory']}/run.py').writeAsString('print(2)');
      await expectLater(extensions.scriptSources(saved), throwsFormatException);
      await expectLater(
        extensions.saveDefinition(saved, {
          'run.py': 'print(3)',
        }, expected: saved),
        throwsFormatException,
      );
    },
  );
}
