/// Session-local activity summaries; never stores message bodies or RPC payloads.
class BackgroundActivity {
  final String key, title, scope;
  final DateTime startedAt = DateTime.now();
  DateTime? finishedAt, retryAt;
  String state = 'running', detail = '';
  final void Function() _changed;
  BackgroundActivity(this.key, this.title, this.scope, this._changed);
  bool get running => state == 'running';
  bool get needsAttention =>
      state == 'failed' || state == 'waiting' || state == 'unknown';
  void progress(String value) {
    detail = value;
    _changed();
  }

  void finish({String state = 'completed', String? detail, DateTime? retryAt}) {
    if (!running) return;
    this.state = state;
    this.detail = detail ?? this.detail;
    this.retryAt = retryAt;
    finishedAt = DateTime.now();
    _changed();
  }
}

class ActivityLog {
  final void Function() _changed;
  final _items = <BackgroundActivity>[];
  ActivityLog(this._changed);
  List<BackgroundActivity> get items => List.unmodifiable(_items);
  int get runningCount => _items.where((e) => e.running).length;
  int get attentionCount => _items.where((e) => e.needsAttention).length;
  BackgroundActivity begin(String key, String title, String scope) {
    // Repeated polling replaces its previous summary rather than filling a log.
    _items.removeWhere((e) => e.key == key && !e.running);
    final task = BackgroundActivity(key, title, scope, () {
      _trim();
      _changed();
    });
    _items.insert(0, task);
    _trim();
    _changed();
    return task;
  }

  void removeScope(String scope) {
    _items.removeWhere((item) => item.scope == scope);
  }

  void _trim() {
    final finished = _items.where((e) => !e.running).toList();
    for (final entry in finished.skip(40)) {
      _items.remove(entry);
    }
  }

  Future<T> run<T>(
    String key,
    String title,
    String scope,
    Future<T> Function(BackgroundActivity) work,
  ) async {
    final task = begin(key, title, scope);
    try {
      final result = await work(task);
      task.finish();
      return result;
    } catch (e) {
      task.finish(state: 'failed', detail: '$e');
      rethrow;
    }
  }
}
