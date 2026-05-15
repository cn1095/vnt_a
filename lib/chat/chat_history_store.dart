import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'chat_models.dart';

/// 本地聊天记录。使用 JSONL 便于流式追加和同步，不上传任何中心服务器。
class ChatHistoryStore {
  static const int maxRoomBytes = 20 * 1024 * 1024;

  Future<Directory> _baseDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}vnt_chat');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _roomFile(String networkId, String roomId) async {
    final dir = await _baseDir();
    final safeNetwork = _safeName(networkId);
    final safeRoom = _safeName(roomId);
    return File('${dir.path}${Platform.pathSeparator}${safeNetwork}_$safeRoom.jsonl');
  }

  Future<List<ChatMessage>> loadMessages(String networkId, String roomId) async {
    final file = await _roomFile(networkId, roomId);
    if (!await file.exists()) {
      return <ChatMessage>[];
    }
    final messages = <ChatMessage>[];
    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }
      try {
        final json = jsonDecode(line);
        if (json is Map) {
          messages.add(ChatMessage.fromJson(Map<String, dynamic>.from(json)));
        }
      } catch (_) {
        // 单条坏记录不影响聊天室整体加载。
      }
    }
    messages.sort((a, b) {
      final timeResult = a.timestamp.compareTo(b.timestamp);
      if (timeResult != 0) {
        return timeResult;
      }
      return a.sequence.compareTo(b.sequence);
    });
    return messages;
  }

  Future<void> appendMessage(
    String networkId,
    ChatMessage message,
  ) async {
    final file = await _roomFile(networkId, message.roomId);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    await file.writeAsString(
      jsonEncode(message.toJson()) + '\n',
      mode: FileMode.append,
      flush: false,
    );
    await _trimIfNeeded(file);
  }

  Future<void> appendMessages(
    String networkId,
    String roomId,
    List<ChatMessage> messages,
  ) async {
    if (messages.isEmpty) {
      return;
    }
    final file = await _roomFile(networkId, roomId);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    final buffer = StringBuffer();
    for (final message in messages) {
      buffer.writeln(jsonEncode(message.toJson()));
    }
    await file.writeAsString(buffer.toString(), mode: FileMode.append);
    await _trimIfNeeded(file);
  }

  Future<void> deleteRoom(String networkId, String roomId) async {
    final file = await _roomFile(networkId, roomId);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<void> deleteNetwork(String networkId) async {
    final dir = await _baseDir();
    final safeNetwork = _safeName(networkId);
    if (!await dir.exists()) {
      return;
    }
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.split(Platform.pathSeparator).last.startsWith(safeNetwork)) {
        await entity.delete();
      }
    }
  }

  Future<void> _trimIfNeeded(File file) async {
    if (!await file.exists()) {
      return;
    }
    final length = await file.length();
    if (length <= maxRoomBytes) {
      return;
    }
    final lines = await file.readAsLines();
    var kept = lines;
    while (kept.isNotEmpty && utf8.encode(kept.join('\n')).length > maxRoomBytes) {
      final removeCount = kept.length < 50 ? 1 : 50;
      kept = kept.sublist(removeCount);
    }
    await file.writeAsString(kept.join('\n') + (kept.isEmpty ? '' : '\n'));
  }

  String _safeName(String value) {
    return value.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
  }
}
