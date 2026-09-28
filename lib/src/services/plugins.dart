import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import '../core/models.dart';
import 'store.dart';

const repositories = {
  'dingtalk': 'DingTalk-Real-AI/dingtalk-workspace-cli',
  'feishu': 'larksuite/cli',
};

class PluginManager {
  final String root;
  final Store store;
  final String architecture;
  final _busy = <String>{};
  PluginManager(this.root, this.store, this.architecture);
  String get target =>
      '${Platform.isMacOS
          ? 'darwin'
          : Platform.isWindows
          ? 'windows'
          : 'linux'}-$architecture';
  Future<Json?> installation(String id) => store.get('installations', id);
  Future<String> binary(String id) async {
    final state = await installation(id);
    if (state == null || state['enabled'] == false) {
      throw const AppFailure('not_installed', '请先在插件页面安装并启用 CLI');
    }
    final file = File(state['binary']);
    if (!p.isWithin(root, file.absolute.path) || !await file.exists()) {
      throw const AppFailure('binary_missing', '应用管理的 CLI 不存在，请重新安装');
    }
    return file.path;
  }

  Future<Json> release(String id) async {
    final repository = repositories[id];
    if (repository == null) throw const AppFailure('unsupported', '未知官方发行源');
    final response = await http
        .get(
          Uri.https('api.github.com', '/repos/$repository/releases/latest'),
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'Imbroglio/0.1',
          },
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw AppFailure('download', '发行源返回 ${response.statusCode}，请检查网络或稍后重试');
    }
    final release = object(jsonDecode(response.body));
    if (release['prerelease'] == true || release['draft'] == true) {
      throw const AppFailure('version', '仅支持正式稳定版本');
    }
    final assets = (release['assets'] as List).map(object).toList();
    final parts = target.split('-');
    final candidates = assets.where((a) {
      final name = '${a['name']}';
      return name.contains(parts[0]) &&
          name.contains(parts[1]) &&
          (name.endsWith('.zip') || name.endsWith('.tar.gz')) &&
          !name.contains('skills');
    }).toList();
    if (candidates.length != 1) {
      throw AppFailure('unsupported', '官方未提供唯一匹配的 $target 发行包');
    }
    final asset = candidates.single;
    return {
      'version': release['tag_name'],
      'asset': asset,
      'checksums': assets
          .where(
            (e) => RegExp(
              r'checksums.*\.txt$',
              caseSensitive: false,
            ).hasMatch('${e['name']}'),
          )
          .toList(),
      'notes': release['body'] ?? '',
    };
  }

  Future<List<int>> _download(
    String url, {
    int maxBytes = 180 * 1024 * 1024,
  }) async {
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' || uri.host != 'github.com') {
      throw const AppFailure('source', '仅从官方 GitHub 发行链接下载');
    }
    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw AppFailure('download', '下载失败 (${response.statusCode})');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 45),
      )) {
        if (bytes.length + chunk.length > maxBytes) {
          throw const AppFailure('size', '发行包超过大小限制');
        }
        bytes.addAll(chunk);
      }
      return bytes;
    } finally {
      client.close();
    }
  }

  Future<void> installOfficial(
    String id,
    Json release,
    void Function(String) progress,
  ) async {
    if (!_busy.add(id)) throw const AppFailure('busy', '此插件正在更新');
    Directory? staging;
    try {
      final version = '${release['version']}';
      if (!RegExp(
        r'^v?\d+\.\d+\.\d+([.+-][a-zA-Z0-9.-]+)?$',
      ).hasMatch(version)) {
        throw const AppFailure('version', '无效发行版本');
      }
      final asset = object(release['asset']);
      progress('下载 $version');
      final bytes = await _download(asset['browser_download_url']);
      var expected = '${asset['digest'] ?? ''}'.replaceFirst('sha256:', '');
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expected)) {
        final checks = (release['checksums'] as List);
        if (checks.length != 1) {
          throw const AppFailure('checksum', '官方发行包缺少 SHA-256，未安装');
        }
        final content = utf8.decode(
          await _download(
            checks.first['browser_download_url'],
            maxBytes: 1024 * 1024,
          ),
        );
        final line = const LineSplitter()
            .convert(content)
            .where(
              (l) =>
                  l.trim().split(RegExp(r'\s+')).last.replaceFirst('*', '') ==
                  asset['name'],
            );
        if (line.length != 1) {
          throw const AppFailure('checksum', '校验文件未包含目标发行包');
        }
        expected = line.single.trim().split(RegExp(r'\s+')).first;
      }
      if (sha256.convert(bytes).toString().toLowerCase() !=
          expected.toLowerCase()) {
        throw const AppFailure('checksum', '下载文件校验失败');
      }
      progress('校验完成，检查兼容性');
      staging = Directory(
        p.join(root, 'plugins', id, 'versions', '$version-${newId()}'),
      );
      await staging.create(recursive: true);
      final name =
          '${id == 'dingtalk' ? 'dws' : 'lark-cli'}${Platform.isWindows ? '.exe' : ''}';
      final extracted = await Isolate.run(() {
        final archive = '${asset['name']}'.endsWith('.zip')
            ? ZipDecoder().decodeBytes(bytes)
            : TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
        final matches = archive.files
            .where((f) => f.isFile && p.posix.basename(f.name) == name)
            .toList();
        if (matches.length != 1 || matches.single.size > 300 * 1024 * 1024) {
          throw const FormatException('发行包缺少唯一 CLI 可执行文件');
        }
        return matches.single.content;
      });
      final executable = File(p.join(staging.path, name));
      await executable.writeAsBytes(extracted, flush: true);
      if (!Platform.isWindows) {
        final chmod = await Process.run('/bin/chmod', ['700', executable.path]);
        if (chmod.exitCode != 0) {
          throw const AppFailure('permission', '无法设置执行权限');
        }
      }
      await probe(id, executable.path, staging.path);
      final old = await installation(id);
      await store.put('installations', id, {
        'id': id,
        'version': version,
        'binary': executable.path,
        'sha256': expected,
        'enabled': true,
        'previous': old == null ? null : {...old, 'previous': null},
      });
      await store.audit('plugin.install', {'plugin': id, 'version': version});
      progress('已安装 $version');
    } finally {
      _busy.remove(id);
    }
  }

  Future<void> probe(String id, String executable, String directory) async {
    final commands = id == 'dingtalk'
        ? [
            ['version'],
            ['chat', 'list-all-conversations', '--help'],
            ['chat', 'message', 'send', '--help'],
          ]
        : [
            ['--version'],
            ['im', '+chat-list', '--help'],
            ['im', '+messages-send', '--help'],
          ];
    for (final args in commands) {
      final result = await Process.run(
        executable,
        args,
        workingDirectory: directory,
        environment: {
          'DWS_CONFIG_DIR': p.join(directory, 'probe'),
          'LARKSUITE_CLI_CONFIG_DIR': p.join(directory, 'probe'),
          'LARKSUITE_CLI_NO_UPDATE_NOTIFIER': '1',
          'LARKSUITE_CLI_NO_SKILLS_NOTIFIER': '1',
        },
      ).timeout(const Duration(seconds: 15));
      final output = '${result.stdout}';
      if (result.exitCode != 0 ||
          (args.contains('--help') && !output.contains(args[1]))) {
        throw const AppFailure('compatibility', 'CLI 命令契约不兼容，旧版本保持不变');
      }
    }
  }

  Future<void> uninstall(String id, {bool package = false}) async {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{1,63}$').hasMatch(id)) {
      throw const AppFailure('plugin', '无效插件 ID');
    }
    await store.remove(package ? 'packages' : 'installations', id);
    final directory = Directory(
      p.join(root, package ? 'packages' : 'plugins', id),
    );
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> rollback(String id) async {
    final state = await installation(id);
    final previous = object(state?['previous']);
    if (previous.isEmpty || !await File(previous['binary']).exists()) {
      throw const AppFailure('rollback', '没有可回滚版本');
    }
    await store.put('installations', id, previous);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final state = await installation(id);
    if (state != null) {
      await store.put('installations', id, {...state, 'enabled': enabled});
    }
  }

  Future<PluginManifest> inspectPackage(String file) async {
    final bytes = await File(file).readAsBytes();
    if (bytes.length > 100 * 1024 * 1024) {
      throw const AppFailure('size', '插件包过大');
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    final entries = archive.files.where(
      (f) => f.name == 'manifest.json' && f.isFile,
    );
    if (entries.length != 1 || entries.single.size > 65536) {
      throw const FormatException('缺少 manifest.json');
    }
    return PluginManifest(
      object(jsonDecode(utf8.decode(entries.single.content))),
    );
  }

  Future<void> importPackage(String file, String expectedDigest) async {
    final bytes = await File(file).readAsBytes();
    if (sha256.convert(bytes).toString() != expectedDigest) {
      throw const AppFailure('package_changed', '插件包在确认后发生变化');
    }
    final manifest = await inspectPackage(file);
    if (repositories.containsKey(manifest.id)) {
      throw const AppFailure('reserved', '不能覆盖官方连接器');
    }
    final archive = ZipDecoder().decodeBytes(bytes);
    final dest = Directory(p.join(root, 'packages', manifest.id, newId()));
    await dest.create(recursive: true);
    var total = 0;
    final seen = <String>{};
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      total += entry.size;
      final normalized = entry.name.replaceAll('\\', '/');
      final target = p.normalize(p.join(dest.path, normalized));
      if (entry.isSymbolicLink ||
          normalized.contains(':') ||
          p.posix.isAbsolute(normalized) ||
          !p.isWithin(dest.path, target) ||
          !seen.add(target) ||
          total > 250 * 1024 * 1024) {
        throw const FormatException('不安全的插件包路径或大小');
      }
      final content = entry.content;
      if (entry.name != 'manifest.json') {
        final expected = object(manifest.data['files'])[entry.name];
        if (expected == null ||
            sha256.convert(content).toString() != expected) {
          throw const FormatException('插件文件校验失败');
        }
      }
      await File(target).parent.create(recursive: true);
      await File(target).writeAsBytes(content);
    }
    if (manifest.kind == 'im') {
      final entry = object(manifest.data['entrypoints'])[target];
      if (entry is! String ||
          !p.isWithin(dest.path, p.normalize(p.join(dest.path, entry))) ||
          !await File(p.join(dest.path, entry)).exists()) {
        throw const FormatException('插件不支持当前平台');
      }
      if (!Platform.isWindows) {
        await Process.run('/bin/chmod', ['700', p.join(dest.path, entry)]);
      }
    }
    await store.put('packages', manifest.id, {
      ...manifest.data,
      'directory': dest.path,
      'enabled': true,
    });
  }
}
