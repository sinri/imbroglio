import 'dart:convert';
import 'dart:io';
import '../core/normalize.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/models.dart';
import 'app.dart';
import 'agent_page.dart';

class MessagesPage extends ConsumerStatefulWidget {
  final VoidCallback onSetup;
  const MessagesPage({super.key, required this.onSetup});
  @override
  ConsumerState<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends ConsumerState<MessagesPage> {
  final compose = TextEditingController(), filter = TextEditingController();
  Message? reply;
  bool sending = false, showAgent = false, markdown = false;
  String? attachment, lastConversation;
  @override
  void dispose() {
    compose.dispose();
    filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = ref.watch(workspaceProvider),
        scheme = Theme.of(context).colorScheme;
    if (w.accounts.isEmpty) {
      return emptyState(
        context,
        Icons.forum_outlined,
        '把沟通带到同一个地方',
        '连接钉钉与飞书，集中处理消息、检索资料，并让 Agent 协助完成业务。',
        action: FilledButton.icon(
          onPressed: widget.onSetup,
          icon: const Icon(Icons.add),
          label: const Text('安装连接器'),
        ),
      );
    }
    final c = w.selectedConversation;
    if (lastConversation != c?.key) {
      lastConversation = c?.key;
      compose.clear();
      reply = null;
      attachment = null;
    }
    final conversations =
        w.conversations
            .where(
              (c) =>
                  (w.selectedAccount == null ||
                      c.accountId == w.selectedAccount) &&
                  c.title.toLowerCase().contains(filter.text.toLowerCase()),
            )
            .toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    final state = c == null ? null : w.sync[c.key];
    return Row(
      children: [
        SizedBox(
          width: 272,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: w.selectedAccount,
                      decoration: const InputDecoration(
                        labelText: '当前账号',
                        isDense: true,
                      ),
                      items: w.accounts
                          .map(
                            (a) => DropdownMenuItem(
                              value: a.id,
                              child: Text(
                                a.label,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (id) {
                        w.selectedAccount = id;
                        w.selectedConversation = null;
                        w.changed();
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: filter,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: '筛选会话',
                        prefixIcon: Icon(Icons.search, size: 20),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  const SizedBox(width: 16),
                  Text(
                    '${conversations.length} 个会话',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '查找联系人',
                    onPressed: () => contacts(),
                    icon: const Icon(Icons.person_search_outlined, size: 19),
                  ),
                  IconButton(
                    tooltip: '刷新会话',
                    onPressed: () => guarded(context, () async {
                      if (w.selectedAccount != null) {
                        await w.refreshConversations(
                          w.account(w.selectedAccount!),
                        );
                      }
                    }),
                    icon: const Icon(Icons.refresh, size: 19),
                  ),
                ],
              ),
              Expanded(
                child: conversations.isEmpty
                    ? const Center(child: Text('登录后刷新会话列表'))
                    : ListView.builder(
                        itemCount: conversations.length,
                        itemBuilder: (context, index) {
                          final chat = conversations[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            child: ListTile(
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                              selected: c?.key == chat.key,
                              selectedTileColor: scheme.primaryContainer
                                  .withValues(alpha: .5),
                              leading: CircleAvatar(
                                backgroundColor: scheme.secondaryContainer,
                                child: Icon(
                                  chat.kind == 'group'
                                      ? Icons.group_outlined
                                      : Icons.person_outline,
                                  size: 22,
                                ),
                              ),
                              title: Text(
                                chat.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                '${w.account(chat.accountId).platform == 'dingtalk' ? '钉钉' : '飞书'} · ${chat.watched ? '已关注' : timeLabel(chat.updatedAt)}',
                                style: const TextStyle(fontSize: 11),
                              ),
                              trailing: chat.unread > 0
                                  ? Badge(label: Text('${chat.unread}'))
                                  : null,
                              onTap: () => guarded(
                                context,
                                () => w.selectConversation(chat),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              TextButton(
                onPressed: () => guarded(context, () async {
                  if (w.selectedAccount != null) {
                    await w.refreshConversations(
                      w.account(w.selectedAccount!),
                      more: true,
                    );
                  }
                }),
                child: const Text('加载更多会话'),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: c == null
              ? emptyState(
                  context,
                  Icons.chat_bubble_outline,
                  '选择一个会话',
                  '消息只在已授权的范围内同步。关注会话可保持后台同步。',
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 14,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  c.title,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${w.account(c.accountId).label} · 用户身份 · ${state?.mode ?? '定时同步'} · ${timeLabel(state?.lastSuccess ?? 0)}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '切换关注',
                            onPressed: () => guarded(
                              context,
                              () => w.watch(
                                c,
                                !w.conversations
                                    .firstWhere((v) => v.key == c.key)
                                    .watched,
                              ),
                            ),
                            icon: Icon(
                              w.conversations
                                      .firstWhere((v) => v.key == c.key)
                                      .watched
                                  ? Icons.star
                                  : Icons.star_border,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Agent 侧栏',
                            onPressed: () {
                              if (MediaQuery.sizeOf(context).width < 1180) {
                                showDialog<void>(
                                  context: context,
                                  builder: (context) => const Dialog(
                                    child: SizedBox(
                                      width: 600,
                                      height: 650,
                                      child: AgentPage(compact: true),
                                    ),
                                  ),
                                );
                              } else {
                                setState(() => showAgent = !showAgent);
                              }
                            },
                            icon: const Icon(Icons.auto_awesome_outlined),
                          ),
                        ],
                      ),
                    ),
                    if (state?.error.isNotEmpty == true)
                      Container(
                        width: double.infinity,
                        color: scheme.errorContainer,
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          state!.error,
                          style: TextStyle(
                            color: scheme.onErrorContainer,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    const Divider(),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(22),
                        children: [
                          Center(
                            child: TextButton.icon(
                              onPressed: () => guarded(
                                context,
                                () => w.syncConversation(c, older: true),
                              ),
                              icon: const Icon(Icons.history, size: 16),
                              label: const Text('加载更早消息'),
                            ),
                          ),
                          ...w.messages.map(
                            (m) => Padding(
                              key: ValueKey(m.key),
                              padding: const EdgeInsets.only(bottom: 20),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                    radius: 16,
                                    backgroundColor: scheme.secondaryContainer,
                                    child: Text(
                                      m.sender.isEmpty
                                          ? '?'
                                          : String.fromCharCode(
                                              m.sender.runes.first,
                                            ),
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          '${m.sender.isEmpty ? m.senderId : m.sender}  ·  ${timeLabel(m.timestamp)}',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.labelSmall,
                                        ),
                                        const SizedBox(height: 6),
                                        Container(
                                          padding: const EdgeInsets.all(14),
                                          decoration: BoxDecoration(
                                            color: scheme.surfaceContainerLow,
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: SelectableText(
                                            m.text.isEmpty
                                                ? '[${m.kind}]'
                                                : m.text,
                                            style: const TextStyle(height: 1.6),
                                          ),
                                        ),
                                        if (m.kind != 'text')
                                          Text(
                                            m.kind,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.labelSmall,
                                          ),
                                      ],
                                    ),
                                  ),
                                  if (findResourceId(m.extra['raw']).isNotEmpty)
                                    IconButton(
                                      tooltip: '下载附件',
                                      icon: const Icon(
                                        Icons.download_outlined,
                                        size: 18,
                                      ),
                                      onPressed: () => download(m),
                                    ),
                                  IconButton(
                                    tooltip: '引用回复',
                                    onPressed: () => setState(() => reply = m),
                                    icon: const Icon(Icons.reply, size: 18),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          ...w.outbox
                              .where(
                                (o) =>
                                    o['accountId'] == c.accountId &&
                                    o['conversationId'] == c.id,
                              )
                              .take(10)
                              .map(
                                (o) => ListTile(
                                  dense: true,
                                  leading: Icon(
                                    o['state'] == 'confirmed'
                                        ? Icons.check_circle_outline
                                        : o['state'] == 'sending'
                                        ? Icons.schedule
                                        : Icons.error_outline,
                                    size: 18,
                                  ),
                                  title: Text('${o['text']}', maxLines: 2),
                                  subtitle: Text(
                                    {
                                          'sending': '发送中',
                                          'confirmed': '已确认发送',
                                          'failed': '发送失败',
                                          'unknown': '结果未知，请刷新核对后再发送',
                                        }[o['state']] ??
                                        '${o['state']}',
                                  ),
                                ),
                              ),
                        ],
                      ),
                    ),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Column(
                        children: [
                          if (reply != null)
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '回复 ${reply!.sender}：${reply!.text}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () => setState(() => reply = null),
                                  icon: const Icon(Icons.close, size: 16),
                                ),
                              ],
                            ),
                          if (attachment != null)
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    attachment!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () =>
                                      setState(() => attachment = null),
                                  icon: const Icon(Icons.close, size: 16),
                                ),
                              ],
                            ),
                          TextField(
                            controller: compose,
                            minLines: 2,
                            maxLines: 5,
                            decoration: const InputDecoration(
                              hintText: '输入消息…',
                              contentPadding: EdgeInsets.all(16),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              IconButton(
                                tooltip: '添加图片或文件',
                                onPressed: () async {
                                  final files = await FilePicker.pickFile();
                                  if (files != null) {
                                    setState(() => attachment = files.path);
                                  }
                                },
                                icon: const Icon(Icons.attach_file, size: 20),
                              ),
                              FilterChip(
                                label: const Text('Markdown'),
                                selected: markdown,
                                onSelected: (v) => setState(() => markdown = v),
                              ),
                              const Spacer(),
                              Flexible(
                                child: Text(
                                  '以 ${w.account(c.accountId).label} 发送',
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                              const SizedBox(width: 12),
                              FilledButton.icon(
                                onPressed: sending ? null : () => send(),
                                icon: const Icon(Icons.arrow_upward, size: 18),
                                label: Text(sending ? '发送中' : '发送'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        if (showAgent &&
            c != null &&
            MediaQuery.sizeOf(context).width >= 1180) ...[
          const VerticalDivider(width: 1),
          const SizedBox(width: 340, child: AgentPage(compact: true)),
        ],
      ],
    );
  }

  Future<void> send() async {
    final w = ref.read(workspaceProvider), c = w.selectedConversation;
    if (c == null || (compose.text.trim().isEmpty && attachment == null)) {
      return;
    }
    setState(() => sending = true);
    await guarded(context, () async {
      await w.send(
        c,
        compose.text,
        reply: reply,
        attachment: attachment,
        image:
            attachment != null &&
            RegExp(
              r'\.(png|jpe?g|gif|webp)$',
              caseSensitive: false,
            ).hasMatch(attachment!),
        markdown: markdown,
      );
      compose.clear();
      if (mounted) {
        setState(() {
          reply = null;
          attachment = null;
        });
      }
    });
    if (mounted) setState(() => sending = false);
  }

  Future<void> download(Message message) async {
    await guarded(context, () async {
      final path = await ref
          .read(workspaceProvider)
          .downloadAttachment(message, findResourceId(message.extra['raw']));
      await FilePicker.saveFile(
        bytes: await File(path).readAsBytes(),
        fileName: message.kind == 'image' ? 'image.png' : 'attachment',
      );
    });
  }

  Future<void> contacts() async {
    final w = ref.read(workspaceProvider);
    if (w.selectedAccount == null) return;
    final query = TextEditingController();
    List<Json> results = [];
    String? error;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, set) => AlertDialog(
          title: const Text('查找联系人'),
          content: SizedBox(
            width: 500,
            height: 360,
            child: Column(
              children: [
                TextField(
                  controller: query,
                  decoration: InputDecoration(
                    hintText: '姓名',
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: () async {
                        try {
                          final r = object(
                            await (await w.client(
                              w.account(w.selectedAccount!),
                            )).call('contacts', {'query': query.text}),
                          );
                          set(
                            () => results = (r['items'] as List)
                                .map(object)
                                .toList(),
                          );
                        } catch (e) {
                          set(() => error = '$e');
                        }
                      },
                    ),
                  ),
                ),
                if (error != null) Text(error!),
                Expanded(
                  child: ListView(
                    children: results
                        .map(
                          (r) => ListTile(
                            trailing: IconButton(
                              tooltip: '打开单聊',
                              icon: const Icon(Icons.chat_outlined),
                              onPressed: () => guarded(context, () async {
                                await w.openContact(w.selectedAccount!, r);
                                if (context.mounted) Navigator.pop(context);
                              }),
                            ),
                            title: SelectableText(
                              const JsonEncoder.withIndent('  ').convert(r),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        ),
      ),
    );
    query.dispose();
  }
}
