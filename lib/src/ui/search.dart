import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/models.dart';
import 'app.dart';

class SearchPage extends ConsumerStatefulWidget {
  final VoidCallback onMessage;
  const SearchPage({super.key, required this.onMessage});
  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final query = TextEditingController();
  final scope = <String>{};
  List<ResourceRef> results = [];
  bool busy = false, online = true, scopeChosen = false;
  @override
  void dispose() {
    query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = ref.watch(workspaceProvider);
    results.removeWhere((r) => w.deletedAccountIds.contains(r.accountId));
    scope.retainAll(w.visibleAccounts.map((a) => a.id));
    if (!scopeChosen && w.selectedAccount != null) {
      scope.add(w.selectedAccount!);
      scopeChosen = true;
    }
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('找到线索，连接上下文', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 10),
          const Text('检索已缓存消息与授权范围内的在线文档。结果附带账号和原始来源。'),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: query,
                  onSubmitted: (_) => search(),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索消息、项目或文档…',
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: busy ? null : search,
                child: Text(busy ? '搜索中' : '搜索'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ...w.visibleAccounts.map(
                (a) => FilterChip(
                  label: Text(a.label),
                  selected: scope.contains(a.id),
                  onSelected: busy
                      ? null
                      : (v) => setState(() {
                          scopeChosen = true;
                          v ? scope.add(a.id) : scope.remove(a.id);
                        }),
                ),
              ),
              FilterChip(
                label: const Text('同时搜索在线资料'),
                selected: online,
                onSelected: (v) => setState(() => online = v),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: results.isEmpty
                ? emptyState(
                    context,
                    Icons.manage_search,
                    '资料都有出处',
                    '选择账号范围，输入关键词开始搜索。支持中文关键词。',
                  )
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, i) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final r = results[i];
                      return Card(
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                          leading: Icon(
                            r.kind == 'message'
                                ? Icons.chat_bubble_outline
                                : Icons.description_outlined,
                          ),
                          title: Text(r.title.isEmpty ? '消息' : r.title),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 6),
                              Text(
                                r.text,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${w.account(r.accountId).label} · ${timeLabel(r.updatedAt)}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          ),
                          trailing: const Icon(Icons.arrow_outward, size: 18),
                          onTap: () => openResource(
                            context,
                            ref,
                            r,
                            onMessage: widget.onMessage,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> search() async {
    if (query.text.trim().isEmpty || scope.isEmpty) return;
    setState(() => busy = true);
    await guarded(context, () async {
      final found = await ref
          .read(workspaceProvider)
          .search(query.text.trim(), scope, online: online);
      if (mounted) setState(() => results = found);
    });
    if (mounted) setState(() => busy = false);
  }
}

Future<void> openResource(
  BuildContext context,
  WidgetRef ref,
  ResourceRef r, {
  VoidCallback? onMessage,
}) async {
  final w = ref.read(workspaceProvider);
  if (r.kind == 'message' && onMessage != null) {
    final c = w.conversations
        .where((c) => c.accountId == r.accountId && c.id == r.conversationId)
        .firstOrNull;
    if (c != null) {
      await w.selectConversation(c);
      onMessage();
      return;
    }
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(r.title.isEmpty ? '来源' : r.title),
      content: SizedBox(
        width: 720,
        height: 480,
        child: FutureBuilder<String>(
          future: w.readResource(r),
          builder: (context, snapshot) => snapshot.hasError
              ? SelectableText('${snapshot.error}')
              : snapshot.hasData
              ? SingleChildScrollView(child: SelectableText(snapshot.data!))
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
      actions: [
        if (r.url.isNotEmpty)
          TextButton(
            onPressed: () {
              final uri = Uri.tryParse(r.url);
              if (uri != null && ['https', 'http'].contains(uri.scheme)) {
                launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('打开原始链接'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
