import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/services/store.dart';

void main() {
  test(
    'batch state lookup crosses chunks and preserves missing/bucket boundaries',
    () async {
      final store = Store(NativeDatabase.memory());
      try {
        await store.init();
        await store.db.transaction(() async {
          for (var i = 0; i < 1005; i++) {
            await store.put('readState', 'c$i', {
              'timestamp': i,
              'platformTime': i + 1,
            });
          }
          await store.put('cursors', 'c0', {'historyDone': true});
        });
        final keys = [...List.generate(1005, (i) => 'c$i'), 'missing', 'c0'];
        final reads = await store.getMany('readState', keys);
        expect(reads.length, 1005);
        expect(reads['c0'], {'timestamp': 0, 'platformTime': 1});
        expect(reads['c1004'], {'timestamp': 1004, 'platformTime': 1005});
        expect(reads.containsKey('missing'), isFalse);
        expect(await store.getMany('cursors', keys), {
          'c0': {'historyDone': true},
        });
        expect(await store.getMany('readState', []), isEmpty);
      } finally {
        await store.close();
      }
    },
  );
}
