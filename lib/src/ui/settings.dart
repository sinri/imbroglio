import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/models.dart';
import '../services/agent.dart';
import 'app.dart';

class PluginsPage extends ConsumerStatefulWidget {
  const PluginsPage({super.key});
  @override
  ConsumerState<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends ConsumerState<PluginsPage> {
  final progress = <String, String>{};
  final busy = <String>{};
  @override
  Widget build(BuildContext context) {
    final w = ref.watch(workspaceProvider);
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '你的工作能力，由插件扩展',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  const Text('官方 CLI 独立安装与更新，无需系统预装 Node 或 Go。'),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: importPackage,
              icon: const Icon(Icons.upload_file),
              label: const Text('安装插件包'),
            ),
          ],
        ),
        const SizedBox(height: 28),
        ...['dingtalk', 'feishu'].map(
          (id) => FutureBuilder<Json?>(
            future: w.plugins.installation(id),
            builder: (context, snapshot) {
              final install = snapshot.data;
              return Card(
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 25,
                            backgroundColor: id == 'dingtalk'
                                ? const Color(0xffe0edff)
                                : const Color(0xffdcf4ef),
                            child: Icon(
                              id == 'dingtalk' ? Icons.bolt : Icons.flight,
                              color: id == 'dingtalk'
                                  ? Colors.blue
                                  : Colors.teal,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  id == 'dingtalk'
                                      ? '钉钉 · DingTalk Workspace'
                                      : '飞书 · Lark CLI',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  install == null
                                      ? '尚未安装'
                                      : '${install['version']} · ${install['enabled'] == true ? '已启用' : '已停用'}',
                                ),
                              ],
                            ),
                          ),
                          FilledButton(
                            onPressed: busy.contains(id)
                                ? null
                                : () => installCli(id),
                            child: Text(install == null ? '安装' : '检查更新'),
                          ),
                          if (install != null)
                            PopupMenuButton<String>(
                              onSelected: (value) => guarded(context, () async {
                                if (value != 'rollback') {
                                  await w.stopPlatform(id);
                                }
                                if (value == 'rollback') {
                                  await w.rollbackPlugin(id);
                                } else if (value == 'toggle') {
                                  await w.plugins.setEnabled(
                                    id,
                                    install['enabled'] != true,
                                  );
                                } else if (value == 'uninstall') {
                                  await w.plugins.uninstall(id);
                                }
                                w.changed();
                                setState(() {});
                              }),
                              itemBuilder: (_) => [
                                PopupMenuItem(
                                  value: 'toggle',
                                  child: Text(
                                    install['enabled'] == true ? '停用' : '启用',
                                  ),
                                ),
                                if (install['previous'] != null)
                                  const PopupMenuItem(
                                    value: 'rollback',
                                    child: Text('回滚上一版'),
                                  ),
                                const PopupMenuItem(
                                  value: 'uninstall',
                                  child: Text('卸载（保留账号数据）'),
                                ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        id == 'dingtalk'
                            ? '个人消息订阅 · 会话收发 · 文档和待办'
                            : '用户身份沟通 · 个人会话定时同步 · 文档和待办',
                      ),
                      if (progress[id] != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          progress[id]!,
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                      if (busy.contains(id))
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(),
                        ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed:
                            install == null || install['enabled'] == false
                            ? null
                            : () => accountDialog(context, ref, id),
                        icon: const Icon(Icons.person_add_alt, size: 18),
                        label: const Text('连接账号'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 18),
        Text('Agent 与扩展插件', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        ...w.packages.map(
          (plugin) => Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Icon(
                plugin['kind'] == 'agent'
                    ? Icons.auto_awesome_outlined
                    : Icons.extension_outlined,
              ),
              title: Text('${plugin['name']}'),
              subtitle: Text(
                '${plugin['version']} · ${(plugin['tools'] as List? ?? []).join(' / ')}',
              ),
              trailing: Wrap(
                children: [
                  if (plugin['kind'] == 'im')
                    IconButton(
                      tooltip: '连接账号',
                      onPressed: () =>
                          accountDialog(context, ref, plugin['id']),
                      icon: const Icon(Icons.person_add_alt),
                    ),
                  Switch(
                    value: plugin['enabled'] == true,
                    onChanged: (value) => guarded(context, () async {
                      if (!value && plugin['kind'] == 'im') {
                        await w.stopPlatform(plugin['id']);
                      }
                      await w.store.put('packages', plugin['id'], {
                        ...plugin,
                        'enabled': value,
                      });
                      w.packages = await w.store.list('packages');
                      w.changed();
                    }),
                  ),
                  if (plugin['builtin'] != true)
                    IconButton(
                      tooltip: '卸载',
                      onPressed: () => guarded(context, () async {
                        if (plugin['kind'] == 'im') {
                          await w.stopPlatform(plugin['id']);
                        }
                        await w.plugins.uninstall(plugin['id'], package: true);
                        w.packages = await w.store.list('packages');
                        w.changed();
                      }),
                      icon: const Icon(Icons.delete_outline),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          '配置与缓存独立保存。系统凭证可能共享；相同账号的授权和退出可能影响系统 CLI。',
          style: TextStyle(fontSize: 12),
        ),
      ],
    );
  }

  Future<void> installCli(String id) async {
    final w = ref.read(workspaceProvider);
    setState(() {
      busy.add(id);
      progress[id] = '检查官方发行源…';
    });
    await guarded(context, () async {
      final release = await w.plugins.release(id);
      if (!mounted) return;
      final yes = await confirm(
        context,
        '安装 ${release['version']}',
        '将下载官方原版并验证 SHA-256。更新期间暂停此平台同步；不修改系统安装的 CLI。\n\n${release['asset']['name']}',
      );
      if (!yes) return;
      await w.updatePlugin(id, release, (message) {
        if (mounted) setState(() => progress[id] = message);
      });
    });
    if (mounted) setState(() => busy.remove(id));
  }

  Future<void> importPackage() async {
    await guarded(context, () async {
      final selected = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );
      if (selected == null) return;
      final file = selected.path!;
      final w = ref.read(workspaceProvider),
          manifest = await w.plugins.inspectPackage(file);
      final digest = sha256.convert(await File(file).readAsBytes()).toString();
      if (!mounted) return;
      final yes = await confirm(
        context,
        '安装 ${manifest.name}',
        '版本 ${manifest.version}\n类型 ${manifest.kind}\n权限：${manifest.data['permissions'] ?? manifest.data['tools']}\n\n${manifest.kind == 'im' ? '此插件包含可执行代码，拥有当前用户的进程权限。请仅安装可信来源。' : '此 Agent 将在所声明的工具权限内执行。'}\n\nSHA-256: $digest',
      );
      if (!yes) return;
      await w.plugins.importPackage(file, digest);
      w.packages = await w.store.list('packages');
      w.changed();
    });
  }
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final base = TextEditingController(),
      model = TextEditingController(),
      key = TextEditingController();
  bool loaded = false, saving = false;
  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      final saved = await ref
          .read(workspaceProvider)
          .store
          .get('settings', 'model');
      if (mounted) {
        setState(() {
          base.text = saved?['baseUrl'] ?? 'https://api.openai.com/v1';
          model.text = saved?['model'] ?? '';
          loaded = true;
        });
      }
    });
  }

  @override
  void dispose() {
    base.dispose();
    model.dispose();
    key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = ref.watch(workspaceProvider);
    return ListView(
      padding: const EdgeInsets.all(28),
      children: [
        Text('账号与授权', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        if (w.accounts.isEmpty)
          const ListTile(
            title: Text('尚未连接账号'),
            subtitle: Text('请先在插件中心安装钉钉或飞书连接器。'),
          ),
        ...w.accounts.map(
          (a) => Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: Icon(
                a.platform == 'dingtalk' ? Icons.bolt : Icons.flight,
              ),
              title: Text(a.label),
              subtitle: Text(
                '${a.platform} · ${a.organization.isEmpty ? a.profile : a.organization} · ${a.enabled ? '同步已开启' : '未连接 / 已暂停'}',
              ),
              trailing: Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => renameAccountDialog(context, ref, a),
                    child: const Text('改名'),
                  ),
                  TextButton(
                    onPressed: () =>
                        accountDialog(context, ref, a.platform, existing: a),
                    child: const Text('授权'),
                  ),
                  TextButton(
                    onPressed: () => guarded(context, () async {
                      if (a.enabled) {
                        await w.disconnect(a);
                      } else {
                        await w.connect(
                          a,
                          profile: a.profile,
                          organization: a.organization,
                          userId: a.userId,
                        );
                      }
                    }),
                    child: Text(a.enabled ? '暂停' : '恢复'),
                  ),
                  IconButton(
                    tooltip: '退出账号',
                    onPressed: () => guarded(context, () async {
                      if (await confirm(
                        context,
                        '退出 ${a.label}',
                        '系统凭证可能共享。退出此账号可能同时影响系统 CLI 的登录态，是否继续？',
                      )) {
                        await w.disconnect(a, logout: true);
                      }
                    }),
                    icon: const Icon(Icons.logout, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 30),
        Text('模型服务', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8),
        const Text('兼容 Chat Completions 的流式输出与工具调用。Agent 所选资料将发送至下方服务。'),
        const SizedBox(height: 18),
        TextField(
          controller: base,
          decoration: const InputDecoration(
            labelText: 'API 基础地址',
            hintText: 'https://example.com/v1',
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: model,
          decoration: const InputDecoration(labelText: '模型名称'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: key,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'API 密钥',
            hintText: '留空保留已存密钥；仅保存到系统安全存储',
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            FilledButton(
              onPressed: saving || !loaded ? null : () => save(),
              child: Text(saving ? '保存中' : '保存模型配置'),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: () => guarded(context, () async {
                await secureStorage.delete(key: modelKey);
                key.clear();
              }),
              child: const Text('删除已存密钥'),
            ),
          ],
        ),
        const SizedBox(height: 32),
        Text('本地数据', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        SelectableText(w.root),
        const SizedBox(height: 8),
        const Text(
          '消息与索引使用本地 SQLite 存储，未启用数据库整体加密。模型密钥使用系统安全存储。关闭窗口进入托盘，退出应用停止同步。',
          style: TextStyle(fontSize: 12),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => audit(),
          icon: const Icon(Icons.receipt_long_outlined),
          label: const Text('查看执行记录'),
        ),
      ],
    );
  }

  Future<void> save() async {
    setState(() => saving = true);
    await guarded(context, () async {
      completionUri(base.text);
      if (model.text.trim().isEmpty) throw const AppFailure('model', '请填写模型名称');
      if (key.text.isNotEmpty) {
        await secureStorage.write(key: modelKey, value: key.text);
      }
      await ref.read(workspaceProvider).store.put('settings', 'model', {
        'baseUrl': base.text.trim(),
        'model': model.text.trim(),
      });
      key.clear();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('模型配置已保存')));
      }
    });
    if (mounted) setState(() => saving = false);
  }

  Future<void> audit() async {
    final rows = await ref
        .read(workspaceProvider)
        .store
        .list('audit', limit: 100);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('最近执行记录'),
        content: SizedBox(
          width: 650,
          height: 450,
          child: ListView(
            children: rows
                .map(
                  (r) => ListTile(
                    title: Text(
                      '${r['action']} · ${r['state'] ?? r['version'] ?? ''}',
                    ),
                    subtitle: SelectableText(jsonEncode(r)),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

Future<bool> confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 580),
          child: SingleChildScrollView(child: SelectableText(body)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    ) ??
    false;

Future<void> renameAccountDialog(
  BuildContext context,
  WidgetRef ref,
  AccountRef account,
) async {
  final workspace = ref.read(workspaceProvider);
  var name = account.label;
  var saving = false;
  String? error;
  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, set) => AlertDialog(
        title: const Text('修改账号名称'),
        content: SizedBox(
          width: 360,
          child: TextFormField(
            initialValue: account.label,
            autofocus: true,
            enabled: !saving,
            decoration: InputDecoration(
              labelText: '账号名称',
              errorText: error,
              suffixIcon: error == null
                  ? null
                  : IconButton(
                      tooltip: '关闭错误提示',
                      onPressed: () => set(() => error = null),
                      icon: const Icon(Icons.close),
                    ),
            ),
            onChanged: (value) => name = value,
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    if (name.trim().isEmpty) {
                      set(() => error = '账号名称不能为空');
                      return;
                    }
                    set(() {
                      saving = true;
                    });
                    try {
                      await workspace.renameAccount(account.id, name);
                      if (context.mounted) Navigator.pop(context);
                    } catch (e) {
                      if (context.mounted) {
                        set(() {
                          saving = false;
                          error = '$e';
                        });
                      }
                    }
                  },
            child: Text(saving ? '保存中' : '保存'),
          ),
        ],
      ),
    ),
  );
}

Future<void> accountDialog(
  BuildContext context,
  WidgetRef ref,
  String platform, {
  AccountRef? existing,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _AccountDialog(platform: platform, existing: existing),
);

class _AccountDialog extends ConsumerStatefulWidget {
  final String platform;
  final AccountRef? existing;
  const _AccountDialog({required this.platform, this.existing});
  @override
  ConsumerState<_AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends ConsumerState<_AccountDialog> {
  late final TextEditingController label;
  final appId = TextEditingController(), secret = TextEditingController();
  AccountRef? current;
  bool busy = false;
  late bool configure;
  String? error;
  Json? status;
  String get platform => widget.platform;
  AccountRef? get existing => widget.existing;

  @override
  void initState() {
    super.initState();
    current = existing;
    configure = platform == 'feishu' && existing == null;
    label = TextEditingController(
      text: existing?.label ?? (platform == 'dingtalk' ? '我的钉钉' : '我的飞书'),
    );
  }

  @override
  void dispose() {
    label.dispose();
    appId.dispose();
    secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final w = ref.watch(workspaceProvider);
    final url = current == null ? null : w.authUrls[current!.id];
    return AlertDialog(
      title: Text(
        '连接 ${platform == 'dingtalk'
            ? '钉钉'
            : platform == 'feishu'
            ? '飞书'
            : platform}',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('配置与缓存独立保存；系统凭证可能共享，授权操作可能影响系统 CLI 的相同账号。'),
              const SizedBox(height: 16),
              TextField(
                controller: label,
                enabled: !busy && existing == null,
                decoration: const InputDecoration(labelText: '账号备注'),
              ),
              if (platform == 'feishu') ...[
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: configure,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => configure = v!),
                  title: const Text('初始化飞书应用配置'),
                ),
                if (configure) ...[
                  TextField(
                    controller: appId,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: 'App ID（可留空，通过浏览器创建）',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: secret,
                    enabled: !busy,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'App Secret（通过 stdin 传入）',
                    ),
                  ),
                ],
              ],
              if (url != null) ...[
                const SizedBox(height: 14),
                SelectableText(url, style: const TextStyle(fontSize: 12)),
                TextButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse(url),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('打开授权页面'),
                ),
              ],
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: LinearProgressIndicator(),
                ),
              if (error != null)
                ErrorNotices(
                  errors: [error!],
                  onDismiss: (_) => setState(() => error = null),
                ),
              if (status != null) ...[
                const SizedBox(height: 12),
                const Text('选择已授权身份'),
                ...((status!['profiles'] as List? ?? []).map((value) {
                  final profile = object(value);
                  final id =
                      '${profile['profile'] ?? profile['name'] ?? profile['corpId'] ?? ''}';
                  return ListTile(
                    title: Text(
                      '${profile['corpName'] ?? profile['name'] ?? id}',
                    ),
                    subtitle: Text(id),
                    onTap: busy
                        ? null
                        : () async {
                            setState(() {
                              busy = true;
                            });
                            try {
                              await w.connect(
                                current!,
                                profile: id,
                                organization: '${profile['corpName'] ?? ''}',
                                userId: '${profile['userId'] ?? ''}',
                              );
                              if (context.mounted) {
                                Navigator.pop(context);
                              }
                            } catch (e) {
                              if (mounted) setState(() => error = '$e');
                            } finally {
                              if (mounted) setState(() => busy = false);
                            }
                          },
                  );
                })),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  setState(() {
                    busy = true;
                  });
                  try {
                    current ??= await w.addAccount(
                      platform,
                      label.text.trim().isEmpty ? platform : label.text.trim(),
                    );
                    if (!mounted) return;
                    final result = await w.authenticate(
                      current!,
                      configure: configure,
                      config: {'appId': appId.text, 'appSecret': secret.text},
                    );
                    if (!mounted) return;
                    secret.clear();
                    if (platform == 'dingtalk' &&
                        (result['profiles'] as List? ?? []).isNotEmpty) {
                      setState(() => status = result);
                    } else {
                      await w.connect(current!);
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    }
                  } catch (e) {
                    if (context.mounted) setState(() => error = '$e');
                  } finally {
                    if (context.mounted) setState(() => busy = false);
                  }
                },
          child: Text(busy ? '等待授权' : '开始授权'),
        ),
      ],
    );
  }
}
