import 'dart:io';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final output = Directory('build/adapters');
  await output.create(recursive: true);
  final dart = p.join(
    p.dirname(Platform.resolvedExecutable),
    'dart${Platform.isWindows ? '.exe' : ''}',
  );
  final pub = await Process.start(
    dart,
    ['pub', 'get'],
    workingDirectory: 'tool/adapter',
    mode: ProcessStartMode.inheritStdio,
  );
  if (await pub.exitCode != 0) {
    exitCode = 1;
    return;
  }
  final process = await Process.start(
    dart,
    [
      'compile',
      'exe',
      '--packages=.dart_tool/package_config.json',
      '../../bin/im_adapter.dart',
      '-o',
      p.absolute(
        p.join(output.path, 'im_adapter${Platform.isWindows ? '.exe' : ''}'),
      ),
    ],
    workingDirectory: 'tool/adapter',
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
