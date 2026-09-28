import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:imbroglio/src/core/normalize.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/messages.dart';
import 'package:imbroglio/src/ui/message_content.dart';
import 'sync_test.dart' show FakeRpc;

void main() {
  late Workspace w;
  final temporaryDirectories = <Directory>[];
  const chat = Conversation(accountId: 'a', id: 'c', title: '测试群');
  setUp(() async {
    w = Workspace()
      ..store = Store(NativeDatabase.memory())
      ..accounts = [
        const AccountRef(
          id: 'a',
          platform: 'feishu',
          label: '账号',
          enabled: false,
        ),
      ]
      ..conversations = [chat];
    await w.store.init();
  });
  tearDown(() async {
    await w.close();
    for (final dir in temporaryDirectories) {
      await dir.delete(recursive: true);
    }
    temporaryDirectories.clear();
  });

  Future<void> open(WidgetTester tester) async {
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
    await tester.tap(find.text('测试群'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('text-only cached Markdown and rich nodes render automatically', (
    tester,
  ) async {
    final messages = [
      normalizeMessage('a', 'c', {'id': 'md', 'text': '# 自动标题\n\n**加粗**'}),
      normalizeMessage('a', 'c', {
        'id': 'rich',
        'content': {
          'richText': [
            {
              'tag': 'text',
              'text': '结构文本',
              'style': ['bold'],
            },
          ],
        },
      }),
    ];
    for (final m in messages) {
      await w.store.saveMessage(m);
    }
    await open(tester);
    expect(find.byType(MarkdownBody), findsNWidgets(2));
    for (final element in find.byType(MessageContent).evaluate()) {
      final bubble = find.byWidget(element.widget);
      expect(
        find.descendant(of: bubble, matching: find.byType(Scrollable)),
        findsNothing,
      );
      expect(
        find.ancestor(of: bubble, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
    }
    expect(tester.takeException(), isNull);
  });

  test(
    'old DingTalk cache displays sender label and keeps message avatar when profile is empty',
    () {
      const m = Message(
        accountId: 'a',
        conversationId: 'c',
        id: 'm',
        text: '',
        timestamp: 0,
        senderId: 'staff1',
        extra: {
          'raw': {
            'sender': '张三',
            'senderId': 'staff1',
            'senderAvatar': 'https://example.com/avatar.png',
          },
        },
      );
      w.senderProfiles[compositeKey('a', 'staff1')] = {
        'name': '',
        'avatar': '',
      };
      expect(senderName(w, m), '张三');
      expect(senderAvatar(w, m), 'https://example.com/avatar.png');
    },
  );

  testWidgets(
    'cached text markers render multiple images while preserving surrounding text',
    (tester) async {
      final file = (await tester.runAsync<File>(() async {
        final dir = await Directory.systemTemp.createTemp('imbroglio-inline-');
        temporaryDirectories.add(dir);
        w.root = dir.path;
        final file = File('${dir.path}/accounts/a/downloads/image.png');
        await file.parent.create(recursive: true);
        await File('assets/tray.png').copy(file.path);
        return file;
      }))!;
      final resources = <String>[];
      w.clients['a'] = FakeRpc((method, args) {
        expect(method, 'attachment.download');
        expect(object(args['message'])['id'], 'images');
        resources.add(args['resourceId'] as String);
        return {'path': file.path};
      });
      await w.store.saveMessage(
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'images',
          text: '前文[图片消息](mediaId=%40one)中间[图片消息](mediaId=two)后文',
          timestamp: 1,
        ),
      );
      await open(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(resources, containsAll(['@one', 'two']));
      expect(find.text('前文'), findsOneWidget);
      expect(find.text('中间'), findsOneWidget);
      expect(find.text('后文'), findsOneWidget);
      final body = find.byType(MessageContent);
      expect(
        find.descendant(of: body, matching: find.byType(Image)),
        findsNWidgets(2),
      );
      expect(find.textContaining('[图片消息]'), findsNothing);
      expect(
        find.descendant(of: body, matching: find.byType(Scrollable)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed inline image can be retried', (tester) async {
    final file = (await tester.runAsync<File>(() async {
      final dir = await Directory.systemTemp.createTemp('imbroglio-retry-');
      temporaryDirectories.add(dir);
      w.root = dir.path;
      final file = File('${dir.path}/accounts/a/downloads/image.png');
      await file.parent.create(recursive: true);
      await File('assets/tray.png').copy(file.path);
      return file;
    }))!;
    var calls = 0;
    w.clients['a'] = FakeRpc((method, args) {
      if (++calls == 1) throw const AppFailure('network', 'offline');
      return {'path': file.path};
    });
    await w.store.saveMessage(
      const Message(
        accountId: 'a',
        conversationId: 'c',
        id: 'retry',
        text: '[图片消息](mediaId=one)',
        timestamp: 1,
      ),
    );
    await open(tester);
    expect(find.text('图片加载失败，点击重试'), findsOneWidget);
    await tester.tap(find.text('图片加载失败，点击重试'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.text('图片加载失败，点击重试'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(MessageContent),
        matching: find.byType(Image),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final kind in ['text', 'markdown']) {
    testWidgets('$kind content expands without an inner scrollable', (
      tester,
    ) async {
      final lines = List.generate(70, (i) => '第 $i 行完整消息内容').join('\n');
      final content = kind == 'markdown'
          ? '```text\n$lines\n```\n\n| 标题 | 内容 |\n| --- | --- |\n| 测试 | 可选中文本 |'
          : lines;
      await w.store.saveMessage(
        Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'long',
          text: content,
          timestamp: 1,
          kind: kind,
        ),
      );
      await open(tester);
      final body = find.byType(MessageContent);
      expect(tester.getSize(body).height, greaterThan(740));
      expect(
        find.descendant(of: body, matching: find.byType(Scrollable)),
        findsNothing,
      );
      expect(
        find.descendant(of: body, matching: find.byType(SelectableText)),
        findsNothing,
      );
      expect(
        find.ancestor(of: body, matching: find.byType(SelectionArea)),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('message can be selected and copied, or copied with its button', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        if (call.method == 'Clipboard.hasStrings') {
          return {'value': copied != null};
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await w.store.saveMessage(
      const Message(
        accountId: 'a',
        conversationId: 'c',
        id: 'copy',
        text: '可选中并复制',
        timestamp: 1,
      ),
    );
    await open(tester);
    await tester.longPress(find.text('可选中并复制'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, isNotEmpty);
    copied = null;
    await tester.tap(find.byTooltip('复制消息'));
    await tester.pumpAndSettle();
    expect(copied, '可选中并复制');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'message header shows its full send time instead of sync status',
    (tester) async {
      final sent = DateTime(2026, 9, 28, 14, 5, 9);
      await w.store.saveMessage(
        Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'time',
          text: '有发送时间的消息',
          timestamp: sent.millisecondsSinceEpoch,
          sender: 'Alice',
        ),
      );
      await open(tester);
      expect(find.text('Alice  ·  2026-09-28 14:05:09'), findsOneWidget);
      expect(messageTimeLabel(0), '发送时间未知');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selecting a chat keeps the row and renders cached rich content',
    (tester) async {
      await w.store.saveMessage(
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'm',
          text: '**进度更新**',
          timestamp: 1000,
          sender: 'Alice',
          kind: 'markdown',
          extra: {'senderLookupId': 'u'},
        ),
      );
      await open(tester);
      expect(find.text('测试群'), findsNWidgets(2));
      expect(find.textContaining('Alice'), findsOneWidget);
      expect(find.textContaining('进度更新', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'file attachment displays a named card with size and save action',
    (tester) async {
      await w.store.saveMessage(
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'file',
          text: '',
          timestamp: 1000,
          kind: 'file',
          extra: {
            'raw': {
              'body': {
                'content':
                    '{"file_key":"key","file_name":"报告.pdf","file_size":2048}',
              },
            },
          },
        ),
      );
      await open(tester);
      expect(find.text('报告.pdf'), findsOneWidget);
      expect(find.text('2.0 KB'), findsOneWidget);
      expect(find.byTooltip('保存文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'slow send keeps a later draft and displays sending state immediately',
    (tester) async {
      final result = Completer<Json>();
      w.clients['a'] = FakeRpc((method, args) => result.future);
      await open(tester);
      final composer = find.widgetWithText(TextField, '输入消息…');
      await tester.enterText(composer, '第一条');
      await tester.tap(find.text('发送'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(find.text('第一条'), findsOneWidget);
      await tester.enterText(composer, '下一条草稿');
      result.complete({'messageId': 'sent'});
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('下一条草稿'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
