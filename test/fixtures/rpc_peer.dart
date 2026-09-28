import 'dart:async';
import 'dart:convert';
import 'dart:io';

void main() {
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final request = jsonDecode(line) as Map;
    final method = request['method'];
    if (method == 'shutdown') {
      stdout.writeln(jsonEncode({'id': request['id'], 'result': {}}));
      exit(0);
    }
    if (method == 'crash') {
      stderr.writeln('fatal test failure access_token=hidden-secret');
      exit(7);
    }
    if (method == 'hang' || method == 'cancel') return;
    Timer(
      Duration(milliseconds: method == 'slow' ? 40 : 1),
      () => stdout.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': {'method': method},
        }),
      ),
    );
  });
}
