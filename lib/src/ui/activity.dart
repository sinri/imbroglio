import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/activity.dart';
import 'app.dart';

class BackgroundActivityBar extends ConsumerWidget {
  const BackgroundActivityBar({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref.watch(workspaceProvider);
    final log = w.activities;
    final current = log.items.where((e) => e.running).firstOrNull;
    final warning = log.attentionCount;
    final connected = w.accounts.any((a) => a.enabled);
    final summary = current != null
        ? '${current.title} · ${current.scope}'
        : warning > 0
        ? '$warning 项后台活动需要留意'
        : log.items.isNotEmpty
        ? '最近完成：${log.items.first.title}'
        : connected
        ? '后台待命，等待下一次同步'
        : '未连接账号';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => const BackgroundActivityDialog(),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              if (current != null)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(
                  warning > 0 ? Icons.info_outline : Icons.cloud_done_outlined,
                  size: 17,
                ),
              const SizedBox(width: 10),
              const Text(
                '后台活动',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              if (w.backgroundPending > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '历史待补齐 ${w.backgroundPending} 个会话',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              if (current != null)
                Text(
                  '${log.runningCount} 项进行中',
                  style: const TextStyle(fontSize: 12),
                ),
              if (current != null && warning > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    '$warning 项异常',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'CLI 诊断记录',
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const DiagnosticDialog(),
                ),
                icon: Badge(
                  isLabelVisible: w.diagnostics.isNotEmpty,
                  label: Text('${w.diagnostics.length}'),
                  child: const Icon(Icons.bug_report_outlined, size: 18),
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.expand_less, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

// Copy mutable activity values so progress notifications cannot change a snapshot.
class _ActivitySnapshot {
  _ActivitySnapshot(BackgroundActivity task)
    : title = task.title,
      scope = task.scope,
      startedAt = task.startedAt,
      finishedAt = task.finishedAt,
      retryAt = task.retryAt,
      state = task.state,
      detail = task.detail,
      running = task.running,
      needsAttention = task.needsAttention;

  final String title, scope, state, detail;
  final DateTime startedAt;
  final DateTime? finishedAt, retryAt;
  final bool running, needsAttention;
}

class BackgroundActivityDialog extends ConsumerStatefulWidget {
  const BackgroundActivityDialog({super.key});
  @override
  ConsumerState<BackgroundActivityDialog> createState() =>
      _BackgroundActivityDialogState();
}

class _BackgroundActivityDialogState
    extends ConsumerState<BackgroundActivityDialog> {
  Timer? _timer;
  bool _autoRefresh = true;
  List<_ActivitySnapshot> _items = [];
  int _backgroundPending = 0;
  DateTime _refreshedAt = DateTime.now();

  void _capture() {
    final w = ref.read(workspaceProvider);
    _items = w.activities.items.map(_ActivitySnapshot.new).toList();
    _backgroundPending = w.backgroundPending;
    _refreshedAt = DateTime.now();
  }

  void _refresh() => setState(_capture);

  @override
  void initState() {
    super.initState();
    _capture();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted && _autoRefresh) _refresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String clock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  Widget entry(_ActivitySnapshot task) {
    final now = _refreshedAt;
    final elapsed = (task.finishedAt ?? now)
        .difference(task.startedAt)
        .inSeconds;
    final status = switch (task.state) {
      'running' => '进行中',
      'failed' => '失败',
      'waiting' => '需留意',
      'unknown' => '结果待确认',
      _ => '已完成',
    };
    final retry = task.retryAt;
    final timing = retry == null
        ? ''
        : retry.isAfter(now)
        ? ' · 预计 ${clock(retry)} 后重试'
        : ' · 等待调度重试';
    return ListTile(
      leading: task.running
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              task.needsAttention
                  ? Icons.info_outline
                  : Icons.check_circle_outline,
              color: task.needsAttention
                  ? Theme.of(context).colorScheme.error
                  : null,
            ),
      title: Text('${task.title} · ${task.scope}'),
      subtitle: Text(
        [
          if (task.detail.isNotEmpty) task.detail,
          '$status · ${clock(task.startedAt)} · ${elapsed}s$timing',
        ].join('\n'),
      ),
      isThreeLine: task.detail.isNotEmpty,
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    final running = items.where((e) => e.running).toList();
    final finished = items.where((e) => !e.running).toList();
    final attentionCount = items.where((e) => e.needsAttention).length;
    return AlertDialog(
      title: const Text('后台活动'),
      content: SizedBox(
        width: 680,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${running.length} 项进行中 · $attentionCount 项需留意'),
            if (_backgroundPending > 0)
              Text('近 7 天历史待补齐：$_backgroundPending 个会话'),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '显示本次运行的活动；重复同步合并显示最近一次。自动刷新间隔为 5 秒。',
                style: TextStyle(fontSize: 12),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${_autoRefresh ? '自动刷新中' : '已暂停刷新'} · ${clock(_refreshedAt)} 更新',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setState(() {
                    _autoRefresh = !_autoRefresh;
                    if (_autoRefresh) _capture();
                  }),
                  icon: Icon(_autoRefresh ? Icons.pause : Icons.play_arrow),
                  label: Text(_autoRefresh ? '暂停刷新' : '恢复刷新'),
                ),
                TextButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('立即刷新'),
                ),
              ],
            ),
            const Divider(),
            Expanded(
              child: items.isEmpty
                  ? const Center(child: Text('暂无后台活动，自动同步开始后会在这里显示'))
                  : ListView(
                      children: [...running.map(entry), ...finished.map(entry)],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const DiagnosticDialog(),
          ),
          child: const Text('CLI 诊断记录'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class DiagnosticDialog extends ConsumerWidget {
  const DiagnosticDialog({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final w = ref.watch(workspaceProvider);
    return AlertDialog(
      title: const Text('CLI 诊断记录'),
      content: SizedBox(
        width: 720,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('本地保存最近 200 条错误摘要，重启后保留。敏感字段和链接已过滤。'),
            const SizedBox(height: 12),
            Expanded(
              child: w.diagnostics.isEmpty
                  ? const Center(child: Text('暂无 CLI 故障记录'))
                  : ListView.builder(
                      itemCount: w.diagnostics.length,
                      itemBuilder: (context, index) {
                        final row = w.diagnostics[index];
                        final conversation = w.conversations
                            .where(
                              (c) =>
                                  c.accountId == row['accountId'] &&
                                  c.id == row['conversationId'],
                            )
                            .firstOrNull;
                        final text = [
                          '${messageTimeLabel(row['timestamp'] as int)} · ${row['account']}',
                          '${row['operation']}${row['exitCode'] == null ? '' : ' · 退出码 ${row['exitCode']}'}',
                          if (conversation != null) '会话：${conversation.title}',
                          '${row['detail']}',
                        ].join('\n');
                        return SelectionArea(
                          key: ValueKey((row['id'], text)),
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: Text(text)),
                                  IconButton(
                                    tooltip: '复制诊断记录',
                                    icon: const Icon(Icons.copy, size: 18),
                                    onPressed: () => Clipboard.setData(
                                      ClipboardData(text: text),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
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
    );
  }
}
