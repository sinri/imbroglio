import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/ui/agent_page.dart';
import 'package:imbroglio/src/core/models.dart';

void main() {
  testWidgets('renders Markdown and copies original source', (tester) async {
    const text = '# Heading\n\n**Bold**\n\n- item\n\n```dart\nprint(1);\n```';
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = call.arguments['text'];
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AgentResponse(content: text)),
      ),
    );
    expect(find.byType(MarkdownBody), findsOneWidget);
    await tester.tap(find.byTooltip('复制 Markdown'));
    await tester.pump();
    expect(copied, text);
    expect(find.text('已复制'), findsOneWidget);
  });
  testWidgets('many sources stay compact and open from a bounded list', (
    tester,
  ) async {
    final sources = {
      for (var i = 1; i <= 100; i++)
        'S$i': ResourceRef(
          accountId: 'a',
          id: '$i',
          title: '来源 $i：很长的引用标题，用于检查窄窗口布局',
        ),
    };
    ResourceRef? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 320,
              child: AgentSources(
                sources: sources,
                onOpen: (source) => opened = source,
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ListTile), findsNothing);
    expect(tester.getSize(find.byType(AgentSources)).height, lessThan(60));
    await tester.tap(find.text('参考来源 · 100'));
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(AgentSources)).height,
      lessThanOrEqualTo(300),
    );
    await tester.tap(find.text('[S1]'));
    expect(opened, same(sources['S1']));
    await tester.drag(find.byType(ListView), const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('参考来源 · 100 · 收起'));
    await tester.pumpAndSettle();
    expect(find.byType(ListTile), findsNothing);
  });
  testWidgets('tool rounds collapse together without hiding final answers', (
    tester,
  ) async {
    final history = <Map<String, dynamic>>[
      {'role': 'user', 'content': '问题'},
      {
        'role': 'assistant',
        'content': '正在检索',
        'tool_calls': [
          {
            'id': 'one',
            'function': {'name': 'search', 'arguments': '{"query":"test"}'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'one', 'content': '检索结果'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'two',
            'function': {'name': 'read_source', 'arguments': '{}'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'two', 'content': '来源正文'},
      {'role': 'assistant', 'content': '最终回复'},
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            child: ListView(
              children: agentHistoryItems(history, 'session').toList(),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(AgentProcess), findsOneWidget);
    expect(find.text('最终回复'), findsOneWidget);
    expect(find.text('正在检索'), findsNothing);
    await tester.tap(find.text('执行过程 · 2 次工具调用'));
    await tester.pumpAndSettle();
    expect(find.text('正在检索'), findsOneWidget);
    expect(find.text('search'), findsOneWidget);
    expect(find.textContaining('参数\n'), findsNothing);
    await tester.tap(find.text('search'));
    await tester.pumpAndSettle();
    expect(find.textContaining('参数\n{"query":"test"}'), findsOneWidget);
    expect(
      tester
          .getSize(
            find.descendant(
              of: find.byType(AgentProcess),
              matching: find.byType(ListView),
            ),
          )
          .height,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('执行过程 · 2 次工具调用 · 收起'));
    await tester.pumpAndSettle();
    expect(find.text('正在检索'), findsNothing);
    expect(find.text('最终回复'), findsOneWidget);
  });
}
