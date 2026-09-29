import '../core/models.dart';
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
  final scope = <String>{};
  String? pluginId;
  bool scopeChosen = false;
  @override
  void dispose() {
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
    return Padding(
      padding: EdgeInsets.all(widget.compact ? 14 : 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: pluginId,
                  decoration: const InputDecoration(
                    labelText: 'Agent 插件',
                    isDense: true,
                  ),
                  items: plugins
                      .map(
                        (p) => DropdownMenuItem<String>(
                          value: p['id'],
                          child: Text(
                            p['name'],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: agent.running
                      ? null
                      : (id) => setState(() => pluginId = id),
                ),
              ),
              IconButton(
                tooltip: '新会话',
                onPressed: agent.running ? null : agent.newSession,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              if (!widget.compact)
                IconButton(
                  tooltip: '历史会话',
                  onPressed: agent.running ? null : () => sessions(),
                  icon: const Icon(Icons.history),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: w.visibleAccounts
                .map(
                  (a) => FilterChip(
                    label: Text(a.label),
                    selected: scope.contains(a.id),
                    onSelected: agent.running
                        ? null
                        : (v) => setState(() {
                            scopeChosen = true;
                            v ? scope.add(a.id) : scope.remove(a.id);
                          }),
                  ),
                )
                .toList(),
          ),
          if (!widget.compact)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                '读取自动执行 · 对外写入需确认 · 所选资料将发送至你配置的模型服务',
                style: TextStyle(fontSize: 12),
              ),
            ),
          const SizedBox(height: 12),
          Expanded(
            child: display.isEmpty && !agent.running
                ? emptyState(
                    context,
                    Icons.auto_awesome_outlined,
                    '让信息成为行动',
                    '总结会话、分析资料，或整理待办。先在设置中配置模型服务。',
                  )
                : ListView(
                    children: [
                      ...display.map((m) {
                        final role = m['role'];
                        if (role == 'tool') {
                          return ExpansionTile(
                            dense: true,
                            title: const Text(
                              '工具执行结果',
                              style: TextStyle(fontSize: 12),
                            ),
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: SelectableText(
                                  '${m['content']}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ),
                            ],
                          );
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                role == 'user' ? '你' : 'Agent',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SelectableText(
                                '${m['content'] ?? ''}',
                                style: const TextStyle(height: 1.6),
                              ),
                              if (m['tool_calls'] != null)
                                Text(
                                  '调用 ${(m['tool_calls'] as List).map((c) => c['function']['name']).join('、')}',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                            ],
                          ),
                        );
                      }),
                      if (agent.streaming.isNotEmpty)
                        SelectableText(agent.streaming),
                      if (agent.running)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: LinearProgressIndicator(),
                        ),
                      if (agent.sources.isNotEmpty)
                        Wrap(
                          spacing: 8,
                          children: agent.sources.entries
                              .map(
                                (s) => ActionChip(
                                  label: Text(
                                    '[${s.key}] ${s.value.title}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onPressed: () =>
                                      openResource(context, ref, s.value),
                                ),
                              )
                              .toList(),
                        ),
                    ],
                  ),
          ),
          if (agent.pendingErrors.isNotEmpty)
            ErrorNotices(
              errors: agent.pendingErrors,
              onDismiss: agent.dismissError,
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
          const SizedBox(height: 10),
          TextField(
            controller: input,
            minLines: 2,
            maxLines: 4,
            enabled: !agent.running,
            decoration: const InputDecoration(hintText: '想了解什么，或需要完成什么？'),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (!widget.compact)
                Text(
                  '${scope.length} 个账号已选定',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              const Spacer(),
              if (agent.running)
                OutlinedButton.icon(
                  onPressed: agent.cancel,
                  icon: const Icon(Icons.stop, size: 18),
                  label: const Text('停止'),
                )
              else
                FilledButton.icon(
                  onPressed: pluginId == null
                      ? null
                      : () {
                          final prompt = input.text;
                          input.clear();
                          agent.run(
                            prompt,
                            scope,
                            plugins.firstWhere((p) => p['id'] == pluginId),
                          );
                        },
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  label: const Text('开始'),
                ),
            ],
          ),
        ],
      ),
    );
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
