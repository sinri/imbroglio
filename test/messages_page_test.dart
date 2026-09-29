import 'dart:async';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind, ImageByteFormat;
import 'package:flutter/rendering.dart';
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

  testWidgets(
    'scrolling selected conversation does not paint over the header',
    (tester) async {
      w.conversations = [
        chat,
        ...List.generate(
          30,
          (i) => Conversation(accountId: 'a', id: 'c$i', title: '会话$i'),
        ),
      ];
      w.selectedConversation = chat;
      await tester.binding.setSurfaceSize(const Size(1120, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [workspaceProvider.overrideWith((ref) => w)],
          child: MaterialApp(
            home: RepaintBoundary(
              key: boundaryKey,
              child: Scaffold(body: MessagesPage(onSetup: () {})),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<List<int>> headerPixels() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()
                as RenderRepaintBoundary;
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = (await image.toByteData(
            format: ImageByteFormat.rawRgba,
          ))!;
          final pixels = bytes.buffer
              .asUint8List(0, image.width * 140 * 4)
              .toList();
          image.dispose();
          return pixels;
        }))!;
      }

      final before = await headerPixels();
      final list = find.byType(ListView).first;
      await tester.drag(list, const Offset(0, -180));
      await tester.pumpAndSettle();
      expect(await headerPixels(), before);
      await tester.drag(list, const Offset(0, 180));
      await tester.pumpAndSettle();
      expect(await headerPixels(), before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing sending scope disables send and explains recovery', (
    tester,
  ) async {
    w.accounts = [w.account('a').copyWith(canSend: false)];
    w.clients['a'] = FakeRpc((_, _) => {'items': [], 'hasMore': false});
    await open(tester);
    expect(find.text('缺少发送权限，请到设置为此账号补充发送授权。'), findsOneWidget);
    final send = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '发送'),
    );
    expect(send.onPressed, isNull);
  });

  for (final lastAccount in [false, true]) {
    testWidgets(
      'logout clears selected chat and ${lastAccount ? 'shows setup' : 'selects a remaining account'}',
      (tester) async {
        w.selectedAccount = 'a';
        if (!lastAccount) {
          w.accounts.add(
            const AccountRef(
              id: 'b',
              platform: 'dingtalk',
              label: '保留的钉钉',
              enabled: false,
            ),
          );
          w.conversations.add(
            const Conversation(accountId: 'b', id: 'other', title: '钉钉群'),
          );
        }
        await open(tester);
        expect(w.selectedConversation?.key, chat.key);
        w.clients['a'] = FakeRpc((method, _) => {});
        await w.disconnect(w.account('a'), logout: true);
        await tester.pumpAndSettle();
        expect(w.selectedConversation, isNull);
        expect(w.messages, isEmpty);
        expect(find.text('测试群'), findsNothing);
        expect(w.selectedAccount, lastAccount ? isNull : 'b');
        if (lastAccount) {
          expect(find.text('连接账号'), findsOneWidget);
          expect(find.byType(DropdownButtonFormField<String>), findsNothing);
        } else {
          final dropdown = tester.widget<DropdownButtonFormField<String>>(
            find.byType(DropdownButtonFormField<String>),
          );
          expect(dropdown.initialValue, 'b');
          expect(find.text('钉钉群'), findsOneWidget);
          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          expect(find.text('账号'), findsNothing);
          expect(find.text('保留的钉钉'), findsWidgets);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('persisted signed-out accounts and chats stay hidden', (
    tester,
  ) async {
    await w.store.put(
      'accounts',
      'a',
      w.account('a').copyWith(signedOut: true).toJson(),
    );
    const remaining = AccountRef(
      id: 'b',
      platform: 'dingtalk',
      label: '保留的钉钉',
      enabled: false,
    );
    await w.store.put('accounts', 'b', remaining.toJson());
    w.accounts = (await w.store.list(
      'accounts',
    )).map(AccountRef.fromJson).toList();
    w.selectedAccount = 'a';
    w.changed();
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
    await tester.pumpAndSettle();
    expect(w.selectedAccount, 'b');
    expect(find.text('测试群'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    expect(find.text('账号'), findsNothing);
    expect(find.text('保留的钉钉'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sync errors survive recovery until manually closed', (
    tester,
  ) async {
    final state = SyncState(error: '同步失败');
    w.sync[chat.key] = state;
    await open(tester);
    expect(find.text('同步失败'), findsOneWidget);
    state.error = '';
    w.changed();
    await tester.pumpAndSettle();
    expect(find.text('同步失败'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭错误提示'));
    await tester.pumpAndSettle();
    expect(find.text('同步失败'), findsNothing);
    state.error = '同步失败';
    w.changed();
    await tester.pumpAndSettle();
    expect(find.text('同步失败'), findsOneWidget);
  });

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

  testWidgets('text quoting an image has no download button', (tester) async {
    await w.store.saveMessage(
      normalizeMessage('a', 'c', {
        'id': 'quoted-image-reply',
        'text': '当前消息只有文字',
        'quotedMessage': {'content': '[图片消息](mediaId=quoted-image)'},
      }),
    );
    await open(tester);
    expect(find.text('当前消息只有文字'), findsOneWidget);
    expect(find.byTooltip('下载附件'), findsNothing);
    expect(find.byTooltip('保存文件'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'Feishu avatars survive caching and match sender identity across chats',
    () {
      final normalized = normalizeConversation('a', {
        'chat_id': 'private',
        'name': 'Peer',
        'chat_mode': 'p2p',
        'p2p_target_id': 'ou_peer',
        'avatar': 'https://example.com/peer.png',
      });
      final cached = Conversation.fromJson(
        normalized.copyWith(unread: 1).toJson(),
      );
      expect(cached.kind, 'p2p');
      expect(cached.peerId, 'ou_peer');
      expect(cached.avatar, 'https://example.com/peer.png');
      w.conversations.add(cached);
      Message message(String sender, {Json extra = const {}}) => Message(
        accountId: 'a',
        conversationId: 'c',
        id: 'm',
        text: '',
        timestamp: 0,
        senderId: sender,
        extra: extra,
      );
      expect(senderAvatar(w, message('ou_peer')), cached.avatar);
      expect(senderAvatar(w, message('ou_other')), isEmpty);
      expect(
        senderAvatar(w, message('ou_peer', extra: {'isOwn': true})),
        isEmpty,
      );
      expect(
        senderAvatar(
          w,
          message(
            'ou_peer',
            extra: {'avatar': 'https://example.com/message.png'},
          ),
        ),
        'https://example.com/message.png',
      );
      w.conversations = [
        Conversation(
          accountId: 'other',
          id: 'private',
          title: '',
          kind: 'p2p',
          peerId: 'ou_peer',
          avatar: cached.avatar,
        ),
        Conversation(
          accountId: 'a',
          id: 'group',
          title: '',
          peerId: 'ou_peer',
          avatar: cached.avatar,
        ),
      ];
      expect(senderAvatar(w, message('ou_peer')), isEmpty);
    },
  );

  testWidgets(
    'conversation list uses platform avatar and falls back on image failure',
    (tester) async {
      w.conversations = [
        const Conversation(
          accountId: 'a',
          id: 'c',
          title: '测试群',
          kind: 'p2p',
          avatar: 'https://example.com/chat.png',
        ),
      ];
      await open(tester);
      final avatar = tester.widget<SenderAvatar>(
        find.byType(SenderAvatar).first,
      );
      expect(avatar.url, 'https://example.com/chat.png');
      await tester.pumpAndSettle();
      expect(find.text('测'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets(
    'active selection survives timeline replacement without stale indices',
    (tester) async {
      await w.store.saveMessage(
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'selected',
          text: '选中后替换消息列表',
          timestamp: 1,
        ),
      );
      await open(tester);
      await tester.dragFrom(
        tester.getTopLeft(find.text('选中后替换消息列表')) + const Offset(2, 10),
        const Offset(130, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      w.messages = [];
      w.changed();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      w.messages = [
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'next',
          text: '新的消息',
          timestamp: 2,
        ),
      ];
      w.changed();
      await tester.pumpAndSettle();
      await tester.dragFrom(
        tester.getTopLeft(find.text('新的消息')) + const Offset(2, 10),
        const Offset(60, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      w.selectedConversation = const Conversation(
        accountId: 'a',
        id: 'other',
        title: '另一个会话',
      );
      w.conversations.add(w.selectedConversation!);
      w.messages = [];
      w.changed();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selection belongs to each message and resets only when its content changes',
    (tester) async {
      const first = Message(
        accountId: 'a',
        conversationId: 'c',
        id: 'stable',
        text: '保持选择的正文',
        timestamp: 1,
      );
      await w.store.saveMessage(first);
      await open(tester);
      Finder region() => find.ancestor(
        of: find.text('保持选择的正文'),
        matching: find.byType(SelectionArea),
      );
      final original = tester.state(region());
      await tester.dragFrom(
        tester.getTopLeft(find.text('保持选择的正文')) + const Offset(2, 10),
        const Offset(110, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      w.changed();
      await tester.pumpAndSettle();
      expect(tester.state(region()), same(original));
      w.messages = [
        first,
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'incoming',
          text: '后台收到新消息',
          timestamp: 2,
        ),
      ];
      w.changed();
      await tester.pumpAndSettle();
      expect(tester.state(region()), same(original));
      expect(find.byType(SelectionArea), findsNWidgets(2));
      w.messages = [
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'stable',
          text: '**更新后的正文**',
          kind: 'markdown',
          timestamp: 1,
        ),
      ];
      w.changed();
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(SelectionArea)), isNot(same(original)));
      expect(tester.takeException(), isNull);
      await tester.drag(
        find.byType(ListView).last,
        const Offset(0, 500),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets('failed send stays in its message row without a snackbar', (
    tester,
  ) async {
    w.clients['a'] = FakeRpc(
      (method, args) => throw const AppFailure('authorization', '无发送权限'),
    );
    await open(tester);
    await tester.enterText(find.widgetWithText(TextField, '输入消息…'), '失败的消息');
    await tester.tap(find.text('发送'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    final row = find.byKey(ValueKey('outbox:${w.outbox.single['id']}'));
    expect(
      find.descendant(of: row, matching: find.text('失败的消息')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.textContaining('发送失败')),
      findsOneWidget,
    );
    expect(find.byType(SnackBar), findsNothing);
    await tester.pump(const Duration(minutes: 10));
    expect(find.textContaining('发送失败'), findsOneWidget);
    await tester.tap(find.byTooltip('关闭错误提示'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('发送失败'), findsNothing);
    expect(find.text('失败的消息'), findsOneWidget);
    expect(w.outbox.single['state'], 'failed');
  });

  test(
    'timeline merges platform aliases and does not truncate pending sends',
    () {
      w.outbox = List.generate(
        12,
        (i) => <String, dynamic>{
          'id': '$i',
          'accountId': 'a',
          'conversationId': 'c',
          'text': '消息$i',
          'timestamp': i,
          'state': 'confirmed',
          'result': {'messageId': 'open-$i'},
        },
      );
      w.messages = [
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'platform-id',
          text: '消息0',
          timestamp: 0,
          extra: {
            'raw': {'openMessageId': 'open-0'},
          },
        ),
      ];
      final timeline = messageTimeline(w, chat);
      expect(timeline, hasLength(12));
      expect(timeline.first.id, 'platform-id');
      expect(timeline.first.extra['timelineKey'], 'outbox:0');
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
      expect(find.text('发送中…'), findsOneWidget);
      final rowKey = ValueKey('outbox:${w.outbox.single['id']}');
      expect(find.byKey(rowKey), findsOneWidget);
      await tester.enterText(composer, '下一条草稿');
      result.complete({'messageId': 'sent'});
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('下一条草稿'), findsOneWidget);
      expect(find.text('第一条'), findsOneWidget);
      expect(find.text('发送中…'), findsNothing);
      expect(find.text('已确认发送'), findsNothing);
      expect(find.byKey(rowKey), findsOneWidget);
      w.messages = [
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'sent',
          text: '第一条',
          timestamp: 1,
        ),
      ];
      w.changed();
      await tester.pumpAndSettle();
      expect(find.text('第一条'), findsOneWidget);
      expect(find.byKey(rowKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
