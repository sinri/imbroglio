import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/workspace.dart';
import '../services/agent.dart';
import 'messages.dart';
import 'search.dart';
import 'agent_page.dart';
import 'settings.dart';
import 'activity.dart';

final workspaceProvider = ChangeNotifierProvider<Workspace>(
  (ref) => Workspace()..initialize(),
);
final themeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);
final agentProvider = ChangeNotifierProvider<AgentController>(
  (ref) => AgentController(ref.read(workspaceProvider)),
);

class ImbroglioApp extends ConsumerWidget {
  const ImbroglioApp({super.key});
  ThemeData theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff5366dc),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      scaffoldBackgroundColor: scheme.surface,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant.withValues(alpha: .5),
        space: 1,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'Imbroglio',
    debugShowCheckedModeBanner: false,
    theme: theme(Brightness.light),
    darkTheme: theme(Brightness.dark),
    themeMode: ref.watch(themeProvider),
    builder: (context, child) => LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 960 && box.maxHeight >= 640) return child!;
        final size = Size(
          box.maxWidth < 960 ? 960 : box.maxWidth,
          box.maxHeight < 640 ? 640 : box.maxHeight,
        );
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox.fromSize(
            size: size,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(size: size),
              child: child!,
            ),
          ),
        );
      },
    ),
    home: const WorkspaceShell(),
  );
}

class WorkspaceShell extends ConsumerStatefulWidget {
  const WorkspaceShell({super.key});
  @override
  ConsumerState<WorkspaceShell> createState() => _WorkspaceShellState();
}

class _WorkspaceShellState extends ConsumerState<WorkspaceShell> {
  int page = 0;
  @override
  void initState() {
    super.initState();
    ref.read(workspaceProvider).requestMessagesPage = () {
      if (!mounted) return;
      setState(() => page = 0);
      ref.read(workspaceProvider).updateReading(visible: true);
    };
  }

  @override
  Widget build(BuildContext context) {
    final w = ref.watch(workspaceProvider),
        color = Theme.of(context).colorScheme;
    if (w.fatal != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(40),
            child: SelectableText('启动失败\n${w.fatal}'),
          ),
        ),
      );
    }
    if (!w.ready) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.hub_outlined, size: 48, color: color.primary),
              const SizedBox(height: 20),
              Text(
                'Imbroglio',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
              const SizedBox(height: 20),
              const Text('正在加载，请稍候'),
              const SizedBox(height: 8),
              Text(
                w.startupStatus,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 88,
            color: color.surfaceContainerLow,
            child: Column(
              children: [
                const SizedBox(height: 30),
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color.primary,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.hub_outlined, color: color.onPrimary),
                ),
                const SizedBox(height: 30),
                Expanded(
                  child: NavigationRail(
                    backgroundColor: Colors.transparent,
                    selectedIndex: page,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: (i) {
                      setState(() => page = i);
                      w.updateReading(visible: i == 0);
                    },
                    destinations: const [
                      NavigationRailDestination(
                        icon: Icon(Icons.forum_outlined),
                        selectedIcon: Icon(Icons.forum),
                        label: Text('消息'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.manage_search),
                        label: Text('资料'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.auto_awesome_outlined),
                        label: Text('Agent'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.extension_outlined),
                        label: Text('插件'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.tune),
                        label: Text('设置'),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: IconButton(
                    tooltip: '切换主题',
                    onPressed: () {
                      ref.read(themeProvider.notifier).state =
                          Theme.of(context).brightness == Brightness.dark
                          ? ThemeMode.light
                          : ThemeMode.dark;
                    },
                    icon: const Icon(Icons.brightness_6_outlined),
                  ),
                ),
              ],
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Text(
                        ['消息工作台', '资料与知识', 'Agent 工作台', '插件中心', '偏好与账号'][page],
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          color: w.accounts.any((a) => a.enabled)
                              ? Colors.teal
                              : color.outline,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${w.accounts.where((a) => a.enabled).length} 个账号已连接',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(width: 20),
                      const Text(
                        'IMBROGLIO',
                        style: TextStyle(
                          letterSpacing: 2,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                if (w.notice != null)
                  MaterialBanner(
                    content: Text(
                      w.notice!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          w.notice = null;
                          w.changed();
                        },
                        child: const Text('关闭'),
                      ),
                    ],
                  ),
                Expanded(
                  child: IndexedStack(
                    index: page,
                    children: [
                      MessagesPage(onSetup: () => setState(() => page = 3)),
                      SearchPage(onMessage: () => setState(() => page = 0)),
                      const AgentPage(),
                      const PluginsPage(),
                      const SettingsPage(),
                    ],
                  ),
                ),
                const Divider(height: 1),
                const BackgroundActivityBar(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> guarded(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), duration: const Duration(seconds: 8)),
      );
    }
  }
}

Widget emptyState(
  BuildContext context,
  IconData icon,
  String title,
  String detail, {
  Widget? action,
}) => Center(
  child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 450),
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 52, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 22),
          Text(
            title,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.6,
            ),
          ),
          if (action != null) ...[const SizedBox(height: 24), action],
        ],
      ),
    ),
  ),
);
String timeLabel(int timestamp) {
  if (timestamp <= 0) return '时间未知';
  final d = DateTime.fromMillisecondsSinceEpoch(timestamp);
  return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String messageTimeLabel(int timestamp) {
  if (timestamp <= 0) return '发送时间未知';
  final d = DateTime.fromMillisecondsSinceEpoch(timestamp).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}
