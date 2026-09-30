import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/agent.dart';
import 'package:imbroglio/src/services/agent_extensions.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'disabled',
    'reject',
    'approve',
    'disable_before_confirm',
  ]) {
    test('model script call: $mode', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('script-loop-');
      final w = Workspace()
        ..root = '${root.path}/workspace'
        ..store = Store(NativeDatabase.memory());
      await w.store.init();
      final source = Directory('${root.path}/source');
      await source.create();
      await File('${source.path}/manifest.json').writeAsString(
        jsonEncode({
          'id': 'test.loop',
          'name': 'Loop',
          'version': '1',
          'protocol': 1,
          'kind': 'agent',
          'prompt': 'Use the script',
          'tools': [],
          'scripts': [
            {'id': 'mark', 'path': 'mark.sh', 'interpreter': '/bin/sh'},
          ],
        }),
      );
      await File(
        '${source.path}/mark.sh',
      ).writeAsString('echo done > marker.txt\necho success');
      final extensions = AgentExtensions(w.root, w.store);
      final owner = (await extensions.importDirectory(source.path)).single;
      await extensions.setScriptsEnabled(mode != 'disabled');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final controller = AgentController(w);
      var requests = 0, previews = 0;
      final offered = <String>[];
      final subscription = server.listen((request) async {
        final body = object(
          jsonDecode(await utf8.decoder.bind(request).join()),
        );
        offered.addAll(
          (body['tools'] as List? ?? []).map((t) => '${t['function']['name']}'),
        );
        final delta = requests++ == 0
            ? {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_1',
                    'type': 'function',
                    'function': {
                      'name': 'run_script',
                      'arguments': jsonEncode({
                        'script': 'test.loop/mark',
                        'input': '{}',
                      }),
                    },
                  },
                ],
              }
            : {'content': 'Finished'};
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          'data: ${jsonEncode({
            'choices': [
              {'delta': delta, 'finish_reason': 'stop'},
            ],
          })}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      await w.store.put('settings', 'model', {
        'baseUrl': 'http://127.0.0.1:${server.port}/v1',
        'model': 'test',
      });
      var deciding = false;
      controller.addListener(() {
        if (controller.pending == null || deciding) return;
        deciding = true;
        previews++;
        if (mode == 'disable_before_confirm') {
          extensions
              .setScriptsEnabled(false)
              .then((_) => controller.decide(true));
        } else {
          controller.decide(mode == 'approve');
        }
      });
      try {
        await HttpOverrides.runWithHttpOverrides(
          () => controller.run('Run', {}, owner),
          _LocalHttpOverrides(),
        ).timeout(const Duration(seconds: 10));
        expect(controller.error, isEmpty);
        expect(requests, 2);
        expect(previews, mode == 'disabled' ? 0 : 1);
        expect(offered.contains('run_script'), mode != 'disabled');
        expect(
          await File('${owner['directory']}/marker.txt').exists(),
          mode == 'approve',
        );
        final result = object(
          jsonDecode(
            controller.history.firstWhere(
              (m) => m['role'] == 'tool',
            )['content'],
          ),
        );
        if (mode == 'approve') expect(result['stdout'], contains('success'));
        if (mode == 'reject') expect(result['cancelled'], true);
        if (mode == 'disabled' || mode == 'disable_before_confirm') {
          expect(result['error'], isNotNull);
        }
      } finally {
        controller.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await w.close();
        await root.delete(recursive: true);
      }
    }, skip: Platform.isWindows);
  }
}

class _LocalHttpOverrides extends HttpOverrides {}
