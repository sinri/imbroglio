import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/models.dart';
import '../services/mcp.dart';
import 'app.dart';

class McpServersSection extends ConsumerStatefulWidget {
  const McpServersSection({super.key});
  @override
  ConsumerState<McpServersSection> createState() => _McpServersSectionState();
}

class _McpServersSectionState extends ConsumerState<McpServersSection> {
  late Future<List<Json>> _servers;
  final _testing = <String, McpClient>{};
  final _results = <String, List<Json>>{};
  McpRepository get repository =>
      McpRepository(ref.read(workspaceProvider).store);
  @override
  void initState() {
    super.initState();
    _servers = repository.list();
  }

  void refresh() {
    if (mounted) {
      setState(() {
        _servers = repository.list();
      });
    }
  }

  @override
  void dispose() {
    for (final c in _testing.values) {
      c.close();
    }
    super.dispose();
  }

  void stop(String id) {
    _testing.remove(id)?.close();
    _results.remove(id);
    ref.read(agentProvider).cancelMcp(id);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Icon(
            Icons.dns_outlined,
            size: 20,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'MCP 服务器',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => edit(),
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(
        '连接外部工具，供 Agent 调用。新增默认停用，每次工具调用都需确认。',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: 16),
      FutureBuilder<List<Json>>(
        future: _servers,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Text('无法读取 MCP 配置');
          if (!snapshot.hasData) return const LinearProgressIndicator();
          if (snapshot.data!.isEmpty) {
            return const Card(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('尚未添加 MCP 服务器 · 支持本地 stdio 和远程 Streamable HTTP'),
              ),
            );
          }
          return Column(
            children: snapshot.data!.map((server) {
              final id = server['id'] as String;
              return Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${server['name']}',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                Text(
                                  '${server['transport'] == 'stdio' ? '本地进程' : '远程 HTTP'} · ${server['enabled'] == true ? '已启用' : '已停用'}',
                                ),
                              ],
                            ),
                          ),
                          Switch(
                            value: server['enabled'] == true,
                            onChanged: (value) => guarded(context, () async {
                              stop(id);
                              await repository.setEnabled(id, value);
                              refresh();
                            }),
                          ),
                          PopupMenuButton<String>(
                            tooltip: '管理 MCP',
                            onSelected: (action) {
                              if (action == 'edit') {
                                edit(server);
                              } else {
                                guarded(context, () async {
                                  stop(id);
                                  await repository.remove(id);
                                  refresh();
                                });
                              }
                            },
                            itemBuilder: (_) => [
                              const PopupMenuItem(
                                value: 'edit',
                                child: Text('编辑'),
                              ),
                              const PopupMenuItem(
                                value: 'remove',
                                child: Text('删除'),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        server['transport'] == 'stdio'
                            ? '启用后，测试或 Agent 运行时会启动本地程序，拥有当前用户权限。'
                            : '仅在测试或 Agent 运行时连接；工具参数与结果会发送到配置的服务。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed:
                            server['enabled'] != true ||
                                _testing.containsKey(id)
                            ? null
                            : () => test(server),
                        icon: const Icon(Icons.network_check),
                        label: Text(
                          _testing.containsKey(id) ? '正在连接…' : '测试连接与查看工具',
                        ),
                      ),
                      if (_results[id] != null) ...[
                        const SizedBox(height: 8),
                        Text('连接成功 · ${_results[id]!.length} 个工具'),
                        for (final tool in _results[id]!)
                          Text('• ${tool['name']}'),
                      ],
                    ],
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    ],
  );

  Future<void> test(Json server) => guarded(context, () async {
    final id = server['id'] as String;
    final config = await repository.load(id);
    if (!await repository.isCurrent(config) || !mounted) return;
    final client = McpClient(config);
    setState(() {
      _testing[id] = client;
      _results.remove(id);
    });
    try {
      await client.connect();
      final tools = await client.listTools();
      if (mounted && _testing[id] == client) {
        setState(() => _results[id] = tools);
      }
    } finally {
      await client.close();
      if (_testing[id] == client) _testing.remove(id);
      if (mounted) setState(() {});
    }
  });

  Future<void> edit([Json? existing]) => guarded(context, () async {
    final config = existing == null
        ? <String, dynamic>{
            'id': 'my-server',
            'name': '我的 MCP',
            'transport': 'stdio',
            'command': 'python3',
            'args': ['/absolute/path/server.py'],
            'env': <String, String>{},
          }
        : await repository.load(existing['id']);
    config.remove('enabled');
    config.remove('revision');
    if (!mounted) return;
    final result = await showDialog<Json>(
      context: context,
      builder: (_) => _McpEditor(config: config, existingId: existing?['id']),
    );
    if (result == null) return;
    if (existing == null &&
        (await repository.list()).any((s) => s['id'] == result['id'])) {
      throw const FormatException('该 ID 已存在，请编辑已有服务器');
    }
    if (!mounted) return;
    stop(result['id']);
    await repository.save(result); // Editing requires explicit re-enabling.
    refresh();
  });
}

class _McpEditor extends StatefulWidget {
  final Json config;
  final String? existingId;
  const _McpEditor({required this.config, this.existingId});
  @override
  State<_McpEditor> createState() => _McpEditorState();
}

class _McpEditorState extends State<_McpEditor> {
  late final text = TextEditingController(
    text: const JsonEncoder.withIndent('  ').convert(widget.config),
  );
  String? error;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existingId == null ? '添加 MCP 服务器' : '编辑 MCP 服务器'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('配置 JSON；env 与 headers 保存到系统安全存储。保存后保持停用，请返回列表主动启用。'),
            const SizedBox(height: 12),
            if (widget.existingId == null)
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => template('stdio'),
                    child: const Text('本地 stdio 模板'),
                  ),
                  TextButton(
                    onPressed: () => template('http'),
                    child: const Text('远程 HTTP 模板'),
                  ),
                ],
              ),
            TextField(
              controller: text,
              minLines: 10,
              maxLines: 18,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                labelText: '服务器配置',
                errorText: error,
                errorMaxLines: 4,
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final result = object(jsonDecode(text.text));
            validateMcpConfig(result);
            if (widget.existingId != null &&
                result['id'] != widget.existingId) {
              throw const FormatException('编辑时不能修改 ID');
            }
            Navigator.pop(context, result);
          } catch (e) {
            setState(() => error = '$e');
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
  void template(String transport) {
    text.text = const JsonEncoder.withIndent('  ').convert({
      'id': 'my-server',
      'name': '我的 MCP',
      'transport': transport,
      if (transport == 'stdio') ...{
        'command': 'python3',
        'args': ['/absolute/path/server.py'],
        'env': {},
      } else ...{
        'url': 'https://example.com/mcp',
        'headers': {},
      },
    });
  }
}
