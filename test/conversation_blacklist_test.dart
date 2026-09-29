import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/messages.dart';
import 'package:imbroglio/src/core/conversation_blacklist.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/conversation_blacklist.dart';
import 'sync_test.dart' show FakeRpc;

void main() {
  const chat = Conversation(
    accountId: 'a',
    id: 'c',
    title: '通知群',
    watched: true,
  );
  late Workspace w;
  late List<String> calls;
  setUp(() async {
    calls = [];
    w = Workspace()
      ..store = Store(NativeDatabase.memory())
      ..accounts = [
        const AccountRef(id: 'a', platform: 'dingtalk', label: '账号'),
      ]
      ..conversations = [chat];
    await w.store.init();
    w.clients['a'] = FakeRpc((method, _) {
      calls.add(method);
      return {'items': [], 'hasMore': false};
    });
  });
  tearDown(() => w.close());
  Future<void> exclude() =>
      w.saveConversationBlacklist([ConversationBlacklistRule(pattern: '通知*')]);

  test('glob escapes regex, matches whole name and honors account scope', () {
    expect(ConversationBlacklistRule(pattern: '通知?').matches(chat), isTrue);
    expect(ConversationBlacklistRule(pattern: '通知').matches(chat), isFalse);
    expect(ConversationBlacklistRule(pattern: '通知.*').matches(chat), isFalse);
    expect(
      ConversationBlacklistRule(pattern: '*', accountId: 'b').matches(chat),
      isFalse,
    );
    expect(
      ConversationBlacklistRule(pattern: '知', regex: true).matches(chat),
      isTrue,
    );
    expect(
      () => ConversationBlacklistRule(pattern: '[', regex: true),
      throwsFormatException,
    );
    expect(
      () => ConversationBlacklistRule(pattern: ' '),
      throwsFormatException,
    );
  });

  test(
    'excluded selection fetches once; automatic history and polling stay excluded; removal resumes',
    () async {
      await exclude();
      await w.loadSyncPolicies();
      expect(w.isConversationExcluded(chat), isTrue);
      expect(w.backgroundPending, 0);
      await w.selectConversation(chat);
      expect(calls, ['messages']);
      expect(w.isConversationExcluded(chat), isTrue);
      calls.clear();
      await w.showEarlierMessages();
      expect(calls, isEmpty);
      w.tick();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(calls, isNot(contains('messages')));
      expect(calls, isNot(contains('subscribe')));
      expect(w.conversations, hasLength(1));
      await w.saveConversationBlacklist([]);
      await w.syncConversation(chat);
      expect(calls, contains('messages'));
      expect(calls, contains('subscribe'));
    },
  );

  test(
    'manual fetch works without subscription and preserves exclusion',
    () async {
      await exclude();
      await w.syncConversation(chat, manual: true);
      expect(calls, ['messages']);
      expect(w.isConversationExcluded(chat), isTrue);
      await w.syncConversation(chat);
      expect(calls, ['messages']);
    },
  );

  testWidgets(
    'excluded conversation remains visible, searchable and fetches on click',
    (tester) async {
      await exclude();
      await tester.binding.setSurfaceSize(const Size(1120, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [workspaceProvider.overrideWith((ref) => w)],
          child: MaterialApp(
            home: Scaffold(body: MessagesPage(onSetup: () {})),
          ),
        ),
      );
      expect(find.text('通知群'), findsOneWidget);
      final search = find.byWidgetPredicate(
        (v) => v is TextField && v.decoration?.hintText == '筛选会话',
      );
      await tester.enterText(search, '不存在');
      await tester.pump();
      expect(find.text('通知群'), findsNothing);
      await tester.enterText(search, '通知');
      await tester.pump();
      expect(find.text('通知群'), findsOneWidget);
      await tester.tap(find.text('通知群'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(calls.where((m) => m == 'messages'), hasLength(1));
      expect(calls, isNot(contains('subscribe')));
      expect(w.selectedConversation?.key, chat.key);
      expect(w.isConversationExcluded(chat), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  test('new rule unsubscribes an existing stream', () async {
    await w.syncConversation(chat);
    await exclude();
    expect(calls, ['messages', 'subscribe', 'unsubscribe']);
  });

  test('rule added during subscribe stops the late subscription', () async {
    final subscribed = Completer<void>();
    final release = Completer<Json>();
    w.clients['a'] = FakeRpc((method, _) {
      calls.add(method);
      if (method == 'subscribe') {
        subscribed.complete();
        return release.future;
      }
      return {'items': []};
    });
    final running = w.syncConversation(chat);
    await subscribed.future;
    await exclude();
    release.complete({});
    await running;
    expect(calls, ['messages', 'subscribe', 'unsubscribe', 'unsubscribe']);
  });

  test('conversation refresh applies rules to renamed conversations', () async {
    await w.saveConversationBlacklist([
      ConversationBlacklistRule(pattern: '归档*'),
    ]);
    await w.syncConversation(chat);
    w.clients['a'] = FakeRpc((method, _) {
      calls.add(method);
      return {
        'items': method == 'conversations'
            ? [
                {...chat.toJson(), 'title': '归档群'},
              ]
            : [],
      };
    });
    await w.refreshConversations(w.accounts.single);
    expect(w.isConversationExcluded(chat), isTrue);
    expect(calls.last, 'unsubscribe');
    final before = calls.length;
    await w.syncConversation(chat);
    expect(calls.length, before);
  });

  test(
    'rule added during request discards response without advancing cursor',
    () async {
      final response = Completer<Json>();
      final started = Completer<void>();
      w.clients['a'] = FakeRpc((method, _) {
        calls.add(method);
        if (method == 'messages') {
          started.complete();
          return response.future;
        }
        return {};
      });
      final running = w.syncConversation(chat);
      await started.future;
      await exclude();
      response.complete({
        'items': [
          Message(
            accountId: 'a',
            conversationId: 'c',
            id: 'm',
            timestamp: DateTime.now().millisecondsSinceEpoch,
            text: 'ignored',
          ).toJson(),
        ],
      });
      await running;
      expect(await w.store.list('messages'), isEmpty);
      expect(await w.store.get('cursors', chat.key), isNull);
      expect(calls, ['messages']);
    },
  );

  testWidgets(
    'click focuses rule input and Chinese composition survives rebuilds',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => ConversationBlacklistDialog(workspace: w),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新增规则'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText))
            .focusNode
            .hasFocus,
        isTrue,
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(editable.focusNode.hasFocus, isTrue);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'tong',
          selection: TextSelection.collapsed(offset: 4),
          composing: TextRange(start: 0, end: 4),
        ),
      );
      await tester.pump();
      expect(
        editable.controller.value.composing,
        const TextRange(start: 0, end: 4),
      );
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '通知*',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(editable.controller.text, '通知*');
      expect(editable.focusNode.hasFocus, isTrue);
      expect(find.text('当前已加载会话命中 1 个'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> openRules(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ConversationBlacklistDialog(workspace: w),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
  }

  Future<void> saveEditor(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, '保存规则'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(ConversationBlacklistDialog), findsOneWidget);
  }

  for (final regex in [false, true]) {
    testWidgets(
      'new rule editor validates and saves then returns to list (regex: $regex)',
      (tester) async {
        await w.saveConversationBlacklist([
          ConversationBlacklistRule(pattern: '已有*'),
        ]);
        await openRules(tester);
        expect(find.text('已有*'), findsOneWidget);
        await tester.tap(find.text('新增规则'));
        await tester.pumpAndSettle();
        if (regex) {
          await tester.tap(find.byType(SwitchListTile));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), '[');
          await tester.pump();
          expect(
            tester
                .widget<FilledButton>(find.widgetWithText(FilledButton, '保存规则'))
                .onPressed,
            isNull,
          );
          expect(find.text('请输入有效的规则'), findsOneWidget);
        }
        await tester.enterText(find.byType(TextField), regex ? '^通知.*' : '通知*');
        await tester.pump();
        expect(find.text('当前已加载会话命中 1 个'), findsOneWidget);
        await saveEditor(tester);
        expect(w.conversationBlacklist, hasLength(2));
        expect(w.conversationBlacklist.first.pattern, '已有*');
        expect(w.conversationBlacklist.last.regex, regex);
        await w.loadSyncPolicies();
        expect(w.isConversationExcluded(chat), isTrue);
        expect(w.conversationBlacklist, hasLength(2));
      },
    );
  }

  testWidgets(
    'edit preloads rule, cancel keeps original, save replaces it and delete persists',
    (tester) async {
      await w.saveConversationBlacklist([
        ConversationBlacklistRule(pattern: '^原规则', regex: true, accountId: 'a'),
      ]);
      await openRules(tester);
      await tester.tap(find.byTooltip('编辑规则'));
      await tester.pumpAndSettle();
      expect(find.text('编辑黑名单规则'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '^原规则',
      );
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await tester.enterText(find.byType(TextField), '放弃的修改');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(w.conversationBlacklist.single.pattern, '^原规则');
      await tester.tap(find.byTooltip('编辑规则'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '^通知');
      await tester.pump();
      await saveEditor(tester);
      expect(w.conversationBlacklist, hasLength(1));
      expect(w.conversationBlacklist.single.pattern, '^通知');
      expect(w.conversationBlacklist.single.accountId, 'a');
      expect(w.isConversationExcluded(chat), isTrue);
      await tester.tap(find.byTooltip('删除规则'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无规则'), findsOneWidget);
      await w.loadSyncPolicies();
      expect(w.conversationBlacklist, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel new rule returns to empty list without saving', (
    tester,
  ) async {
    await openRules(tester);
    await tester.tap(find.text('新增规则'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '通知*');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(w.conversationBlacklist, isEmpty);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.byType(ConversationBlacklistDialog), findsNothing);
  });
}
