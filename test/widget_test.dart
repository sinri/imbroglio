import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';

void main() {
  testWidgets('startup failure is visible rather than an empty shell', (
    tester,
  ) async {
    final workspace = Workspace()..fatal = 'test failure';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => workspace)],
        child: const ImbroglioApp(),
      ),
    );
    expect(find.textContaining('test failure'), findsOneWidget);
  });
}
