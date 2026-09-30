import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/agent.dart';
import 'package:imbroglio/src/services/mcp.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'mcp_test.dart' show dartBinary, RealHttp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'approve',
    'reject',
    'disable_before_confirm',
    'scope_empty',
  ]) {
    test('Agent MCP $mode', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('agent-mcp-');
      final log = File('${root.path}/calls.txt');
      final w = Workspace()
        ..root = root.path
        ..store = Store(NativeDatabase.memory());
      await w.store.init();
      final repository = McpRepository(w.store);
      await repository.save({
        'id': 'test.local',
        'name': 'Local',
        'transport': 'stdio',
        'command': await dartBinary(),
        'args': ['test/fixtures/mcp_peer.dart', log.path],
      });
      await repository.setEnabled('test.local', true);
      final agent = <String, dynamic>{
        'id': 'test.agent',
        'kind': 'agent',
        'prompt': 'Test',
        'tools': [],
        'enabled': true,
        if (mode == 'scope_empty') 'mcpServers': [],
      };
      await w.store.put('packages', agent['id'], agent);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final controller = AgentController(w);
      var requests = 0, previews = 0;
      final subscription = server.listen((request) async {
        final body = object(
          jsonDecode(await utf8.decoder.bind(request).join()),
        );
        final tools = body['tools'] as List? ?? [];
        if (mode == 'scope_empty') expect(tools, isEmpty);
        final functions = tools.map((t) => t['function']).toList();
        if (functions.isNotEmpty) {
          expect(functions.map((f) => f['name']).toSet().length, 2);
          expect(functions.first['parameters']['type'], 'object');
        }
        final delta = requests++ == 0 && functions.isNotEmpty
            ? {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'call_mcp',
                    'type': 'function',
                    'function': {
                      'name': functions.first['name'],
                      'arguments': '{"message":"hello"}',
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
        expect(controller.pending!['tool'], 'mcp_call');
        if (mode == 'disable_before_confirm') {
          repository
              .setEnabled('test.local', false)
              .then((_) => controller.decide(true));
        } else {
          controller.decide(mode == 'approve');
        }
      });
      try {
        await HttpOverrides.runWithHttpOverrides(
          () => controller.run('Test', {}, agent),
          RealHttp(),
        ).timeout(const Duration(seconds: 10));
        expect(controller.error, isEmpty);
        expect(previews, mode == 'scope_empty' ? 0 : 1);
        final methods = await log.exists()
            ? await log.readAsLines()
            : <String>[];
        expect(
          methods.where((m) => m == 'tools/call').length,
          mode == 'approve' ? 1 : 0,
        );
        if (mode == 'scope_empty') expect(methods, isEmpty);
        if (mode == 'approve') {
          final result = jsonDecode(
            controller.history.firstWhere(
              (m) => m['role'] == 'tool',
            )['content'],
          );
          expect(result['content'][0]['text'], contains('hello'));
        }
      } finally {
        controller.dispose();
        await subscription.cancel();
        await server.close(force: true);
        await w.close();
        await root.delete(recursive: true);
      }
    });
  }
}
