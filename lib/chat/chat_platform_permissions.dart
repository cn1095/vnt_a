import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

class ChatPermissionResult {
  final bool granted;
  final String message;

  const ChatPermissionResult({
    required this.granted,
    required this.message,
  });
}

/// 聊天室多媒体权限。iOS 暂时只允许观看对方共享屏幕。
class ChatPlatformPermissions {
  static const MethodChannel _vpnChannel = MethodChannel('top.wherewego.vnt/vpn');

  static Future<ChatPermissionResult> requestAudioVideo() async {
    if (Platform.isIOS) {
      return const ChatPermissionResult(
        granted: false,
        message: 'iOS 暂时仅支持查看对方共享屏幕',
      );
    }
    if (Platform.isAndroid) {
      final mic = await Permission.microphone.request();
      final camera = await Permission.camera.request();
      if (mic.isGranted && camera.isGranted) {
        return const ChatPermissionResult(granted: true, message: '音视频权限已允许');
      }
      return const ChatPermissionResult(granted: false, message: '需要允许麦克风和摄像头权限');
    }
    if (Platform.isMacOS) {
      return const ChatPermissionResult(
        granted: true,
        message: 'macOS 首次使用时会由系统弹出麦克风、摄像头权限',
      );
    }
    return const ChatPermissionResult(granted: true, message: '当前平台可发起音视频信令');
  }

  static Future<ChatPermissionResult> requestScreenShare() async {
    if (Platform.isIOS) {
      return const ChatPermissionResult(
        granted: false,
        message: 'iOS 暂时仅支持查看对方共享屏幕，不发起屏幕共享',
      );
    }
    if (Platform.isAndroid) {
      return const ChatPermissionResult(
        granted: true,
        message: 'Android 屏幕共享会在采集开始时请求录屏授权',
      );
    }
    if (Platform.isMacOS) {
      return const ChatPermissionResult(
        granted: true,
        message: 'macOS 需要在系统设置中允许屏幕录制权限',
      );
    }
    if (Platform.isLinux) {
      return const ChatPermissionResult(
        granted: true,
        message: 'Linux 屏幕共享在 Wayland 下可能需要系统门户授权',
      );
    }
    return const ChatPermissionResult(granted: true, message: '当前平台可发起屏幕共享信令');
  }

  static Future<ChatPermissionResult> requestRemoteAssist() async {
    if (Platform.isIOS) {
      return const ChatPermissionResult(
        granted: false,
        message: 'iOS 暂时不支持被远程控制，只能查看屏幕共享',
      );
    }
    if (Platform.isAndroid) {
      final enabled = await _isAndroidAccessibilityEnabled();
      if (enabled) {
        return const ChatPermissionResult(
          granted: true,
          message: 'Android 无障碍权限已开启，可以发起远程协助信令',
        );
      }
      await _openAndroidAccessibilitySettings();
      return const ChatPermissionResult(
        granted: false,
        message: 'Android 远程协助需要先在无障碍设置中开启 VNT 远程协助服务',
      );
    }
    if (Platform.isMacOS) {
      return const ChatPermissionResult(
        granted: true,
        message: 'macOS 远程协助需要辅助功能和屏幕录制权限',
      );
    }
    if (Platform.isLinux) {
      return const ChatPermissionResult(
        granted: true,
        message: 'Linux 远程协助在 Wayland 下可能受系统限制',
      );
    }
    return const ChatPermissionResult(granted: true, message: '当前平台可发送远程协助信令');
  }

  static Future<bool> _isAndroidAccessibilityEnabled() async {
    try {
      final result = await _vpnChannel.invokeMethod<bool>('isRemoteAssistAccessibilityEnabled');
      return result == true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _openAndroidAccessibilitySettings() async {
    try {
      await _vpnChannel.invokeMethod<bool>('openAccessibilitySettings');
    } catch (_) {
      // 跳转失败只影响引导，不影响聊天室其他能力。
    }
  }
}
