import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/search.dart';

class SearchWorkspace extends Workspace {
  String? submittedQuery;

  @override
  Future<List<ResourceRef>> search(
    String query,
    Set<String> scope, {
    bool online = true,
  }) async {
    submittedQuery = query;
    return [];
  }
}

void main() {
  testWidgets('search accepts Chinese input across workspace updates', (
    tester,
  ) async {
    final workspace = SearchWorkspace()
      ..accounts = [const AccountRef(id: 'a', platform: 'feishu', label: '账号')]
      ..selectedAccount = 'a';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => workspace)],
        child: MaterialApp(
          home: Scaffold(body: SearchPage(onMessage: () {})),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '项目资料',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 2, end: 4),
      ),
    );
    workspace.changed();
    await tester.pump();
    final editable = tester.widget<EditableText>(find.byType(EditableText));
    expect(editable.focusNode.hasFocus, isTrue);
    expect(editable.controller.text, '项目资料');
    expect(
      editable.controller.value.composing,
      const TextRange(start: 2, end: 4),
    );
    await tester.enterText(find.byType(TextField), '项目资料');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(workspace.submittedQuery, '项目资料');
  });
}
