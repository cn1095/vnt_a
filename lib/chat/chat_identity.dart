import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import 'package:vnt_app/network_config.dart';

/// 生成组网指纹。只发送摘要，不发送 token 或组网密码明文。
class ChatIdentity {
  static const Uuid _uuid = Uuid();

  static String newId() {
    return _uuid.v4();
  }

  static String networkId(NetworkConfig config) {
    final source = <String>[
      config.token,
      config.serverAddress,
      config.groupPassword,
      config.encryptionAlgorithm,
      config.useChannelType,
      'vnt-chat-v1',
    ].join('|');
    return sha256.convert(utf8.encode(source)).toString();
  }

  static String roomPasswordHash(String roomId, String password) {
    if (password.trim().isEmpty) {
      return '';
    }
    return sha256.convert(utf8.encode('$roomId|$password|vnt-room')).toString();
  }
}
