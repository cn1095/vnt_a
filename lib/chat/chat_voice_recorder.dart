import 'dart:io';

import 'package:flutter/services.dart';

class ChatVoiceRecordResult {
  final String path;
  final int durationMs;

  const ChatVoiceRecordResult({
    required this.path,
    required this.durationMs,
  });
}

class ChatVoiceRecorder {
  static const MethodChannel _channel = MethodChannel('top.wherewego.vnt/chat_voice');

  static Future<bool> start() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('startRecord');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  static Future<ChatVoiceRecordResult?> stop() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('stopRecord');
      if (result == null) {
        return null;
      }
      final path = result['path']?.toString() ?? '';
      final durationMs = result['durationMs'] is int ? result['durationMs'] as int : 0;
      if (path.isEmpty || durationMs <= 0) {
        return null;
      }
      return ChatVoiceRecordResult(path: path, durationMs: durationMs);
    } catch (_) {
      return null;
    }
  }

  static Future<void> cancel() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('cancelRecord');
    } catch (_) {}
  }

  static Future<bool> play(String url) async {
    if (!Platform.isAndroid || url.isEmpty) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('playRecord', <String, dynamic>{
        'url': url,
      });
      return result == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopPlay() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('stopPlay');
    } catch (_) {}
  }
}
