import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'workspace.dart';

class DesktopIntegration with WindowListener {
  final Workspace workspace;
  TrayIcon? icon;
  DesktopIntegration(this.workspace);
  Future<void> initialize() async {
    try {
      await localNotifier.setup(
        appName: 'Imbroglio',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      workspace.onIncoming = (message) async {
        if (workspace.selectedConversation?.accountId == message.accountId &&
            workspace.selectedConversation?.id == message.conversationId &&
            await windowManager.isFocused()) {
          return;
        }
        final notification = LocalNotification(
          title: message.sender.isEmpty ? '新消息' : message.sender,
          body: message.text.length > 120
              ? '${message.text.substring(0, 120)}…'
              : message.text,
        );
        notification.onClick = () async {
          await show();
          final c = workspace.conversations
              .where(
                (c) =>
                    c.accountId == message.accountId &&
                    c.id == message.conversationId,
              )
              .firstOrNull;
          if (c != null) await workspace.selectConversation(c);
        };
        try {
          await notification.show();
        } catch (_) {
          /* optional desktop capability */
        }
      };
    } catch (_) {
      workspace.notice = '系统通知不可用，可继续在应用内查看消息';
    }
    try {
      icon = TrayIcon.create();
      if (icon == null) throw StateError('Tray unavailable');
      icon!.icon = ImageAsset.fromAsset('assets/tray.png');
      icon!.setTooltip('Imbroglio');
      final menu = Menu.create()!;
      final open = MenuItem.createWithLabelAndType(
        '打开 Imbroglio',
        MenuItemType.normal,
      )!;
      open.addListener((event) {
        if (event is MenuItemClickedEvent) show();
      });
      menu.addItem(open);
      menu.addSeparator();
      final quit = MenuItem.createWithLabelAndType(
        '退出并停止同步',
        MenuItemType.normal,
      )!;
      quit.addListener((event) async {
        if (event is MenuItemClickedEvent) {
          await workspace.close();
          icon?.dispose();
          await windowManager.setPreventClose(false);
          await windowManager.close();
        }
      });
      menu.addItem(quit);
      icon!.setContextMenu(menu);
      icon!.setVisible(true);
      icon!.addListener((event) {
        if (event is TrayIconClickedEvent) show();
      });
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
    } catch (_) {
      workspace.notice = '托盘不可用，关闭窗口将退出应用';
    }
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  @override
  void onWindowClose() async {
    if (icon != null) await windowManager.hide();
  }
}
