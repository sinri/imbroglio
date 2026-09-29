import 'workspace.dart';

/// First make the loading frame visible; only then start disk/database work.
Future<void> startWorkspace(
  Workspace workspace, {
  String? directory,
  required Future<void> Function() showWindow,
  required Future<void> Function() initializeDesktop,
}) async {
  try {
    await workspace.startupTrace.measure('window.show', showWindow);
    await Future<void>.delayed(Duration.zero);
    await workspace.initialize(directory: directory);
  } catch (e) {
    workspace.fatal = '启动失败：$e';
    workspace.changed();
  }
  workspace.startupTrace.mark(
    workspace.ready ? 'startup.ready' : 'startup.failed',
  );
  await workspace.saveStartupTrace();
  if (workspace.ready) {
    try {
      await workspace.startupTrace.measure(
        'desktop.initialize',
        initializeDesktop,
      );
    } catch (_) {
      workspace.notice = '桌面通知或托盘初始化失败，可继续使用工作台';
      workspace.changed();
    }
    await workspace.saveStartupTrace();
  }
}
