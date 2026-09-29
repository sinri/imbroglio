import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../core/normalize.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/models.dart';
import 'app.dart';
import 'agent_page.dart';
import 'message_content.dart';
import '../services/workspace.dart';

String senderName(Workspace w, Message m) {
  if (m.extra['isOwn'] == true ||
      (w.account(m.accountId).userId.isNotEmpty &&
          w.account(m.accountId).userId == m.senderId)) {
    return '我';
  }
  final profile =
      w.senderProfiles[compositeKey(m.accountId, senderLookupId(m))];
  final resolved = '${profile?['name'] ?? ''}'.trim();
  return resolved.isNotEmpty
      ? resolved
      : (messageSenderName(m).isNotEmpty
            ? messageSenderName(m)
            : m.senderId.isNotEmpty
            ? m.senderId
            : '未知发送者');
}

String senderAvatar(Workspace w, Message m) {
  final embedded = messageSenderAvatar(m);
  if (embedded.isNotEmpty) return embedded;
  final fromChat = conversationSenderAvatar(m, w.conversations);
  if (fromChat.isNotEmpty) return fromChat;
  final profile =
      w.senderProfiles[compositeKey(m.accountId, senderLookupId(m))];
  final resolved = avatarUrl(profile?['avatar']);
  return resolved;
}

String senderAvatarPath(Workspace w, Message m) {
  if (messageSenderAvatar(m).isNotEmpty ||
      conversationSenderAvatar(m, w.conversations).isNotEmpty) {
    return '';
  }
  final profile =
      w.senderProfiles[compositeKey(m.accountId, senderLookupId(m))];
  final path = '${profile?['avatarPath'] ?? ''}';
  return w.validSenderAvatarPath(m.accountId, path) ? path : '';
}

/// Merge local sends with platform echoes so each send occupies one timeline row.
List<Message> messageTimeline(Workspace w, Conversation c) {
  final messages = w.messages
      .where((m) => m.accountId == c.accountId && m.conversationId == c.id)
      .toList();
  for (final row in w.outbox.where(
    (o) => o['accountId'] == c.accountId && o['conversationId'] == c.id,
  )) {
    final remoteId = '${object(row['result'])['messageId'] ?? ''}';
    final index = remoteId.isEmpty
        ? -1
        : messages.indexWhere(
            (m) =>
                m.id == remoteId ||
                object(m.extra['raw'])['openMessageId'] == remoteId ||
                object(m.extra['raw'])['messageId'] == remoteId,
          );
    final localKey = 'outbox:${row['id']}';
    if (index >= 0) {
      final message = messages[index];
      messages[index] = Message.fromJson({
        ...message.toJson(),
        'extra': {...message.extra, 'timelineKey': localKey, 'isOwn': true},
      });
      continue;
    }
    final attachment = '${row['attachment'] ?? ''}';
    messages.add(
      Message(
        accountId: c.accountId,
        conversationId: c.id,
        id: localKey,
        text: [
          if ('${row['text'] ?? ''}'.isNotEmpty) '${row['text']}',
          if (attachment.isNotEmpty) '📎 ${p.basename(attachment)}',
        ].join('\n'),
        timestamp: row['timestamp'] as int? ?? 0,
        sender: '我',
        status: '${row['state']}',
        extra: {
          'isOwn': true,
          'timelineKey': localKey,
          'localSend': true,
          'sendError': row['error'],
          'errorDismissed': row['errorDismissed'],
          'replyId': row['replyId'],
        },
      ),
    );
  }
  messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return messages;
}

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
    if (w.visibleAccounts.isEmpty) {
      return emptyState(
        context,
        Icons.forum_outlined,
        '把沟通带到同一个地方',
        '连接钉钉与飞书，集中处理消息、检索资料，并让 Agent 协助完成业务。',
        action: FilledButton.icon(
          onPressed: widget.onSetup,
          icon: const Icon(Icons.add),
          label: const Text('连接账号'),
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
                  w.visibleAccounts.any((a) => a.id == c.accountId) &&
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
                      key: ValueKey(w.selectedAccount),
                      initialValue: w.selectedAccount,
                      decoration: const InputDecoration(
                        labelText: '当前账号',
                        isDense: true,
                      ),
                      items: w.visibleAccounts
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
                            key: ValueKey(chat.key),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onSecondaryTapDown: (details) => guarded(
                                context,
                                () => conversationMenu(
                                  chat,
                                  details.globalPosition,
                                ),
                              ),
                              // Keep tile ink inside the scrolling row instead of
                              // painting it on the page Material above the viewport.
                              child: Material(
                                type: MaterialType.transparency,
                                clipBehavior: Clip.antiAlias,
                                borderRadius: BorderRadius.circular(12),
                                child: ListTile(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  selected: c?.key == chat.key,
                                  selectedTileColor: scheme.primaryContainer
                                      .withValues(alpha: .5),
                                  leading: SenderAvatar(
                                    name: chat.title,
                                    url: chat.avatar,
                                    radius: 20,
                                    fallbackIcon: chat.kind == 'group'
                                        ? Icons.group_outlined
                                        : null,
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
                                    '${w.account(chat.accountId).platform == 'dingtalk' ? '钉钉' : '飞书'} · ${w.isConversationExcluded(chat)
                                        ? '已排除自动同步'
                                        : chat.watched
                                        ? '已关注'
                                        : timeLabel(chat.updatedAt)}',
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                  trailing: chat.unread > 0
                                      ? Tooltip(
                                          message: chat.unreadIsLocal
                                              ? '本应用未读（原平台未提供已读状态）'
                                              : '平台未读',
                                          child: Badge(
                                            label: Text('${chat.unread}'),
                                          ),
                                        )
                                      : null,
                                  onTap: () => guarded(
                                    context,
                                    () => w.selectConversation(chat),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (w.backgroundPending > 0)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    '自动补齐近三个月历史 · ${w.backgroundPending} 个会话',
                    style: Theme.of(context).textTheme.labelSmall,
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
                  '近期会话自动同步，选择会话即可阅读。',
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
                                  '${w.account(c.accountId).label} · 用户身份 · ${w.isConversationExcluded(c) ? '已排除自动同步' : state?.mode ?? '定时同步'} · ${(state?.lastSuccess ?? 0) == 0 ? '尚未同步' : '最近同步 ${timeLabel(state!.lastSuccess)}'}',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          if (w.isConversationExcluded(c))
                            TextButton(
                              onPressed: () => guarded(
                                context,
                                () => w.syncConversation(c, manual: true),
                              ),
                              child: const Text('手动拉取'),
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
                    if (state?.pendingErrors.isNotEmpty == true)
                      ErrorNotices(
                        errors: state!.pendingErrors,
                        onDismiss: (error) {
                          state.pendingErrors.remove(error);
                          w.changed();
                        },
                      ),
                    const Divider(),
                    Expanded(
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (notification) {
                          if (notification is ScrollUpdateNotification &&
                              notification.metrics.pixels > 0 &&
                              notification.metrics.extentAfter < 100 &&
                              !w.loadingEarlier) {
                            w.showEarlierMessages();
                          }
                          return false;
                        },
                        child: ListView(
                          key: PageStorageKey(c.key),
                          reverse: true,
                          padding: const EdgeInsets.all(22),
                          children: [
                            Center(
                              child: TextButton.icon(
                                onPressed: () => guarded(
                                  context,
                                  () => w.showEarlierMessages(manual: true),
                                ),
                                icon: const Icon(Icons.history, size: 16),
                                label: Text(
                                  w.loadingEarlier ? '加载中…' : '加载更早消息',
                                ),
                              ),
                            ),
                            ...messageTimeline(w, c).map(
                              (m) => Padding(
                                key: ValueKey<String>(
                                  '${m.extra['timelineKey'] ?? m.key}',
                                ),
                                padding: const EdgeInsets.only(bottom: 20),
                                // Keep selection out of the recycling timeline.
                                // Content replacement gets a fresh selection delegate.
                                child: SelectionArea(
                                  key: ValueKey((
                                    m.key,
                                    m.text,
                                    m.kind,
                                    jsonEncode(m.extra),
                                    w.messages
                                        .where(
                                          (other) =>
                                              other.id == m.extra['replyId'],
                                        )
                                        .firstOrNull
                                        ?.text,
                                  )),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SelectionContainer.disabled(
                                        child: SenderAvatar(
                                          name: senderName(w, m),
                                          url: senderAvatar(w, m),
                                          path: senderAvatarPath(w, m),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '${senderName(w, m)}  ·  ${messageTimeLabel(m.timestamp)}',
                                              style: Theme.of(
                                                context,
                                              ).textTheme.labelSmall,
                                            ),
                                            const SizedBox(height: 6),
                                            Container(
                                              padding: const EdgeInsets.all(14),
                                              decoration: BoxDecoration(
                                                color:
                                                    scheme.surfaceContainerLow,
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  if ('${m.extra['replyId'] ?? ''}'
                                                      .isNotEmpty)
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            bottom: 8,
                                                          ),
                                                      child: Text(
                                                        '回复：${w.messages.where((other) => other.id == m.extra['replyId']).firstOrNull?.text ?? '原消息尚未缓存'}',
                                                        style: Theme.of(
                                                          context,
                                                        ).textTheme.labelSmall,
                                                      ),
                                                    ),
                                                  MessageContent(
                                                    m,
                                                    onDownload: () =>
                                                        download(m),
                                                  ),
                                                ],
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
                                      if (m.status == 'sending')
                                        const Padding(
                                          padding: EdgeInsets.all(8),
                                          child: Text('发送中…'),
                                        ),
                                      if ((m.status == 'failed' ||
                                              m.status == 'unknown') &&
                                          m.extra['errorDismissed'] != true)
                                        SizedBox(
                                          width: 220,
                                          child: ErrorNotices(
                                            errors: [
                                              '${m.status == 'failed' ? '发送失败' : '发送结果未知，请核对原平台'}'
                                                  '${m.extra['sendError'] == null ? '' : '：${m.extra['sendError']}'}',
                                            ],
                                            onDismiss: (_) =>
                                                w.dismissSendError(
                                                  m.id.substring(
                                                    'outbox:'.length,
                                                  ),
                                                ),
                                          ),
                                        ),
                                      if (m.text.isNotEmpty)
                                        IconButton(
                                          tooltip: '复制消息',
                                          onPressed: () => copyMessage(m.text),
                                          icon: const Icon(
                                            Icons.copy_outlined,
                                            size: 18,
                                          ),
                                        ),
                                      if (m.kind != 'file' &&
                                          findResourceId(
                                            m.extra['raw'],
                                          ).isNotEmpty)
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
                                        onPressed: m.extra['localSend'] == true
                                            ? null
                                            : () => setState(() => reply = m),
                                        icon: const Icon(Icons.reply, size: 18),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ].reversed.toList(),
                        ),
                      ),
                    ),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                      child: Column(
                        children: [
                          if (!w.account(c.accountId).canSend)
                            const Text('缺少发送权限，请到设置为此账号补充发送授权。'),
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
                                onPressed:
                                    sending || !w.account(c.accountId).canSend
                                    ? null
                                    : () => send(),
                                icon: const Icon(Icons.arrow_upward, size: 18),
                                label: const Text('发送'),
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

  Future<void> conversationMenu(Conversation chat, Offset position) async {
    final w = ref.read(workspaceProvider);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(position);
    final excluded = w.isConversationExcluded(chat);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: 'blacklist',
          enabled: !excluded,
          child: Row(
            children: [
              const Icon(Icons.block, size: 18),
              const SizedBox(width: 12),
              Text(excluded ? '已在黑名单中' : '加入黑名单'),
            ],
          ),
        ),
      ],
    );
    if (!mounted || action != 'blacklist') return;
    await w.blacklistConversation(chat);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已将「${chat.title}」加入黑名单，可在设置中管理规则')));
  }

  Future<void> copyMessage(String text) => guarded(context, () async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('消息已复制'), duration: Duration(seconds: 1)),
      );
    }
  });

  Future<void> send() async {
    final w = ref.read(workspaceProvider), c = w.selectedConversation;
    if (c == null || (compose.text.trim().isEmpty && attachment == null)) {
      return;
    }
    final text = compose.text;
    final previousReply = reply;
    final previousAttachment = attachment;
    setState(() {
      sending = true;
      compose.clear();
      reply = null;
      attachment = null;
    });
    try {
      await w.send(
        c,
        text,
        reply: previousReply,
        attachment: previousAttachment,
        image:
            previousAttachment != null &&
            RegExp(
              r'\.(png|jpe?g|gif|webp)$',
              caseSensitive: false,
            ).hasMatch(previousAttachment),
        markdown: markdown,
      );
    } catch (_) {
      // The send record retains the error next to its message.
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  Future<void> download(Message message) async {
    await guarded(context, () async {
      final path = await ref
          .read(workspaceProvider)
          .downloadAttachment(message, findResourceId(message.extra['raw']));
      await FilePicker.saveFile(
        bytes: await File(path).readAsBytes(),
        fileName: p.basename(
          '${attachmentDetails(message.extra['raw'])['name'] ?? (message.kind == 'image' ? 'image.png' : 'attachment')}'
              .replaceAll('\\', '/'),
        ),
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
                if (error != null)
                  ErrorNotices(
                    errors: [error!],
                    onDismiss: (_) => set(() => error = null),
                  ),
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
