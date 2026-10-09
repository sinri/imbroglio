import 'dart:io';

import 'package:local_notifier/local_notifier.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'workspace.dart';

class DesktopIntegration with WindowListener {
  final Workspace workspace;
  TrayIcon? icon;
  Menu? _trayMenu;
  MenuItem? _openItem;
  MenuItem? _quitItem;
  var _quitting = false;
  DesktopIntegration(this.workspace);
  Future<void> initialize() async {
    windowManager.addListener(this);
    // macOS can restore the window from the Dock even without a tray icon.
    if (Platform.isMacOS) await windowManager.setPreventClose(true);
    workspace.windowFocused = await windowManager.isFocused();
    try {
      await localNotifier.setup(
        appName: 'Imbroglio',
        shortcutPolicy: ShortcutPolicy.requireCreate,
      );
      workspace.onIncoming = (message) async {
        if (workspace.chatVisible &&
            workspace.selectedConversation?.accountId == message.accountId &&
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
          workspace.requestMessagesPage?.call();
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
      quit.addListener((event) {
        if (event is MenuItemClickedEvent && _quitItem != null) {
          // The click is delivered inside the native menu loop. Leave that
          // call before tearing down the tray icon and the process.
          Future<void>(() => quitApp());
        }
      });
      menu.addItem(quit);
      // Menu items free their native handles when collected. Keep them alive
      // for as long as the tray icon is shown.
      _trayMenu = menu;
      _openItem = open;
      _quitItem = quit;
      icon!.setContextMenu(menu);
      // Windows leaves the trigger at None, so assigning a menu does not open
      // it. Right-click is the notification-area convention.
      if (Platform.isWindows) {
        icon!.setContextMenuTrigger(ContextMenuTrigger.rightClicked);
      }
      icon!.setVisible(true);
      icon!.addListener((event) {
        if (_trayMenu == null || _openItem == null) return;
        if (event is TrayIconClickedEvent) show();
      });
      await windowManager.setPreventClose(true);
    } catch (_) {
      workspace.notice = Platform.isMacOS
          ? '托盘不可用，可点击 Dock 图标重新打开窗口'
          : '托盘不可用，关闭窗口将退出应用';
    }
  }

  Future<void> show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  /// Stops sync, removes the tray icon, and ends the process.
  ///
  /// Closing the window only hides it while the tray icon exists. This path
  /// clears that icon first so the close is not turned back into a hide.
  Future<void> quitApp() async {
    if (_quitting) return;
    _quitting = true;
    final tray = icon;
    icon = null;
    try {
      await workspace.close();
    } catch (_) {
      /* still leave the process */
    }
    tray?.dispose();
    try {
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } catch (_) {
      /* the process exit below is the backstop */
    }
    exit(0);
  }

  @override
  void onWindowFocus() {
    workspace.updateReading(focused: true);
  }

  @override
  void onWindowBlur() {
    workspace.updateReading(focused: false);
  }

  @override
  void onWindowClose() async {
    if (_quitting) return;
    if (Platform.isMacOS || icon != null) await windowManager.hide();
  }
}
