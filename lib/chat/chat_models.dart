import 'dart:convert';

/// 聊天室基础端口。所有通信都走 VNT 虚拟 IP，不依赖中心聊天服务器。
class ChatPorts {
  static const int control = 39271;
  static const int files = 39272;
  static const int rtcSignal = 39273;
}

class ChatPacketType {
  static const String hello = 'hello';
  static const String roomCreate = 'roomCreate';
  static const String roomList = 'roomList';
  static const String join = 'join';
  static const String joinResult = 'joinResult';
  static const String leave = 'leave';
  static const String message = 'message';
  static const String historyRequest = 'historyRequest';
  static const String historyChunk = 'historyChunk';
  static const String callInvite = 'callInvite';
  static const String callSignal = 'callSignal';
  static const String screenShare = 'screenShare';
  static const String remoteControl = 'remoteControl';
}

class ChatMessageType {
  static const String text = 'text';
  static const String system = 'system';
  static const String file = 'file';
  static const String image = 'image';
  static const String video = 'video';
  static const String voice = 'voice';
  static const String call = 'call';
}

class ChatRoomInfo {
  final String roomId;
  final String networkId;
  final String name;
  final String ownerDeviceId;
  final String ownerName;
  final String ownerIp;
  final bool hasPassword;
  final int memberCount;
  final int updatedAt;

  const ChatRoomInfo({
    required this.roomId,
    required this.networkId,
    required this.name,
    required this.ownerDeviceId,
    required this.ownerName,
    required this.ownerIp,
    required this.hasPassword,
    required this.memberCount,
    required this.updatedAt,
  });

  ChatRoomInfo copyWith({
    String? ownerIp,
    int? memberCount,
    int? updatedAt,
  }) {
    return ChatRoomInfo(
      roomId: roomId,
      networkId: networkId,
      name: name,
      ownerDeviceId: ownerDeviceId,
      ownerName: ownerName,
      ownerIp: ownerIp ?? this.ownerIp,
      hasPassword: hasPassword,
      memberCount: memberCount ?? this.memberCount,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'roomId': roomId,
      'networkId': networkId,
      'name': name,
      'ownerDeviceId': ownerDeviceId,
      'ownerName': ownerName,
      'ownerIp': ownerIp,
      'hasPassword': hasPassword,
      'memberCount': memberCount,
      'updatedAt': updatedAt,
    };
  }

  factory ChatRoomInfo.fromJson(Map<String, dynamic> json) {
    return ChatRoomInfo(
      roomId: json['roomId']?.toString() ?? '',
      networkId: json['networkId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      ownerDeviceId: json['ownerDeviceId']?.toString() ?? '',
      ownerName: json['ownerName']?.toString() ?? '',
      ownerIp: json['ownerIp']?.toString() ?? '',
      hasPassword: json['hasPassword'] == true,
      memberCount: json['memberCount'] is int ? json['memberCount'] as int : 0,
      updatedAt: json['updatedAt'] is int ? json['updatedAt'] as int : 0,
    );
  }
}

class ChatMember {
  final String deviceId;
  final String name;
  final String ip;
  final int joinedAt;

  const ChatMember({
    required this.deviceId,
    required this.name,
    required this.ip,
    required this.joinedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'deviceId': deviceId,
      'name': name,
      'ip': ip,
      'joinedAt': joinedAt,
    };
  }

  factory ChatMember.fromJson(Map<String, dynamic> json) {
    return ChatMember(
      deviceId: json['deviceId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      ip: json['ip']?.toString() ?? '',
      joinedAt: json['joinedAt'] is int ? json['joinedAt'] as int : 0,
    );
  }
}

class ChatMessage {
  final String messageId;
  final String roomId;
  final String senderDeviceId;
  final String senderName;
  final String senderIp;
  final String type;
  final String content;
  final int timestamp;
  final int sequence;
  final Map<String, dynamic> extra;

  const ChatMessage({
    required this.messageId,
    required this.roomId,
    required this.senderDeviceId,
    required this.senderName,
    required this.senderIp,
    required this.type,
    required this.content,
    required this.timestamp,
    required this.sequence,
    required this.extra,
  });

  bool get isSystem => type == ChatMessageType.system;

  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'roomId': roomId,
      'senderDeviceId': senderDeviceId,
      'senderName': senderName,
      'senderIp': senderIp,
      'type': type,
      'content': content,
      'timestamp': timestamp,
      'sequence': sequence,
      'extra': extra,
    };
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final extraValue = json['extra'];
    return ChatMessage(
      messageId: json['messageId']?.toString() ?? '',
      roomId: json['roomId']?.toString() ?? '',
      senderDeviceId: json['senderDeviceId']?.toString() ?? '',
      senderName: json['senderName']?.toString() ?? '',
      senderIp: json['senderIp']?.toString() ?? '',
      type: json['type']?.toString() ?? ChatMessageType.text,
      content: json['content']?.toString() ?? '',
      timestamp: json['timestamp'] is int ? json['timestamp'] as int : 0,
      sequence: json['sequence'] is int ? json['sequence'] as int : 0,
      extra: extraValue is Map
          ? Map<String, dynamic>.from(extraValue)
          : <String, dynamic>{},
    );
  }
}

class ChatPacket {
  final String packetId;
  final String type;
  final String networkId;
  final String roomId;
  final String senderDeviceId;
  final String senderName;
  final String senderIp;
  final int timestamp;
  final Map<String, dynamic> payload;

  const ChatPacket({
    required this.packetId,
    required this.type,
    required this.networkId,
    required this.roomId,
    required this.senderDeviceId,
    required this.senderName,
    required this.senderIp,
    required this.timestamp,
    required this.payload,
  });

  String encodeLine() {
    return jsonEncode(toJson()) + '\n';
  }

  Map<String, dynamic> toJson() {
    return {
      'packetId': packetId,
      'type': type,
      'networkId': networkId,
      'roomId': roomId,
      'senderDeviceId': senderDeviceId,
      'senderName': senderName,
      'senderIp': senderIp,
      'timestamp': timestamp,
      'payload': payload,
    };
  }

  factory ChatPacket.fromJson(Map<String, dynamic> json) {
    final payloadValue = json['payload'];
    return ChatPacket(
      packetId: json['packetId']?.toString() ?? '',
      type: json['type']?.toString() ?? '',
      networkId: json['networkId']?.toString() ?? '',
      roomId: json['roomId']?.toString() ?? '',
      senderDeviceId: json['senderDeviceId']?.toString() ?? '',
      senderName: json['senderName']?.toString() ?? '',
      senderIp: json['senderIp']?.toString() ?? '',
      timestamp: json['timestamp'] is int ? json['timestamp'] as int : 0,
      payload: payloadValue is Map
          ? Map<String, dynamic>.from(payloadValue)
          : <String, dynamic>{},
    );
  }
}
