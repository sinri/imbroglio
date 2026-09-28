import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/plugins.dart';
import 'package:imbroglio/src/services/store.dart';

void main() {
  late Directory root;
  late Store store;
  late PluginManager manager;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('imbroglio-package-test-');
    store = Store(NativeDatabase.memory());
    await store.init();
    manager = PluginManager(root.path, store, 'arm64');
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  Future<File> package({
    String id = 'test.agent',
    Map<String, List<int>> files = const {},
    Map<String, String>? hashes,
  }) async {
    final manifest = {
      'id': id,
      'name': 'Test',
      'version': '1.0.0',
      'kind': 'agent',
      'protocol': 1,
      'prompt': 'Summarize',
      'tools': ['search'],
      'files':
          hashes ??
          {
            for (final e in files.entries)
              e.key: sha256.convert(e.value).toString(),
          },
    };
    final bytes = utf8.encode(jsonEncode(manifest));
    final archive = Archive()
      ..addFile(ArchiveFile('manifest.json', bytes.length, bytes));
    for (final e in files.entries) {
      archive.addFile(ArchiveFile(e.key, e.value.length, e.value));
    }
    return File('${root.path}/package.zip')
      ..writeAsBytesSync(ZipEncoder().encode(archive));
  }

  test(
    'declarative plugin installs with verified identity and permissions',
    () async {
      final file = await package();
      final hash = sha256.convert(await file.readAsBytes()).toString();
      await manager.importPackage(file.path, hash);
      expect((await store.get('packages', 'test.agent'))!['enabled'], true);
    },
  );
  test('package changed after preview cannot be installed', () async {
    final file = await package();
    await expectLater(
      manager.importPackage(file.path, '0' * 64),
      throwsA(isA<AppFailure>()),
    );
    expect(await store.list('packages'), isEmpty);
  });
  test('zip traversal never writes outside install directory', () async {
    final file = await package(
      files: {'../../escaped.txt': utf8.encode('bad')},
    );
    await expectLater(
      manager.importPackage(
        file.path,
        sha256.convert(await file.readAsBytes()).toString(),
      ),
      throwsFormatException,
    );
    expect(await store.list('packages'), isEmpty);
    expect(File('${root.path}/escaped.txt').existsSync(), false);
  });
  test('invalid file digest does not activate plugin', () async {
    final file = await package(
      files: {'note.txt': utf8.encode('changed')},
      hashes: {'note.txt': '0' * 64},
    );
    await expectLater(
      manager.importPackage(
        file.path,
        sha256.convert(await file.readAsBytes()).toString(),
      ),
      throwsFormatException,
    );
    expect(await store.list('packages'), isEmpty);
  });
  test('failed official download preserves active version', () async {
    await store.put('installations', 'feishu', {
      'version': 'v1.0.0',
      'binary': 'old',
    });
    await expectLater(
      manager.installOfficial('feishu', {
        'version': 'v1.0.1',
        'asset': {'browser_download_url': 'http://untrusted.test/a.zip'},
      }, (_) {}),
      throwsA(isA<AppFailure>()),
    );
    expect((await manager.installation('feishu'))!['version'], 'v1.0.0');
  });
  test('package cannot shadow a reserved official connector', () async {
    final file = await package(id: 'dingtalk');
    await expectLater(
      manager.importPackage(
        file.path,
        sha256.convert(await file.readAsBytes()).toString(),
      ),
      throwsA(isA<AppFailure>()),
    );
  });
}
