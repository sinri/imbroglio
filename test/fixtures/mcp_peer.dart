import 'dart:convert';
import 'dart:io';

void main(List<String> args) async {
  var initialized = false;
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    final method = message['method'];
    if (args.isNotEmpty) {
      File(args.first).writeAsStringSync('$method\n', mode: FileMode.append);
    }
    if (method == 'notifications/initialized') {
      initialized = true;
      continue;
    }
    if (!message.containsKey('id')) continue;
    final params = message['params'] as Map? ?? {};
    Object result;
    switch (method) {
      case 'initialize':
        result = {
          'protocolVersion': '2025-11-25',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'fixture', 'version': '1'},
        };
      case 'tools/list':
        if (!initialized) {
          exit(2);
        }
        final second = params['cursor'] == 'next';
        result = {
          'tools': [
            {
              'name': second ? 'second' : 'echo',
              'description': 'Echo test data',
              'inputSchema': {'type': 'object', 'properties': {}},
            },
          ],
          if (!second) 'nextCursor': 'next',
        };
      case 'tools/call':
        if (params['name'] == 'hang') continue;
        if (params['name'] == 'exit') exit(3);
        if (params['name'] == 'large') {
          stdout.writeln('x' * (2 * 1024 * 1024 + 1));
          continue;
        }
        result = {
          'content': [
            {'type': 'text', 'text': jsonEncode(params['arguments'])},
          ],
          'isError': params['name'] == 'fail',
        };
      default:
        result = {};
    }
    stdout.writeln(
      jsonEncode({'jsonrpc': '2.0', 'id': message['id'], 'result': result}),
    );
  }
}
