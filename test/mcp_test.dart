import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/mcp.dart';
import 'package:imbroglio/src/services/store.dart';

class RealHttp extends HttpOverrides {}

Future<String> dartBinary() async {
  final config =
      jsonDecode(await File('.dart_tool/package_config.json').readAsString())
          as Map;
  final flutter =
      (config['packages'] as List).firstWhere(
            (v) => v['name'] == 'flutter',
          )['rootUri']
          as String;
  return p.normalize(
    p.join(
      Uri.parse(flutter).toFilePath(),
      '..',
      '..',
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'repository defaults disabled, isolates secrets, updates revision',
    () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = Store(NativeDatabase.memory());
      await store.init();
      final repo = McpRepository(store);
      await repo.save({
        'id': 'test.http',
        'name': 'HTTP',
        'transport': 'http',
        'url': 'https://example.com/mcp',
        'headers': {'Authorization': 'Bearer secret'},
      });
      final saved = (await repo.list()).single;
      expect(saved['enabled'], false);
      expect(saved.containsKey('headers'), false);
      expect(
        (await repo.load('test.http'))['headers']['Authorization'],
        'Bearer secret',
      );
      await repo.setEnabled('test.http', true);
      expect(
        (await repo.load('test.http'))['revision'],
        isNot(saved['revision']),
      );
      await repo.remove('test.http');
      expect(await repo.list(), isEmpty);
      await store.close();
    },
  );
  test('invalid remote URLs and reserved headers are rejected', () {
    final config = {
      'id': 'test.http',
      'name': 'HTTP',
      'transport': 'http',
      'url': 'http://example.com/mcp',
    };
    expect(() => validateMcpConfig(config), throwsFormatException);
    expect(
      () => validateMcpConfig({
        ...config,
        'url': 'https://example.com',
        'headers': {'MCP-Session-ID': 'spoof'},
      }),
      throwsFormatException,
    );
  });
  test('stdio handshake, pagination, results, timeout and close', () async {
    final config = {
      'id': 'test.local',
      'name': 'Local',
      'transport': 'stdio',
      'enabled': true,
      'command': await dartBinary(),
      'args': ['test/fixtures/mcp_peer.dart'],
    };
    final client = McpClient(config, timeout: const Duration(seconds: 2));
    try {
      await client.connect();
      expect((await client.listTools()).map((t) => t['name']), [
        'echo',
        'second',
      ]);
      expect(
        (await client.callTool('echo', {'hello': '世界'}))['content'][0]['text'],
        contains('世界'),
      );
      expect((await client.callTool('fail', {}))['isError'], true);
      await expectLater(
        client.callTool('hang', {}),
        throwsA(isA<AppFailure>().having((e) => e.code, 'code', 'mcp_timeout')),
      );
    } finally {
      await client.close();
    }
    await expectLater(client.callTool('echo', {}), throwsA(isA<AppFailure>()));
  });
  test(
    'stdio cancellation, oversized messages and process exit fail promptly',
    () async {
      for (final method in ['hang', 'large', 'exit']) {
        final client = McpClient({
          'id': 'test.local',
          'name': 'Local',
          'transport': 'stdio',
          'enabled': true,
          'command': await dartBinary(),
          'args': ['test/fixtures/mcp_peer.dart'],
        });
        await client.connect();
        final assertion = expectLater(
          client.callTool(method, {}),
          throwsA(isA<AppFailure>()),
        );
        if (method == 'hang') await client.close();
        await assertion.timeout(const Duration(seconds: 5));
        await client.close();
      }
    },
  );
  for (final sse in [false, true]) {
    test(
      'HTTP $sse initialization, session headers, JSON/SSE and delete',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final calls = <String>[];
          final headers = <String?>[];
          final subscription = server.listen((request) async {
            if (request.method == 'DELETE') {
              calls.add('DELETE');
              request.response.statusCode = 204;
              await request.response.close();
              return;
            }
            final msg =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            calls.add(msg['method']);
            if (msg['method'] != 'initialize') {
              headers.add(request.headers.value('mcp-session-id'));
              headers.add(request.headers.value('mcp-protocol-version'));
            }
            if (!msg.containsKey('id')) {
              request.response.statusCode = 202;
              await request.response.close();
              return;
            }
            final result = msg['method'] == 'initialize'
                ? {
                    'protocolVersion': '2025-11-25',
                    'capabilities': {'tools': {}},
                  }
                : msg['method'] == 'tools/list'
                ? {
                    'tools': [
                      {
                        'name': 'echo',
                        'inputSchema': {'type': 'object'},
                      },
                    ],
                  }
                : {
                    'content': [
                      {'type': 'text', 'text': 'ok'},
                    ],
                  };
            if (msg['method'] == 'initialize') {
              request.response.headers.set('MCP-Session-Id', 'test-session');
            }
            request.response.headers.contentType = sse
                ? ContentType('text', 'event-stream')
                : ContentType.json;
            final response = jsonEncode({
              'jsonrpc': '2.0',
              'id': msg['id'],
              'result': result,
            });
            request.response.write(
              sse ? ': heartbeat\r\ndata: $response\r\n\r\n' : response,
            );
            await request.response.close();
          });
          final client = McpClient({
            'id': 'test.http',
            'name': 'HTTP',
            'transport': 'http',
            'enabled': true,
            'url': 'http://127.0.0.1:${server.port}/mcp',
          });
          try {
            await client.connect();
            expect((await client.listTools()).single['name'], 'echo');
            expect(
              (await client.callTool('echo', {}))['content'][0]['text'],
              'ok',
            );
            await client.close();
            expect(calls, [
              'initialize',
              'notifications/initialized',
              'tools/list',
              'tools/call',
              'DELETE',
            ]);
            expect(headers, everyElement(anyOf('test-session', '2025-11-25')));
          } finally {
            await client.close();
            await subscription.cancel();
            await server.close(force: true);
          }
        }, RealHttp());
      },
    );
  }
}
