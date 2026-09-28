import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/plugins.dart';
import 'package:imbroglio/src/core/rpc.dart';
import 'package:imbroglio/src/core/models.dart';
import 'dart:ffi';

/// Explicit network smoke test. Downloads official CLIs into build/verification.
/// Only help/version/initialize/health are invoked: no login or business data.
Future<void> main() async {
  final root = p.absolute('build/verification');
  await Directory(root).create(recursive: true);
  final store = await Store.open(p.join(root, 'verify.sqlite'));
  final manager = PluginManager(
    root,
    store,
    Abi.current().toString().contains('arm64') ? 'arm64' : 'amd64',
  );
  try {
    for (final id in ['dingtalk', 'feishu']) {
      final release = await manager.release(id);
      stdout.writeln(
        '$id: official ${release['version']} (${release['asset']['name']})',
      );
      final existing = await manager.installation(id);
      if (existing?['version'] != release['version']) {
        await manager.installOfficial(id, release, stdout.writeln);
      }
      final process = await Process.start(
        p.absolute(
          'build/adapters/im_adapter${Platform.isWindows ? '.exe' : ''}',
        ),
        [],
      );
      final rpc = RpcClient(process);
      try {
        final result = object(
          await rpc.call('initialize', {
            'protocol': 1,
            'platform': id,
            'binary': await manager.binary(id),
            'directory': p.join(root, 'accounts', id),
            'accountId': id,
            'profile': '',
          }, const Duration(seconds: 90)),
        );
        stdout.writeln(
          '$id: protocol=${result['protocol']} capabilities=${result['capabilities']}',
        );
        stdout.writeln(await rpc.call('health'));
      } finally {
        await rpc.close();
      }
    }
  } finally {
    await store.close();
  }
}
