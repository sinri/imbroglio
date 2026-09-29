import 'dart:convert';
import 'dart:io';

/// Startup timings contain stage names and durations, never account/message data.
class StartupTrace {
  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, Object>> events = [];

  void mark(String stage) {
    events.add({'stage': stage, 'elapsedUs': _clock.elapsedMicroseconds});
  }

  Future<T> measure<T>(String stage, Future<T> Function() action) async {
    final start = _clock.elapsedMicroseconds;
    try {
      return await action();
    } finally {
      events.add({
        'stage': stage,
        'elapsedUs': _clock.elapsedMicroseconds,
        'durationUs': _clock.elapsedMicroseconds - start,
      });
    }
  }

  Map<String, Object> toJson() => {'version': 1, 'events': events};

  Future<void> save(String path) async {
    try {
      await File(path).writeAsString(jsonEncode(toJson()));
    } catch (_) {
      // Optional diagnostics must not prevent startup.
    }
  }
}
