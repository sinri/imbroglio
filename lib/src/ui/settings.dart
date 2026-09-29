import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../core/models.dart';
import '../core/feishu_auth.dart';
import '../services/agent.dart';
import 'app.dart';
import 'conversation_blacklist.dart';

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
          '安装完成后，请前往「设置 → 账号与授权」连接和管理账号。',
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
  final exitingAccounts = <String>{};
  final cleaningAccounts = <String>{};
  final _sourceQueries = <String, ({Object version, Future<Json?> future})>{};
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
        const Text('按 IM 来源连接账号，管理授权、名称和同步状态。'),
        const SizedBox(height: 16),
        for (final platform in {
          'dingtalk',
          'feishu',
          ...w.packages
              .where((p) => p['kind'] == 'im')
              .map((p) => p['id'] as String),
          ...w.accounts.map((a) => a.platform),
        })
          accountSource(platform),
        const SizedBox(height: 30),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('会话黑名单'),
          subtitle: Text(
            '已配置 ${w.conversationBlacklist.length} 条规则 · 按会话名称排除自动同步',
          ),
          trailing: OutlinedButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => ConversationBlacklistDialog(workspace: w),
            ),
            child: const Text('管理规则'),
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

  Widget accountSource(String platform) {
    final w = ref.read(workspaceProvider);
    final builtin = platform == 'dingtalk' || platform == 'feishu';
    final package = w.packages
        .where((p) => p['kind'] == 'im' && p['id'] == platform)
        .firstOrNull;
    final name = platform == 'dingtalk'
        ? '钉钉'
        : platform == 'feishu'
        ? '飞书'
        : '${package?['name'] ?? platform}';
    final accounts = w.visibleAccounts
        .where((a) => a.platform == platform)
        .toList();
    final Object version = builtin
        ? (w.store, w.store.revision('installations'))
        : jsonEncode(package);
    var query = _sourceQueries[platform];
    if (query == null || query.version != version) {
      query = (
        version: version,
        future: builtin
            ? w.store.get('installations', platform)
            : Future<Json?>.value(package),
      );
      _sourceQueries[platform] = query;
    }
    final archived = w.accounts
        .where((a) => a.platform == platform && a.signedOut)
        .toList();
    return FutureBuilder<Json?>(
      future: query.future,
      builder: (context, snapshot) {
        final installation = snapshot.data;
        final available =
            snapshot.connectionState == ConnectionState.done &&
            !snapshot.hasError &&
            installation != null &&
            (builtin
                ? installation['enabled'] != false
                : installation['enabled'] == true);
        final status = snapshot.hasError
            ? '无法读取插件状态，请重新进入设置'
            : snapshot.connectionState != ConnectionState.done
            ? '正在读取插件状态…'
            : installation == null
            ? '尚未安装插件，请前往插件中心安装'
            : !available
            ? '插件已停用，请前往插件中心启用'
            : '插件已就绪';
        return Card(
          key: ValueKey('account-source:$platform'),
          margin: const EdgeInsets.only(bottom: 16),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      platform == 'dingtalk'
                          ? Icons.bolt
                          : platform == 'feishu'
                          ? Icons.flight
                          : Icons.extension_outlined,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$name · ${accounts.length} 个账号',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            status,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      key: ValueKey('add-account:$platform'),
                      onPressed: available
                          ? () => accountDialog(context, ref, platform)
                          : null,
                      icon: const Icon(Icons.person_add_alt, size: 18),
                      label: const Text('添加账号'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (w.accounts.any(
                  (a) =>
                      a.platform == platform && cleaningAccounts.contains(a.id),
                )) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  const Text('正在清理本地数据…'),
                ],
                if (accounts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('尚未连接账号'),
                  ),
                for (final a in accounts) accountTile(a, available: available),
                if (archived.isNotEmpty)
                  ExpansionTile(
                    key: ValueKey('archived-accounts:$platform'),
                    title: Text('已退出账号的本地数据（${archived.length}）'),
                    subtitle: const Text('这些账号已退出，仅保留本地记录，可在此清理。'),
                    children: [
                      for (final a in archived)
                        ListTile(
                          title: Text(a.label),
                          trailing: TextButton.icon(
                            onPressed: exitingAccounts.contains(a.id)
                                ? null
                                : () => deleteAccountDialog(a),
                            icon: const Icon(Icons.delete_forever_outlined),
                            label: const Text('清理本地数据'),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget accountTile(AccountRef a, {required bool available}) {
    final w = ref.read(workspaceProvider);
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        leading: Icon(a.platform == 'dingtalk' ? Icons.bolt : Icons.flight),
        title: Text(a.label),
        subtitle: Text(
          '${a.organization.isEmpty ? a.profile : a.organization} · ${a.enabled ? '同步已开启' : '未连接 / 已暂停'}${a.canSend ? '' : ' · 缺少发送权限'}',
        ),
        trailing: Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: exitingAccounts.contains(a.id)
                  ? null
                  : () => renameAccountDialog(context, ref, a),
              child: const Text('改名'),
            ),
            TextButton(
              onPressed: exitingAccounts.contains(a.id) || !available
                  ? null
                  : () => accountDialog(context, ref, a.platform, existing: a),
              child: Text(a.canSend ? '授权' : '补充发送授权'),
            ),
            if (!a.signedOut)
              TextButton(
                onPressed:
                    exitingAccounts.contains(a.id) || (!a.enabled && !available)
                    ? null
                    : () => guarded(context, () async {
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
              tooltip: '删除账号及本地数据',
              onPressed: exitingAccounts.contains(a.id)
                  ? null
                  : () => deleteAccountDialog(a),
              icon: const Icon(Icons.delete_forever_outlined, size: 20),
            ),
            IconButton(
              tooltip: cleaningAccounts.contains(a.id)
                  ? '正在清理本地数据'
                  : exitingAccounts.contains(a.id)
                  ? '正在退出账号'
                  : '退出账号',
              onPressed: exitingAccounts.contains(a.id) || a.signedOut
                  ? null
                  : () => guarded(context, () async {
                      if (await confirm(
                        context,
                        '退出 ${a.label}',
                        '系统凭证可能共享。退出此账号可能同时影响系统 CLI 的登录态，是否继续？',
                      )) {
                        if (!mounted) return;
                        setState(() => exitingAccounts.add(a.id));
                        try {
                          await w.disconnect(a, logout: true);
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('已退出 ${a.label}')),
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() => exitingAccounts.remove(a.id));
                          }
                        }
                      }
                    }),
              icon: exitingAccounts.contains(a.id)
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.logout, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> deleteAccountDialog(AccountRef a) async {
    var logout = !a.signedOut;
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (dialogContext, set) => AlertDialog(
              title: Text('彻底清理 ${a.label}'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '将删除此账号在本应用中的账号资料、聊天记录与索引、附件和头像、同步及发送记录、配置和备份。涉及此账号的整个 Agent 会话也会删除，包括其中其他账号的内容。此操作无法撤销。',
                      ),
                      const SizedBox(height: 12),
                      const Text('不会删除云端消息、已导出到其他位置的文件或其他账号的独立数据。'),
                      if (!a.signedOut) ...[
                        const SizedBox(height: 12),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('同时注销登录'),
                          subtitle: const Text(
                            '系统凭证可能共享，注销可能影响系统 CLI。插件不可用时，可取消勾选，仅清理本地数据。',
                          ),
                          value: logout,
                          onChanged: (value) => set(() => logout = value!),
                        ),
                        if (!logout) const Text('仅清理本地数据不会注销登录或撤销服务端授权。'),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(dialogContext).colorScheme.error,
                  ),
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('永久删除'),
                ),
              ],
            ),
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() {
      exitingAccounts.add(a.id);
      cleaningAccounts.add(a.id);
    });
    try {
      await guarded(context, () async {
        await ref.read(workspaceProvider).deleteAccount(a, logout: logout);
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('已清理 ${a.label} 的本地数据')));
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          exitingAccounts.remove(a.id);
          cleaningAccounts.remove(a.id);
        });
      }
    }
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
  bool authorizing = false, stopRequested = false;
  late bool configure;
  String? error;
  String? authStage;
  String? authorizationNotice;
  String? openedAuthUrl;
  bool browserSetup = false;
  bool forceAuthorization = false;
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

  Future<List<String>?> choosePermissions(Json permissions) async {
    if (!mounted || stopRequested) return null;
    final granted = (permissions['granted'] as List).cast<String>().toSet();
    final appScopes = (permissions['appScopes'] as List).cast<String>().toSet();
    final available = {...granted, ...appScopes};
    final canReuse = permissions['canReuse'] == true;
    if (canReuse && granted.containsAll(feishuAllScopes)) {
      return [];
    }
    var sending = granted.containsAll(feishuSendScopes);
    var documents = granted.containsAll(feishuDocumentScopes);
    var agent = granted.containsAll(feishuAgentScopes);
    Widget scopeDetails(Set<String> scopes) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final scope in scopes)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SelectableText(
              '$scope\n${granted.contains(scope)
                  ? '用户已授权'
                  : appScopes.contains(scope)
                  ? '应用已开通 · 待用户授权'
                  : '应用未开通'}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
      ],
    );
    return showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('飞书已有授权'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('应用：${permissions['appId']}'),
                  const SizedBox(height: 12),
                  Text(
                    canReuse
                        ? '现有授权可读取消息，可直接连接。其他功能按需补充授权。'
                        : '需要授权基础消息读取权限后才能连接。',
                  ),
                  if (!available.containsAll(feishuReadScopes))
                    const Text('应用尚未开通基础消息读取权限，请先在飞书开放平台开通后重试。'),
                  const SizedBox(height: 12),
                  const Text(
                    '基础消息读取（必需）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const Text('在飞书开放平台的用户身份权限中搜索以下标识。'),
                  const SizedBox(height: 8),
                  scopeDetails(feishuReadScopes),
                  const Text('包含会话和消息读取、图片附件下载、联系人资料查询、消息搜索。'),
                  TextButton.icon(
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: feishuReadScopes.join('\n')),
                      );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已复制基础读取权限')),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制必需权限'),
                  ),
                  const Divider(),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('发送与回复消息'),
                    subtitle: Text(
                      granted.containsAll(feishuSendScopes)
                          ? '已授权'
                          : available.containsAll(feishuSendScopes)
                          ? '可选，需要用户授权'
                          : '应用尚未开通，请先在飞书开放平台开通',
                    ),
                    value: sending,
                    onChanged:
                        granted.containsAll(feishuSendScopes) ||
                            !available.containsAll(feishuSendScopes)
                        ? null
                        : (v) => update(() => sending = v!),
                  ),
                  scopeDetails(feishuSendScopes),
                  const Divider(),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('搜索与读取文档'),
                    subtitle: Text(
                      granted.containsAll(feishuDocumentScopes)
                          ? '已授权'
                          : available.containsAll(feishuDocumentScopes)
                          ? '可选，需要用户授权'
                          : '应用尚未开通，请先在飞书开放平台开通',
                    ),
                    value: documents,
                    onChanged:
                        granted.containsAll(feishuDocumentScopes) ||
                            !available.containsAll(feishuDocumentScopes)
                        ? null
                        : (v) => update(() => documents = v!),
                  ),
                  scopeDetails(feishuDocumentScopes),
                  const Divider(),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Agent 创建文档与待办'),
                    subtitle: Text(
                      granted.containsAll(feishuAgentScopes)
                          ? '已授权；执行具体操作时仍需确认'
                          : available.containsAll(feishuAgentScopes)
                          ? '可选，需要用户授权；执行具体操作时仍需确认'
                          : '应用尚未开通，请先在飞书开放平台开通',
                    ),
                    value: agent,
                    onChanged:
                        granted.containsAll(feishuAgentScopes) ||
                            !available.containsAll(feishuAgentScopes)
                        ? null
                        : (v) => update(() => agent = v!),
                  ),
                  scopeDetails(feishuAgentScopes),
                  TextButton.icon(
                    onPressed: () => Clipboard.setData(
                      ClipboardData(text: feishuAllScopes.join('\n')),
                    ),
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制全部功能权限'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            if (canReuse)
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, <String>[]),
                child: const Text('使用现有授权连接'),
              ),
            TextButton(
              onPressed: available.containsAll(feishuAllScopes)
                  ? () => Navigator.pop(dialogContext, feishuAllScopes.toList())
                  : null,
              child: const Text('一次性授权全部功能'),
            ),
            FilledButton(
              onPressed: !available.containsAll(feishuReadScopes)
                  ? null
                  : () => Navigator.pop(dialogContext, <String>[
                      ...feishuReadScopes,
                      if (sending) ...feishuSendScopes,
                      if (documents) ...feishuDocumentScopes,
                      if (agent) ...feishuAgentScopes,
                    ]),
              child: Text(canReuse ? '授权所选功能' : '授权并连接'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> openAuthorization(String url) async {
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened && mounted && !stopRequested) {
        setState(() => authorizationNotice = '未能打开浏览器，请点击下方按钮或复制链接完成授权。');
      }
    } catch (_) {
      if (mounted && !stopRequested) {
        setState(() => authorizationNotice = '未能打开浏览器，请点击下方按钮或复制链接完成授权。');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = ref.watch(workspaceProvider);
    final url = current == null ? null : w.authUrls[current!.id];
    if (platform == 'feishu' &&
        authorizing &&
        !stopRequested &&
        url != null &&
        openedAuthUrl != url) {
      openedAuthUrl = url;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            authorizing &&
            !stopRequested &&
            current != null &&
            w.authUrls[current!.id] == url) {
          unawaited(openAuthorization(url));
        }
      });
    }
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
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: forceAuthorization,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => forceAuthorization = v!),
                  title: const Text('重新授权（不复用现有登录）'),
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
                  onPressed: () => openAuthorization(url),
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('打开授权页面'),
                ),
              ],
              if (busy) Text(authStage ?? '连接验证'),
              if (platform == 'feishu' && authorizing) ...[
                const SizedBox(height: 8),
                if (authStage == '应用初始化')
                  const Text('第一步：创建应用配置。网页显示“配置成功”后，请返回这里继续用户授权。'),
                if (authStage == '用户授权')
                  Text(
                    browserSetup
                        ? '应用配置已完成。第二步：授权你的飞书身份，还需在新的授权页面确认。'
                              '如果仍停留在“配置成功”页面，请打开当前授权链接。'
                        : '请在用户授权页面确认你的飞书身份。',
                  ),
                if (authStage == '用户授权' && url == null)
                  const Text('正在获取用户授权链接，获得后会自动打开浏览器。'),
                if (authStage == '连接验证') const Text('用户授权已完成，正在验证连接。'),
              ],
              if (authorizationNotice != null) Text(authorizationNotice!),
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
        if (platform == 'feishu' && authorizing)
          TextButton(
            onPressed: stopRequested
                ? null
                : () {
                    setState(() {
                      stopRequested = true;
                      authStage = '正在中止';
                    });
                    if (current != null) w.cancelAuthentication(current!);
                  },
            child: Text(stopRequested ? '正在中止' : '中止授权'),
          ),
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
                    authorizing = true;
                    stopRequested = false;
                    authorizationNotice = null;
                    openedAuthUrl = null;
                    if (configure) browserSetup = appId.text.trim().isEmpty;
                    error = null;
                    authStage = null;
                  });
                  try {
                    current ??= await w.addAccount(
                      platform,
                      label.text.trim().isEmpty ? platform : label.text.trim(),
                    );
                    if (!mounted) return;
                    if (stopRequested) {
                      throw const AppFailure('cancelled', '授权已中止');
                    }
                    final result = await w.authenticate(
                      current!,
                      configure: configure,
                      config: {
                        'appId': appId.text,
                        'appSecret': secret.text,
                        'forceAuthorization': forceAuthorization,
                      },
                      onPermissions: platform == 'feishu'
                          ? choosePermissions
                          : null,
                      onStage: (stage) {
                        if (!mounted || stopRequested) return;
                        setState(() {
                          authStage = stage;
                          if (stage == '用户授权' || stage == '检查现有授权') {
                            configure = false;
                            secret.clear();
                          }
                        });
                      },
                    );
                    if (!mounted) return;
                    if (stopRequested) {
                      throw const AppFailure('cancelled', '授权已中止');
                    }
                    setState(() => authorizing = false);
                    secret.clear();
                    if (platform == 'dingtalk' &&
                        (result['profiles'] as List? ?? []).isNotEmpty) {
                      setState(() => status = result);
                    } else {
                      try {
                        await w.connect(
                          current!.copyWith(
                            canSend: result['canSend'] != false,
                          ),
                          userId: '${result['userId'] ?? ''}',
                        );
                      } catch (e) {
                        throw AppFailure('connection', '连接验证失败：$e');
                      }
                      if (context.mounted) {
                        Navigator.pop(context);
                      }
                    }
                  } catch (e) {
                    if (context.mounted) {
                      setState(() {
                        if (stopRequested ||
                            (e is AppFailure && e.code == 'cancelled')) {
                          authorizationNotice = '授权已中止';
                        } else {
                          error = '$e';
                        }
                      });
                    }
                  } finally {
                    if (context.mounted) {
                      setState(() {
                        busy = false;
                        authorizing = false;
                      });
                    }
                  }
                },
          child: Text(busy ? '处理中' : '开始授权'),
        ),
      ],
    );
  }
}
