/// 聊天室运行时清理注册表。
///
/// VNT 断开、切换配置、应用退出前都需要先关闭聊天室 TCP socket 和文件共享服务，
/// 避免底层虚拟网卡停止后聊天室仍在读写 socket 导致 UI 卡顿或状态残留。
class ChatRuntimeRegistry {
  static final Map<Object, Future<void> Function()> _cleaners =
      <Object, Future<void> Function()>{};
  static bool _cleaning = false;

  static void register(Object owner, Future<void> Function() cleaner) {
    _cleaners[owner] = cleaner;
  }

  static void unregister(Object owner) {
    _cleaners.remove(owner);
  }

  static bool get hasActiveRuntime => _cleaners.isNotEmpty;

  static Future<void> disposeAll({Object? except}) async {
    if (_cleaning) {
      return;
    }
    _cleaning = true;
    try {
      final entries = _cleaners.entries.toList();
      for (final entry in entries) {
        if (except != null && identical(entry.key, except)) {
          continue;
        }
        try {
          await entry.value().timeout(const Duration(seconds: 3));
        } catch (_) {
          // 单个聊天室清理失败不能阻塞 VNT 断开或应用退出。
        }
      }
    } finally {
      _cleaning = false;
    }
  }
}
