import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/services/agent.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'mcp_test.dart' show RealHttp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'recover',
    'manual',
    'auth',
    'cancel',
    'partial',
    'tool_manual',
  ]) {
    test('model retry $mode', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('agent-retry-');
      final w = Workspace()
        ..root = root.path
        ..store = Store(NativeDatabase.memory());
      await w.store.init();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final controller = AgentController(w);
      var requests = 0;
      final plugin = <String, dynamic>{
        'id': 'test.agent',
        'kind': 'agent',
        'prompt': 'Test',
        'tools': ['conversations'],
        'enabled': true,
        'mcpServers': [],
      };
      await w.store.put('packages', plugin['id'], plugin);
      await w.store.put('settings', 'model', {
        'baseUrl': 'http://127.0.0.1:${server.port}/v1',
        'model': 'test',
      });
      final sub = server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        expect(
          (body['messages'] as List).where((m) => m['role'] == 'user').length,
          1,
        );
        requests++;
        if (mode == 'tool_manual' && requests == 1) {
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {
                    'tool_calls': [
                      {
                        'index': 0,
                        'id': 'call_1',
                        'function': {'name': 'conversations', 'arguments': '{}'},
                      },
                    ],
                  },
                  'finish_reason': 'tool_calls',
                },
              ],
            })}\n\n',
          );
          await request.response.close();
          return;
        }
        if (mode == 'tool_manual') {
          expect(
            (body['messages'] as List).where((m) => m['role'] == 'tool').length,
            1,
          );
        }
        if (mode == 'auth' ||
            ((mode == 'tool_manual' && requests <= 4) ||
                mode != 'partial' && requests <= (mode == 'manual' ? 3 : 1))) {
          request.response.statusCode = mode == 'auth' ? 401 : 503;
        } else {
          final partial = mode == 'partial' && requests == 1;
          request.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': partial ? 'discard me' : '**Done**'},
                  'finish_reason': partial ? null : 'stop',
                },
              ],
            })}\n\n',
          );
        }
        await request.response.close();
      });
      if (mode == 'cancel') {
        controller.addListener(() {
          if (controller.retryStatus.isNotEmpty && !controller.cancelled) {
            controller.cancel();
          }
        });
      }
      try {
        await HttpOverrides.runWithHttpOverrides(() async {
          await controller.run('Test', {}, plugin);
          if (mode == 'manual' || mode == 'tool_manual') {
            expect(requests, mode == 'tool_manual' ? 4 : 3);
            expect(controller.canRetry, isTrue);
            await controller.retry();
          }
        }, RealHttp());
        if (mode == 'auth' || mode == 'cancel') {
          expect(requests, 1);
          expect(controller.canRetry, isFalse);
        } else {
          expect(controller.error, isEmpty);
          expect(controller.history.last['content'], '**Done**');
          expect(
            requests,
            mode == 'tool_manual'
                ? 5
                : mode == 'manual'
                ? 4
                : 2,
          );
          expect(
            controller.history.where((m) => m['role'] == 'assistant').length,
            mode == 'tool_manual' ? 2 : 1,
          );
        }
      } finally {
        controller.dispose();
        await sub.cancel();
        await server.close(force: true);
        await w.close();
        await root.delete(recursive: true);
      }
    });
  }
}
