import 'package:flutter/services.dart';

/// OS reachability, not a promise that an individual IM service is reachable.
/// Hosts without the native channel retain request-level recovery.
class NetworkMonitor {
  static const channel = MethodChannel('imbroglio/network');
  void Function(bool)? onChanged;
  bool _started = false;

  Future<bool?> check() async {
    try {
      return await channel
          .invokeMethod<bool>('status')
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return null;
    }
  }

  Future<void> start(void Function(bool) listener) async {
    onChanged = listener;
    try {
      channel.setMethodCallHandler((call) async {
        if (call.method == 'changed' && call.arguments is bool) {
          onChanged?.call(call.arguments as bool);
        }
      });
      _started = true;
    } catch (_) {
      return; // Headless hosts may not have a platform messenger.
    }
    final available = await check();
    if (available != null) onChanged?.call(available);
  }

  void dispose() {
    onChanged = null;
    if (_started) channel.setMethodCallHandler(null);
    _started = false;
  }
}
