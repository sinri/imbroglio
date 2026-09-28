import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/ui/app.dart';

void main() {
  test('sync recovery preserves distinct unacknowledged errors', () {
    final state = SyncState(error: '首次错误');
    state.error = '';
    expect(state.error, isEmpty);
    expect(state.pendingErrors, ['首次错误']);
    state.error = '第二次错误';
    state.error = '第二次错误';
    expect(state.pendingErrors, ['首次错误', '第二次错误']);
    state.pendingErrors.remove('首次错误');
    expect(state.error, '第二次错误');
    state.error = '首次错误';
    expect(state.pendingErrors, ['第二次错误', '首次错误']);
  });

  testWidgets('operation errors persist and queued errors require closing', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (value) {
              context = value;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await guarded(context, () async => throw StateError('操作失败一'));
    await guarded(context, () async => throw StateError('操作失败二'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(hours: 1));
    expect(find.textContaining('操作失败一'), findsOneWidget);
    expect(find.textContaining('操作失败二'), findsNothing);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.textContaining('操作失败一'), findsNothing);
    expect(find.textContaining('操作失败二'), findsOneWidget);
    await tester.pump(const Duration(hours: 1));
    expect(find.textContaining('操作失败二'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });
}
