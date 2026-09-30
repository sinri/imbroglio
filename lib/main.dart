import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'src/core/window_geometry.dart';
import 'src/services/workspace.dart';
import 'src/services/desktop.dart';
import 'src/ui/app.dart';
import 'src/services/startup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final workspace = Workspace();
  runApp(
    ProviderScope(
      overrides: [workspaceProvider.overrideWith((ref) => workspace)],
      child: const ImbroglioApp(),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    workspace.startupTrace.mark('flutter.first-frame');
    await startWorkspace(
      workspace,
      directory: Platform.environment['IMBROGLIO_WORKSPACE'],
      showWindow: () async {
        await prepareWindow();
        if (Platform.isMacOS) {
          final nativeUs = await const MethodChannel(
            'imbroglio/startup',
          ).invokeMethod<int>('flutterReady');
          if (nativeUs != null) {
            workspace.startupTrace.events.add({
              'stage': 'native.window-to-flutter-ready',
              'durationUs': nativeUs,
            });
          }
          // The native loading window is already visible. Finishing startup
          // must not reopen it or steal focus after the user switches apps.
          return;
        }
        await windowManager.show();
        await windowManager.focus();
      },
      initializeDesktop: () => DesktopIntegration(workspace).initialize(),
    );
  });
}

Future<void> prepareWindow() async {
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    if (Platform.isMacOS) {
      // Native startup owns geometry. The generic ready-to-show helper also
      // restores minimized windows and exits fullscreen, undoing user actions.
      await windowManager.setTitle('Imbroglio');
      return;
    }
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(title: 'Imbroglio'),
    );
    try {
      final displays = await screenRetriever.getAllDisplays();
      final cursor = await screenRetriever.getCursorScreenPoint();
      final display =
          displays
              .where(
                (d) =>
                    ((d.visiblePosition ?? Offset.zero) &
                            (d.visibleSize ?? d.size))
                        .contains(cursor),
              )
              .firstOrNull ??
          await screenRetriever.getPrimaryDisplay();
      final bounds = initialWindowBounds(
        (display.visiblePosition ?? Offset.zero) &
            (display.visibleSize ?? display.size),
      );
      await windowManager.setMinimumSize(
        Size(bounds.width.clamp(1, 960), bounds.height.clamp(1, 640)),
      );
      await windowManager.setBounds(bounds);
    } catch (_) {
      // Keep startup usable if the platform cannot report its work area.
      await windowManager.setSize(const Size(960, 640));
      await windowManager.center();
    }
  }
}
