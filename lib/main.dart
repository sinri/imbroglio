import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'src/services/workspace.dart';
import 'src/services/desktop.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final workspace = Workspace();
  await workspace.initialize();
  if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1320, 860),
        minimumSize: Size(960, 640),
        title: 'Imbroglio',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
    if (workspace.ready) await DesktopIntegration(workspace).initialize();
  }
  runApp(
    ProviderScope(
      overrides: [workspaceProvider.overrideWith((ref) => workspace)],
      child: const ImbroglioApp(),
    ),
  );
}
