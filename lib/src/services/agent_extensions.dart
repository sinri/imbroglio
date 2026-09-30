import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import '../core/models.dart';
import 'store.dart';

/// Directory imports are snapshots; source edits require explicit re-import.
class AgentExtensions {
  final String root;
  final Store store;
  AgentExtensions(this.root, this.store);

  Future<bool> get scriptsEnabled async =>
      (await store.get('settings', 'localScripts'))?['enabled'] == true;

  Future<void> setScriptsEnabled(bool value) =>
      store.put('settings', 'localScripts', {'enabled': value});

  Future<List<Json>> importDirectory(String path) async {
    final source = Directory(await Directory(path).resolveSymbolicLinks());
    final definitions = <Json>[];
    var total = 0;
    final allFiles = <File>[];
    await for (final entry in source.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entry is Link) throw const FormatException('目录不能包含符号链接');
      if (entry is File) {
        total += await entry.length();
        if (total > 50 * 1024 * 1024 || allFiles.length >= 2000) {
          throw const FormatException('目录超过 50 MiB 或 2000 个文件');
        }
        allFiles.add(entry);
      }
    }
    final ids = <String>{};
    for (final file in allFiles.where(
      (f) => p.basename(f.path) == 'manifest.json',
    )) {
      final data = object(jsonDecode(await file.readAsString()));
      if (data['kind'] == 'skill') {
        data['prompt'] ??= await File(
          p.join(file.parent.path, 'SKILL.md'),
        ).readAsString();
        data['tools'] ??= <String>[];
      }
      final manifest = PluginManifest(data);
      if (!['agent', 'skill'].contains(manifest.kind) ||
          !ids.add(manifest.id) ||
          ['dingtalk', 'feishu'].contains(manifest.id)) {
        throw const FormatException('目录只支持 ID 不重复的 Agent 与 skill');
      }
      final old = await store.get('packages', manifest.id);
      if (old != null && (old['builtin'] == true || old['kind'] == 'im')) {
        throw const FormatException('不能覆盖内置 Agent 或 IM 插件');
      }
      final files = <String, List<int>>{};
      for (final child in allFiles.where(
        (f) => p.isWithin(file.parent.path, f.path),
      )) {
        if (child.path != file.path &&
            p.basename(child.path) == 'manifest.json') {
          throw const FormatException('定义目录不能嵌套');
        }
        files[p
            .relative(child.path, from: file.parent.path)
            .replaceAll('\\', '/')] = await child
            .readAsBytes();
      }
      for (final raw in data['scripts'] as List? ?? []) {
        final script = object(raw);
        if (!files.containsKey(script['path'])) {
          throw const FormatException('脚本必须位于定义目录内');
        }
      }
      definitions.add({'manifest': data, 'files': files});
    }
    if (definitions.isEmpty) throw const FormatException('没有找到 manifest.json');
    final available = {
      ...{for (final j in await store.list('packages')) j['id']: j},
      for (final d in definitions) d['manifest']['id']: d['manifest'],
    };
    for (final d in definitions) {
      for (final id in d['manifest']['skills'] as List? ?? []) {
        if (available[id]?['kind'] != 'skill') {
          throw FormatException('找不到 skill：$id');
        }
      }
    }
    final installed = <Json>[];
    final staging = <Directory>[];
    try {
      for (final definition in definitions) {
        final data = object(definition['manifest']);
        final dest = Directory(p.join(root, 'packages', data['id'], newId()));
        staging.add(dest);
        final hashes = <String, String>{};
        for (final entry
            in (definition['files'] as Map<String, List<int>>).entries) {
          final out = File(p.join(dest.path, entry.key));
          await out.parent.create(recursive: true);
          await out.writeAsBytes(entry.value);
          hashes[entry.key] = sha256.convert(entry.value).toString();
        }
        installed.add({
          ...data,
          'directory': dest.path,
          'files': hashes,
          'enabled': true,
          'builtin': false,
          'sourceDirectory': source.path,
        });
      }
      await store.db.transaction(() async {
        for (final data in installed) {
          await store.put('packages', data['id'], data);
        }
      });
      return installed;
    } catch (_) {
      for (final dir in staging) {
        if (await dir.exists()) await dir.delete(recursive: true);
      }
      rethrow;
    }
  }

  /// Read only registered, unchanged files from the managed installation.
  Future<List<int>> _readFile(Json owner, String relative) async {
    _validatePath(relative);
    final directory = await Directory(
      owner['directory'],
    ).resolveSymbolicLinks();
    final file = File(p.join(directory, relative));
    final resolved = await file.resolveSymbolicLinks();
    if (!p.isWithin(directory, resolved)) {
      throw const FormatException('文件越出定义目录');
    }
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != object(owner['files'])[relative]) {
      throw FormatException('文件已在外部修改：$relative，请重新导入后编辑');
    }
    return bytes;
  }

  void _validatePath(String path) {
    if (path.isEmpty ||
        p.posix.isAbsolute(path) ||
        path.contains('\\') ||
        path.contains(':') ||
        path.split('/').any((v) => v == '..' || v == '.' || v.isEmpty)) {
      throw const FormatException('文件路径必须是定义目录内的相对路径');
    }
  }

  Future<Map<String, String>> scriptSources(Json owner) async {
    final sources = <String, String>{};
    for (final raw in owner['scripts'] as List? ?? []) {
      final path = object(raw)['path'] as String;
      final bytes = await _readFile(owner, path);
      if (bytes.length > 1024 * 1024) {
        throw const FormatException('编辑器支持 1 MiB 以内的脚本文本');
      }
      sources[path] = utf8.decode(bytes);
    }
    return sources;
  }

  Future<Json> saveDefinition(
    Json definition,
    Map<String, String> scripts, {
    Json? expected,
  }) async {
    final data = object(jsonDecode(jsonEncode(definition)));
    for (final key in [
      'directory',
      'files',
      'enabled',
      'builtin',
      'sourceDirectory',
      'origin',
    ]) {
      data.remove(key);
    }
    final manifest = PluginManifest(data);
    if (!['agent', 'skill'].contains(manifest.kind) ||
        ['dingtalk', 'feishu'].contains(manifest.id) ||
        manifest.name.trim().isEmpty ||
        manifest.version.trim().isEmpty) {
      throw const FormatException('请填写名称、版本及有效的 Agent / skill 定义');
    }
    if (expected != null &&
        (expected['id'] != manifest.id || expected['kind'] != manifest.kind)) {
      throw const FormatException('编辑时不能修改 ID 或类型');
    }
    final files = <String, List<int>>{};
    if (expected != null && expected['directory'] != null) {
      for (final path in object(expected['files']).keys) {
        final bytes = await _readFile(expected, path);
        if (path == 'manifest.json' ||
            path == 'SKILL.md' ||
            scripts.containsKey(path)) {
          continue;
        }
        files[path] = bytes;
      }
    }
    final paths = <String>{};
    for (final raw in data['scripts'] as List? ?? []) {
      final path = object(raw)['path'] as String;
      _validatePath(path);
      if (['manifest.json', 'SKILL.md'].contains(path) ||
          !scripts.containsKey(path)) {
        throw const FormatException(
          '每个脚本需要文件路径和代码，不能使用 manifest.json 或 SKILL.md',
        );
      }
      paths.add(path);
      final bytes = utf8.encode(scripts[path]!);
      if (bytes.length > 1024 * 1024) throw const FormatException('脚本超过 1 MiB');
      files[path] = bytes;
    }
    if (scripts.keys.any((path) => !paths.contains(path))) {
      throw const FormatException('存在未声明的脚本文件');
    }
    if (manifest.kind == 'skill') {
      files['SKILL.md'] = utf8.encode(data['prompt']);
    }
    files['manifest.json'] = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(data),
    );
    if (files.length > 2000 ||
        files.values.fold<int>(0, (total, bytes) => total + bytes.length) >
            50 * 1024 * 1024) {
      throw const FormatException('定义超过 50 MiB 或 2000 个文件');
    }
    final dest = Directory(p.join(root, 'packages', manifest.id, newId()));
    try {
      final hashes = <String, String>{};
      for (final entry in files.entries) {
        final file = File(p.join(dest.path, entry.key));
        await file.parent.create(recursive: true);
        await file.writeAsBytes(entry.value, flush: true);
        hashes[entry.key] = sha256.convert(entry.value).toString();
      }
      final saved = {
        ...data,
        'directory': dest.path,
        'files': hashes,
        'enabled': expected?['enabled'] ?? true,
        'builtin': expected?['builtin'] == true,
        'origin': 'editor',
        if (expected?['sourceDirectory'] != null)
          'sourceDirectory': expected!['sourceDirectory'],
      };
      await store.db.transaction(() async {
        final current = await store.get('packages', manifest.id);
        if (jsonEncode(current) != jsonEncode(expected)) {
          throw const AppFailure(
            'definition_conflict',
            '此 ID 已存在或定义已被更新，请重新打开编辑器',
          );
        }
        for (final id in data['skills'] as List? ?? []) {
          if ((await store.get('packages', id))?['kind'] != 'skill') {
            throw FormatException('找不到 skill：$id');
          }
        }
        await store.put('packages', manifest.id, saved);
      });
      return saved;
    } catch (_) {
      if (await dest.exists()) await dest.delete(recursive: true);
      rethrow;
    }
  }

  Future<List<Json>> resolve(Json agent) async {
    final current = await store.get('packages', agent['id']);
    if (current == null ||
        current['enabled'] != true ||
        current['kind'] != 'agent') {
      throw const AppFailure('plugin', 'Agent 已停用或卸载');
    }
    final result = <Json>[current];
    for (final id in current['skills'] as List? ?? []) {
      final skill = await store.get('packages', id);
      if (skill == null ||
          skill['kind'] != 'skill' ||
          skill['enabled'] != true) {
        throw AppFailure('skill', 'skill 不可用：$id');
      }
      result.add(skill);
    }
    return result;
  }
}

class LocalScriptRunner {
  final Future<bool> Function() allowed;
  LocalScriptRunner({required this.allowed});
  Future<void> _checkPermission() async {
    if (!await allowed()) {
      throw const AppFailure('scripts_disabled', '本地脚本执行已关闭');
    }
    if (_cancelled) throw const AppFailure('cancelled', '脚本执行已取消');
  }

  Process? _process;
  bool _cancelled = false;
  void cancel() {
    _cancelled = true;
    _process?.kill(ProcessSignal.sigkill);
  }

  Future<Json> run(Json owner, Json script, String input) async {
    if (_cancelled) throw const AppFailure('cancelled', '脚本执行已取消');
    await _checkPermission();
    final directory = await Directory(
      owner['directory'],
    ).resolveSymbolicLinks();
    final file = File(p.join(directory, script['path']));
    final resolved = await file.resolveSymbolicLinks();
    if (!p.isWithin(directory, resolved) ||
        sha256.convert(await file.readAsBytes()).toString() !=
            object(owner['files'])[script['path']]) {
      throw const AppFailure('script_changed', '脚本内容已变更，请重新导入目录');
    }
    if (_cancelled) throw const AppFailure('cancelled', '脚本执行已取消');
    await _checkPermission();
    final process = await Process.start(
      script['interpreter'],
      [resolved],
      workingDirectory: directory,
      runInShell: false,
    );
    _process = process;
    if (_cancelled) process.kill(ProcessSignal.sigkill);
    final output = <String, List<int>>{'stdout': [], 'stderr': []};
    var size = 0;
    var limited = false;
    var timedOut = false;
    void collect(String key, List<int> bytes) {
      final remaining = 128 * 1024 - size;
      if (remaining > 0) output[key]!.addAll(bytes.take(remaining));
      size += bytes.length;
      if (size > 128 * 1024) {
        limited = true;
        process.kill(ProcessSignal.sigkill);
      }
    }

    final outDone = Completer<void>(), errDone = Completer<void>();
    final out = process.stdout.listen(
      (b) => collect('stdout', b),
      onDone: outDone.complete,
    );
    final err = process.stderr.listen(
      (b) => collect('stderr', b),
      onDone: errDone.complete,
    );
    final timer = Timer(
      Duration(seconds: script['timeoutSeconds'] as int? ?? 60),
      () {
        timedOut = true;
        process.kill(ProcessSignal.sigkill);
      },
    );
    try {
      process.stdin.add(utf8.encode('$input\n'));
      // Scripts may close stdin without reading it.
      unawaited(process.stdin.close().catchError((Object _) {}));
      final code = await process.exitCode;
      await Future.wait([
        outDone.future,
        errDone.future,
      ]).timeout(const Duration(seconds: 1), onTimeout: () => <void>[]);
      return {
        'exitCode': code,
        'stdout': utf8.decode(output['stdout']!, allowMalformed: true),
        'stderr': utf8.decode(output['stderr']!, allowMalformed: true),
        'timedOut': timedOut,
        'outputLimited': limited,
        'cancelled': _cancelled,
      };
    } finally {
      timer.cancel();
      await out.cancel();
      await err.cancel();
      _process = null;
    }
  }
}
