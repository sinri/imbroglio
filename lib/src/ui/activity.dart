import 'dart:async';
import 'package:flutter/material.dart';
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
              const SizedBox(width: 8),
              const Icon(Icons.expand_less, size: 18),
            ],
          ),
        ),
      ),
    );
  }
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
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String clock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  Widget entry(BackgroundActivity task) {
    final now = DateTime.now();
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
    final w = ref.watch(workspaceProvider);
    final items = w.activities.items;
    final running = items.where((e) => e.running).toList();
    final finished = items.where((e) => !e.running).toList();
    return AlertDialog(
      title: const Text('后台活动'),
      content: SizedBox(
        width: 680,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${running.length} 项进行中 · ${w.activities.attentionCount} 项需留意',
            ),
            if (w.backgroundPending > 0)
              Text('近 90 天历史待补齐：${w.backgroundPending} 个会话'),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                '显示本次运行的活动；重复同步合并显示最近一次。',
                style: TextStyle(fontSize: 12),
              ),
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
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
