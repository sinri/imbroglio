import '../core/models.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'search.dart';

class AgentPage extends ConsumerStatefulWidget {
  final bool compact;
  const AgentPage({super.key, this.compact = false});
  @override
  ConsumerState<AgentPage> createState() => _AgentPageState();
}

class _AgentPageState extends ConsumerState<AgentPage> {
  final input = TextEditingController();
  final transcript = ScrollController();
  String? lastSession;
  Object? lastContent;
  bool followTail = true;

  @override
  void initState() {
    super.initState();
    transcript.addListener(() {
      followTail = transcript.position.extentAfter < 100;
    });
  }

  final scope = <String>{};
  String? pluginId;
  bool scopeChosen = false;
  @override
  void dispose() {
    transcript.dispose();
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = ref.watch(workspaceProvider), agent = ref.watch(agentProvider);
    final plugins = w.packages
        .where((p) => p['kind'] == 'agent' && p['enabled'] == true)
        .toList();
    scope.retainAll(w.visibleAccounts.map((a) => a.id));
    if (!scopeChosen && w.selectedAccount != null) {
      scope.add(w.selectedAccount!);
      scopeChosen = true;
    }
    if (!plugins.any((p) => p['id'] == pluginId)) {
      pluginId = plugins.firstOrNull?['id'];
    }
    final display = agent.history.where((m) => m['role'] != 'system').toList();
    final content = (
      agent.history.length,
      agent.streaming,
      agent.pending,
      agent.error,
      agent.running,
    );
    final changedSession = lastSession != agent.sessionId;
    if (changedSession || content != lastContent) {
      final scroll = changedSession || followTail;
      lastSession = agent.sessionId;
      lastContent = content;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && scroll && transcript.hasClients) {
          transcript.jumpTo(transcript.position.maxScrollExtent);
        }
      });
    }
    final colors = Theme.of(context).colorScheme;
    final title = display
        .where((m) => m['role'] == 'user')
        .firstOrNull?['content'];
    void submit() {
      if (agent.running || pluginId == null || input.text.trim().isEmpty) {
        return;
      }
      followTail = true;
      final prompt = input.text;
      input.clear();
      agent.run(prompt, scope, plugins.firstWhere((p) => p['id'] == pluginId));
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title == null ? '新会话' : '$title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: '新会话',
                onPressed: agent.running ? null : agent.newSession,
                icon: const Icon(Icons.edit_square, size: 20),
              ),
              IconButton(
                tooltip: '历史会话',
                onPressed: agent.running ? null : sessions,
                icon: const Icon(Icons.history, size: 20),
              ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final side = constraints.maxWidth > 900
                  ? (constraints.maxWidth - 852) / 2
                  : 20.0;
              return ListView(
                controller: transcript,
                padding: EdgeInsets.fromLTRB(side, 24, side, 24),
                children: [
                  if (display.isEmpty && !agent.running)
                    Padding(
                      padding: EdgeInsets.only(
                        top: constraints.maxHeight > 350 ? 80 : 8,
                        bottom: 24,
                      ),
                      child: Column(
                        children: [
                          Icon(
                            Icons.auto_awesome_outlined,
                            size: 32,
                            color: colors.onSurfaceVariant,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            '今天想完成什么？',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '从会话和资料中查找答案，或交给 Agent 处理任务',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                          const SizedBox(height: 24),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              for (final prompt in [
                                '总结最近的会话',
                                '查找相关资料',
                                '整理待办事项',
                              ])
                                ActionChip(
                                  label: Text(prompt),
                                  onPressed: () {
                                    input.text = prompt;
                                    input.selection = TextSelection.collapsed(
                                      offset: prompt.length,
                                    );
                                  },
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ...agentHistoryItems(display, agent.sessionId),
                  if (agent.streaming.isNotEmpty)
                    AgentResponse(content: agent.streaming),
                  if (agent.running)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              agent.retryStatus.isNotEmpty
                                  ? agent.retryStatus
                                  : agent.pending != null
                                  ? '等待你的确认'
                                  : '正在处理…',
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (agent.sources.isNotEmpty)
                    AgentSources(
                      key: ValueKey(agent.sessionId),
                      sources: agent.sources,
                      onOpen: (source) => openResource(context, ref, source),
                    ),
                  if (agent.pendingErrors.isNotEmpty)
                    ErrorNotices(
                      errors: agent.pendingErrors,
                      onDismiss: agent.dismissError,
                    ),
                  if (agent.canRetry)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: agent.retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试并继续'),
                      ),
                    ),
                  if (agent.pending != null)
                    Card(
                      color: Theme.of(context).colorScheme.tertiaryContainer,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '确认业务操作',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 8),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxHeight: 160),
                              child: SingleChildScrollView(
                                child: SelectableText(
                                  operationSummary(agent.pending!, w),
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                TextButton(
                                  onPressed: () => agent.decide(false),
                                  child: const Text('拒绝'),
                                ),
                                const Spacer(),
                                FilledButton(
                                  onPressed: () => agent.decide(true),
                                  child: const Text('确认执行'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 884),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  widget.compact ? 12 : 16,
                  8,
                  widget.compact ? 12 : 16,
                  12,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: colors.surfaceContainerLow,
                        border: Border.all(color: colors.outlineVariant),
                        borderRadius: BorderRadius.circular(22),
                      ),
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CallbackShortcuts(
                            bindings: {
                              const SingleActivator(
                                LogicalKeyboardKey.enter,
                                meta: true,
                              ): submit,
                              const SingleActivator(
                                LogicalKeyboardKey.enter,
                                control: true,
                              ): submit,
                            },
                            child: TextField(
                              controller: input,
                              minLines: 2,
                              maxLines: 5,
                              enabled: !agent.running,
                              decoration: const InputDecoration(
                                hintText: '发送消息，或描述要完成的任务',
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                                contentPadding: EdgeInsets.fromLTRB(
                                  4,
                                  4,
                                  4,
                                  12,
                                ),
                              ),
                            ),
                          ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Expanded(
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 4,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 200,
                                      ),
                                      child: DropdownButtonHideUnderline(
                                        child: DropdownButton<String>(
                                          value: pluginId,
                                          isDense: true,
                                          isExpanded: true,
                                          hint: const Text('选择 Agent'),
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelMedium,
                                          items: plugins
                                              .map(
                                                (p) => DropdownMenuItem<String>(
                                                  value: p['id'],
                                                  child: Text(
                                                    p['name'],
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ),
                                              )
                                              .toList(),
                                          onChanged: agent.running
                                              ? null
                                              : (id) => setState(
                                                  () => pluginId = id,
                                                ),
                                        ),
                                      ),
                                    ),
                                    TextButton.icon(
                                      onPressed: agent.running
                                          ? null
                                          : selectAccounts,
                                      icon: const Icon(
                                        Icons.account_circle_outlined,
                                        size: 16,
                                      ),
                                      label: Text('${scope.length} 个账号'),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              if (agent.running)
                                IconButton.filled(
                                  tooltip: '停止',
                                  onPressed: agent.cancel,
                                  icon: const Icon(
                                    Icons.stop_rounded,
                                    size: 20,
                                  ),
                                )
                              else
                                ValueListenableBuilder<TextEditingValue>(
                                  valueListenable: input,
                                  builder: (context, value, _) =>
                                      IconButton.filled(
                                        tooltip: '发送（⌘ / Ctrl + Enter）',
                                        onPressed:
                                            pluginId == null ||
                                                value.text.trim().isEmpty
                                            ? null
                                            : submit,
                                        icon: const Icon(
                                          Icons.arrow_upward,
                                          size: 20,
                                        ),
                                      ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '读取自动执行 · 对外写入需确认 · 资料将发送至配置的模型服务',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> selectAccounts() async {
    final w = ref.read(workspaceProvider);
    final selected = Set<String>.of(scope);
    final applied = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('选择资料范围'),
          content: SizedBox(
            width: 360,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Agent 仅使用所选账号的资料。更换已有会话的账号范围前，请先新建会话。'),
                  const SizedBox(height: 12),
                  if (w.visibleAccounts.isEmpty) const Text('暂无可用账号，请先在设置中添加'),
                  for (final account in w.visibleAccounts)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(account.label),
                      value: selected.contains(account.id),
                      onChanged: (value) => update(() {
                        value == true
                            ? selected.add(account.id)
                            : selected.remove(account.id);
                      }),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    if (applied == true && mounted) {
      setState(() {
        scopeChosen = true;
        scope
          ..clear()
          ..addAll(selected);
      });
    }
  }

  Future<void> sessions() async {
    final records = await ref
        .read(workspaceProvider)
        .store
        .list('agentSessions');
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('历史会话'),
        children: records
            .map(
              (r) => SimpleDialogOption(
                onPressed: () {
                  ref.read(agentProvider).loadSession(r);
                  Navigator.pop(context);
                },
                child: Text(
                  '${r['title']}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

String operationSummary(Json preview, Workspace workspace) {
  final args = object(preview['arguments']);
  final name =
      {
        'mcp_call': '调用 MCP 工具',
        'run_script': '执行本地脚本',
        'send_message': '发送消息',
        'create_document': '创建文档',
        'create_task': '创建待办',
      }[preview['tool']] ??
      '业务操作';
  final lines = ['$name · ${preview['account']}'];
  if (args['conversation'] != null) {
    final chat = workspace.conversations
        .where(
          (c) => c.accountId == args['account'] && c.id == args['conversation'],
        )
        .firstOrNull;
    lines.add('会话：${chat?.title ?? args['conversation']}');
  }
  for (final field in {
    'server': 'MCP 服务器',
    'mcpTool': '工具',
    'script': '脚本',
    'interpreter': '解释器',
    'path': '文件',
    'input': '输入 JSON',
    'title': '标题',
    'assignee': '执行者',
    'due': '截止时间',
    'text': '消息内容',
    'content': '文档正文',
  }.entries) {
    final value = args[field.key];
    if (value != null && '$value'.isNotEmpty) {
      lines.add('${field.value}：$value');
    }
  }
  return lines.join('\n\n');
}

class AgentResponse extends StatelessWidget {
  final String content;
  const AgentResponse({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MarkdownBody(
          data: content,
          selectable: true,
          styleSheet: MarkdownStyleSheet(
            p: const TextStyle(height: 1.6),
            tableColumnWidth: const FlexColumnWidth(),
          ),
          imageBuilder: (_, _, _) => const Text('[图片链接]'),
          onTapLink: (_, href, _) {
            final uri = Uri.tryParse(href ?? '');
            if (uri != null && ['https', 'http'].contains(uri.scheme)) {
              launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
        ),
        if (content.isNotEmpty)
          IconButton(
            tooltip: '复制 Markdown',
            icon: const Icon(Icons.copy_outlined, size: 18),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: content));
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('已复制')));
              }
            },
          ),
      ],
    );
  }
}

/// Keep the source collection compact even when a search returns many matches.
class AgentSources extends StatefulWidget {
  final Map<String, ResourceRef> sources;
  final ValueChanged<ResourceRef> onOpen;
  const AgentSources({super.key, required this.sources, required this.onOpen});

  @override
  State<AgentSources> createState() => _AgentSourcesState();
}

class _AgentSourcesState extends State<AgentSources> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final entries = widget.sources.entries.toList();
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextButton.icon(
          onPressed: () => setState(() => expanded = !expanded),
          icon: Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
          label: Text('参考来源 · ${entries.length}${expanded ? ' · 收起' : ''}'),
        ),
        if (expanded)
          Container(
            constraints: const BoxConstraints(maxHeight: 240),
            decoration: BoxDecoration(
              border: Border.all(color: colors.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: ListView.separated(
              primary: false,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final entry = entries[index];
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Text(
                    '[${entry.key}]',
                    style: TextStyle(color: colors.primary, fontSize: 12),
                  ),
                  title: Text(
                    entry.value.title.isEmpty ? '未命名来源' : entry.value.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  onTap: () => widget.onOpen(entry.value),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// Group consecutive tool rounds; user messages and final answers stay visible.
Iterable<Widget> agentHistoryItems(List<Json> history, String sessionId) sync* {
  bool isProcess(Json message) =>
      message['role'] == 'tool' ||
      (message['role'] == 'assistant' &&
          (message['tool_calls'] as List? ?? []).isNotEmpty);
  for (var i = 0; i < history.length;) {
    final start = i;
    if (isProcess(history[i])) {
      final steps = <Json>[];
      while (i < history.length && isProcess(history[i])) {
        steps.add(history[i++]);
      }
      yield AgentProcess(
        key: ValueKey('$sessionId-process-$start'),
        steps: steps,
      );
    } else {
      final message = history[i++];
      yield Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: message['role'] == 'assistant'
            ? AgentResponse(content: '${message['content'] ?? ''}')
            : Align(
                alignment: Alignment.centerRight,
                child: FractionallySizedBox(
                  widthFactor: 0.85,
                  alignment: Alignment.centerRight,
                  child: Builder(
                    builder: (context) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: SelectableText(
                        '${message['content'] ?? ''}',
                        style: const TextStyle(height: 1.6),
                      ),
                    ),
                  ),
                ),
              ),
      );
    }
  }
}

class AgentProcess extends StatefulWidget {
  final List<Json> steps;
  const AgentProcess({super.key, required this.steps});

  @override
  State<AgentProcess> createState() => _AgentProcessState();
}

class _AgentProcessState extends State<AgentProcess> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final calls = widget.steps
        .expand((m) => m['tool_calls'] as List? ?? [])
        .toList();
    final results = {
      for (final step in widget.steps.where((m) => m['role'] == 'tool'))
        step['tool_call_id']: step,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton.icon(
            onPressed: () => setState(() => expanded = !expanded),
            icon: Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
            ),
            label: Text(
              '执行过程 · ${calls.length} 次工具调用${expanded ? ' · 收起' : ''}',
            ),
          ),
          if (expanded)
            Container(
              constraints: const BoxConstraints(maxHeight: 320),
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: ListView(
                primary: false,
                shrinkWrap: true,
                padding: const EdgeInsets.all(8),
                children: [
                  for (final step in widget.steps)
                    if (step['role'] == 'assistant') ...[
                      if ('${step['content'] ?? ''}'.isNotEmpty)
                        AgentResponse(content: '${step['content']}'),
                      for (final raw in step['tool_calls'] as List? ?? [])
                        Builder(
                          builder: (context) {
                            final call = object(raw);
                            final function = object(call['function']);
                            final result = results[call['id']];
                            return ExpansionTile(
                              key: ValueKey(call['id']),
                              dense: true,
                              title: Text(
                                '${function['name']}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(result == null ? '等待结果' : '已返回结果'),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: SelectableText(
                                      '参数\n${function['arguments'] ?? ''}\n\n结果\n${result?['content'] ?? '等待结果'}',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        height: 1.5,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                    ] else if (!calls.any(
                      (c) => c['id'] == step['tool_call_id'],
                    ))
                      ExpansionTile(
                        title: const Text('工具执行结果'),
                        children: [SelectableText('${step['content'] ?? ''}')],
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
