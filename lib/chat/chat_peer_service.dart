import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'chat_history_store.dart';
import 'chat_identity.dart';
import 'chat_models.dart';

class ChatLocalNode {
  final String networkId;
  final String deviceId;
  final String name;
  final String ip;

  const ChatLocalNode({
    required this.networkId,
    required this.deviceId,
    required this.name,
    required this.ip,
  });
}

class ChatSessionState {
  final ChatRoomInfo room;
  final bool isOwner;
  final List<ChatMember> members;

  const ChatSessionState({
    required this.room,
    required this.isOwner,
    required this.members,
  });
}

class _LocalRoom {
  final ChatRoomInfo info;
  final String passwordHash;
  final Map<String, Socket> memberSockets = <String, Socket>{};
  final Map<String, ChatMember> members = <String, ChatMember>{};

  _LocalRoom({
    required this.info,
    required this.passwordHash,
  });
}

/// 基于 VNT 虚拟 IP 的点对点聊天室服务。
class ChatPeerService {
  final ChatHistoryStore historyStore;
  ServerSocket? _server;
  ChatLocalNode? _local;
  Socket? _joinedSocket;
  ChatSessionState? _session;
  int _sequence = 0;

  final Map<String, _LocalRoom> _localRooms = <String, _LocalRoom>{};
  final Map<String, ChatRoomInfo> _remoteRooms = <String, ChatRoomInfo>{};
  final Set<String> _messageIds = <String>{};

  final StreamController<List<ChatRoomInfo>> _roomsController =
      StreamController<List<ChatRoomInfo>>.broadcast();
  final StreamController<ChatMessage> _messageController =
      StreamController<ChatMessage>.broadcast();
  final StreamController<ChatSessionState?> _sessionController =
      StreamController<ChatSessionState?>.broadcast();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  ChatPeerService({required this.historyStore});

  Stream<List<ChatRoomInfo>> get roomsStream => _roomsController.stream;
  Stream<ChatMessage> get messageStream => _messageController.stream;
  Stream<ChatSessionState?> get sessionStream => _sessionController.stream;
  Stream<String> get errorStream => _errorController.stream;
  List<ChatRoomInfo> get rooms => _mergedRooms();
  ChatSessionState? get session => _session;

  Future<void> start(ChatLocalNode local) async {
    _local = local;
    if (_server != null) {
      return;
    }
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, ChatPorts.control, shared: true);
    _server!.listen(_handleSocket, onError: (Object e) {
      _errorController.add('聊天室服务异常：$e');
    });
  }

  Future<void> dispose() async {
    await leaveRoom(deleteHistory: false);
    final server = _server;
    _server = null;
    if (server != null) {
      await server.close();
    }
    await _roomsController.close();
    await _messageController.close();
    await _sessionController.close();
    await _errorController.close();
  }

  Future<void> scanPeers(List<String> peerIps) async {
    final local = _local;
    if (local == null) {
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final expiredKeys = <String>[];
    _remoteRooms.forEach((key, value) {
      if (now - value.updatedAt > 15000) {
        expiredKeys.add(key);
      }
    });
    for (final key in expiredKeys) {
      _remoteRooms.remove(key);
    }

    for (final ip in peerIps) {
      if (ip == local.ip || ip.trim().isEmpty) {
        continue;
      }
      try {
        final socket = await Socket.connect(
          ip,
          ChatPorts.control,
          timeout: const Duration(milliseconds: 700),
        );
        final completer = Completer<void>();
        late StreamSubscription<String> sub;
        sub = socket
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
          try {
            final json = jsonDecode(line);
            if (json is Map) {
              final packet = ChatPacket.fromJson(Map<String, dynamic>.from(json));
              if (packet.type == ChatPacketType.roomList && packet.networkId == local.networkId) {
                final list = packet.payload['rooms'];
                if (list is List) {
                  for (final item in list) {
                    if (item is Map) {
                      final room = ChatRoomInfo.fromJson(Map<String, dynamic>.from(item))
                          .copyWith(ownerIp: ip, updatedAt: now);
                      _remoteRooms[room.roomId] = room;
                    }
                  }
                }
              }
            }
          } catch (_) {
            // 忽略不符合协议的数据。
          }
        }, onDone: () {
          if (!completer.isCompleted) {
            completer.complete();
          }
        }, onError: (_) {
          if (!completer.isCompleted) {
            completer.complete();
          }
        });
        socket.write(_packet(ChatPacketType.hello, '').encodeLine());
        await Future.any(<Future<void>>[
          completer.future,
          Future<void>.delayed(const Duration(milliseconds: 900)),
        ]);
        await sub.cancel();
        socket.destroy();
      } catch (_) {
        // 探测失败表示对方没有开启聊天室或暂时不可达。
      }
    }
    _emitRooms();
  }

  Future<ChatRoomInfo> createRoom(String name, String password) async {
    final local = _requireLocal();
    final roomId = ChatIdentity.newId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final info = ChatRoomInfo(
      roomId: roomId,
      networkId: local.networkId,
      name: name.trim().isEmpty ? '未命名聊天室' : name.trim(),
      ownerDeviceId: local.deviceId,
      ownerName: local.name,
      ownerIp: local.ip,
      hasPassword: password.trim().isNotEmpty,
      memberCount: 1,
      updatedAt: now,
    );
    final room = _LocalRoom(
      info: info,
      passwordHash: ChatIdentity.roomPasswordHash(roomId, password),
    );
    room.members[local.deviceId] = ChatMember(
      deviceId: local.deviceId,
      name: local.name,
      ip: local.ip,
      joinedAt: now,
    );
    _localRooms[roomId] = room;
    _session = ChatSessionState(
      room: info,
      isOwner: true,
      members: room.members.values.toList(),
    );
    _emitRooms();
    _sessionController.add(_session);
    await _addSystemMessage(roomId, '${local.name}（${local.ip}）创建了聊天室');
    return info;
  }

  Future<bool> joinRoom(ChatRoomInfo room, String password) async {
    final local = _requireLocal();
    if (room.ownerIp == local.ip || _localRooms.containsKey(room.roomId)) {
      final localRoom = _localRooms[room.roomId];
      if (localRoom == null) {
        return false;
      }
      _session = ChatSessionState(
        room: localRoom.info,
        isOwner: true,
        members: localRoom.members.values.toList(),
      );
      _sessionController.add(_session);
      return true;
    }
    await leaveRoom(deleteHistory: false);
    try {
      final socket = await Socket.connect(
        room.ownerIp,
        ChatPorts.control,
        timeout: const Duration(seconds: 3),
      );
      _joinedSocket = socket;
      final completer = Completer<bool>();
      socket
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        _handleJoinedLine(line, room, completer);
      }, onDone: () {
        if (_session != null && _session!.room.roomId == room.roomId) {
          _session = null;
          _sessionController.add(null);
        }
      }, onError: (Object e) {
        _errorController.add('聊天室连接异常：$e');
      });
      socket.write(_packet(ChatPacketType.join, room.roomId, <String, dynamic>{
        'passwordHash': ChatIdentity.roomPasswordHash(room.roomId, password),
      }).encodeLine());
      return await Future.any<bool>(<Future<bool>>[
        completer.future,
        Future<bool>.delayed(const Duration(seconds: 4), () => false),
      ]);
    } catch (e) {
      _errorController.add('加入聊天室失败：$e');
      return false;
    }
  }

  Future<void> leaveRoom({bool deleteHistory = true}) async {
    final local = _local;
    final session = _session;
    if (local == null || session == null) {
      return;
    }
    if (!session.isOwner) {
      try {
        _joinedSocket?.write(_packet(ChatPacketType.leave, session.room.roomId).encodeLine());
      } catch (_) {}
      _joinedSocket?.destroy();
      _joinedSocket = null;
    } else {
      final room = _localRooms.remove(session.room.roomId);
      if (room != null) {
        for (final socket in room.memberSockets.values) {
          socket.destroy();
        }
      }
    }
    if (deleteHistory) {
      await historyStore.deleteRoom(local.networkId, session.room.roomId);
    }
    _session = null;
    _sessionController.add(null);
    _emitRooms();
  }

  Future<void> sendText(String text) async {
    final content = text.trim();
    if (content.isEmpty) {
      return;
    }
    await sendMessage(ChatMessageType.text, content, <String, dynamic>{});
  }

  Future<void> sendMessage(
    String type,
    String content,
    Map<String, dynamic> extra,
  ) async {
    final local = _requireLocal();
    final session = _session;
    if (session == null) {
      throw StateError('未加入聊天室');
    }
    final message = ChatMessage(
      messageId: ChatIdentity.newId(),
      roomId: session.room.roomId,
      senderDeviceId: local.deviceId,
      senderName: local.name,
      senderIp: local.ip,
      type: type,
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      sequence: ++_sequence,
      extra: extra,
    );
    final packet = _packet(ChatPacketType.message, session.room.roomId, <String, dynamic>{
      'message': message.toJson(),
    });
    if (session.isOwner) {
      await _acceptMessage(message, broadcast: true);
    } else {
      _joinedSocket?.write(packet.encodeLine());
    }
  }

  Future<void> sendCallPacket(String packetType, Map<String, dynamic> payload) async {
    final session = _session;
    if (session == null) {
      return;
    }
    final packet = _packet(packetType, session.room.roomId, payload);
    if (session.isOwner) {
      _broadcast(session.room.roomId, packet);
    } else {
      _joinedSocket?.write(packet.encodeLine());
    }
  }

  Future<List<ChatMessage>> loadCurrentMessages() async {
    final local = _local;
    final session = _session;
    if (local == null || session == null) {
      return <ChatMessage>[];
    }
    final messages = await historyStore.loadMessages(local.networkId, session.room.roomId);
    for (final message in messages) {
      _messageIds.add(message.messageId);
    }
    return messages;
  }

  void _handleSocket(Socket socket) {
    socket
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      try {
        final json = jsonDecode(line);
        if (json is! Map) {
          return;
        }
        final packet = ChatPacket.fromJson(Map<String, dynamic>.from(json));
        _handleIncomingPacket(socket, packet);
      } catch (_) {
        // 忽略不符合协议的数据。
      }
    }, onDone: () {
      _removeSocket(socket);
    }, onError: (_) {
      _removeSocket(socket);
    });
  }

  void _handleIncomingPacket(Socket socket, ChatPacket packet) {
    final local = _local;
    if (local == null || packet.networkId != local.networkId) {
      return;
    }
    if (packet.type == ChatPacketType.hello) {
      final rooms = _localRooms.values.map((room) {
        return room.info.copyWith(
          memberCount: room.members.length,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        ).toJson();
      }).toList();
      socket.write(_packet(ChatPacketType.roomList, '', <String, dynamic>{
        'rooms': rooms,
      }).encodeLine());
      Future<void>.delayed(const Duration(milliseconds: 80), socket.destroy);
      return;
    }
    if (packet.type == ChatPacketType.join) {
      _handleJoin(socket, packet);
      return;
    }
    if (packet.type == ChatPacketType.leave) {
      _removeSocket(socket);
      return;
    }
    if (packet.type == ChatPacketType.message) {
      final messageJson = packet.payload['message'];
      if (messageJson is Map) {
        _acceptMessage(ChatMessage.fromJson(Map<String, dynamic>.from(messageJson)), broadcast: true);
      }
      return;
    }
    if (packet.type == ChatPacketType.callInvite ||
        packet.type == ChatPacketType.callSignal ||
        packet.type == ChatPacketType.screenShare ||
        packet.type == ChatPacketType.remoteControl) {
      _broadcast(packet.roomId, packet);
    }
  }

  void _handleJoin(Socket socket, ChatPacket packet) {
    final local = _local;
    final room = _localRooms[packet.roomId];
    if (local == null || room == null) {
      socket.write(_packet(ChatPacketType.joinResult, packet.roomId, <String, dynamic>{
        'ok': false,
        'message': '聊天室不存在',
      }).encodeLine());
      return;
    }
    final hash = packet.payload['passwordHash']?.toString() ?? '';
    if (room.passwordHash.isNotEmpty && room.passwordHash != hash) {
      socket.write(_packet(ChatPacketType.joinResult, packet.roomId, <String, dynamic>{
        'ok': false,
        'message': '房间密码错误',
      }).encodeLine());
      return;
    }
    final member = ChatMember(
      deviceId: packet.senderDeviceId,
      name: packet.senderName,
      ip: packet.senderIp,
      joinedAt: DateTime.now().millisecondsSinceEpoch,
    );
    room.memberSockets[member.deviceId] = socket;
    room.members[member.deviceId] = member;
    socket.write(_packet(ChatPacketType.joinResult, packet.roomId, <String, dynamic>{
      'ok': true,
      'room': room.info.copyWith(memberCount: room.members.length).toJson(),
      'members': room.members.values.map((item) => item.toJson()).toList(),
    }).encodeLine());
    _sendHistory(socket, packet.roomId);
    _addSystemMessage(packet.roomId, '${member.name}（${member.ip}）加入了聊天室');
    _session = ChatSessionState(
      room: room.info.copyWith(memberCount: room.members.length),
      isOwner: true,
      members: room.members.values.toList(),
    );
    _sessionController.add(_session);
    _emitRooms();
  }

  void _handleJoinedLine(String line, ChatRoomInfo room, Completer<bool> completer) {
    try {
      final json = jsonDecode(line);
      if (json is! Map) {
        return;
      }
      final packet = ChatPacket.fromJson(Map<String, dynamic>.from(json));
      if (packet.type == ChatPacketType.joinResult) {
        final ok = packet.payload['ok'] == true;
        if (ok) {
          final roomJson = packet.payload['room'];
          final membersJson = packet.payload['members'];
          final joinedRoom = roomJson is Map
              ? ChatRoomInfo.fromJson(Map<String, dynamic>.from(roomJson))
              : room;
          final members = <ChatMember>[];
          if (membersJson is List) {
            for (final item in membersJson) {
              if (item is Map) {
                members.add(ChatMember.fromJson(Map<String, dynamic>.from(item)));
              }
            }
          }
          _session = ChatSessionState(
            room: joinedRoom.copyWith(ownerIp: room.ownerIp),
            isOwner: false,
            members: members,
          );
          _sessionController.add(_session);
        } else {
          _errorController.add(packet.payload['message']?.toString() ?? '加入聊天室失败');
          _joinedSocket?.destroy();
          _joinedSocket = null;
        }
        if (!completer.isCompleted) {
          completer.complete(ok);
        }
        return;
      }
      if (packet.type == ChatPacketType.message) {
        final messageJson = packet.payload['message'];
        if (messageJson is Map) {
          _acceptMessage(ChatMessage.fromJson(Map<String, dynamic>.from(messageJson)), broadcast: false);
        }
        return;
      }
      if (packet.type == ChatPacketType.historyChunk) {
        final messagesJson = packet.payload['messages'];
        if (messagesJson is List) {
          for (final item in messagesJson) {
            if (item is Map) {
              _acceptMessage(ChatMessage.fromJson(Map<String, dynamic>.from(item)), broadcast: false);
            }
          }
        }
      }
    } catch (_) {
      // 忽略不符合协议的数据。
    }
  }

  Future<void> _acceptMessage(ChatMessage message, {required bool broadcast}) async {
    final local = _local;
    if (local == null || _messageIds.contains(message.messageId)) {
      return;
    }
    _messageIds.add(message.messageId);
    await historyStore.appendMessage(local.networkId, message);
    _messageController.add(message);
    if (broadcast) {
      _broadcast(message.roomId, _packet(ChatPacketType.message, message.roomId, <String, dynamic>{
        'message': message.toJson(),
      }));
    }
  }

  Future<void> _addSystemMessage(String roomId, String content) async {
    final local = _requireLocal();
    final message = ChatMessage(
      messageId: ChatIdentity.newId(),
      roomId: roomId,
      senderDeviceId: local.deviceId,
      senderName: '系统',
      senderIp: local.ip,
      type: ChatMessageType.system,
      content: content,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      sequence: ++_sequence,
      extra: <String, dynamic>{},
    );
    await _acceptMessage(message, broadcast: true);
  }

  void _broadcast(String roomId, ChatPacket packet) {
    final room = _localRooms[roomId];
    if (room == null) {
      return;
    }
    final line = packet.encodeLine();
    final failed = <String>[];
    room.memberSockets.forEach((deviceId, socket) {
      try {
        socket.write(line);
      } catch (_) {
        failed.add(deviceId);
      }
    });
    for (final id in failed) {
      room.memberSockets.remove(id);
      room.members.remove(id);
    }
  }

  Future<void> _sendHistory(Socket socket, String roomId) async {
    final local = _local;
    if (local == null) {
      return;
    }
    final messages = await historyStore.loadMessages(local.networkId, roomId);
    const size = 40;
    for (var i = 0; i < messages.length; i += size) {
      final end = i + size > messages.length ? messages.length : i + size;
      socket.write(_packet(ChatPacketType.historyChunk, roomId, <String, dynamic>{
        'messages': messages.sublist(i, end).map((item) => item.toJson()).toList(),
        'done': end >= messages.length,
      }).encodeLine());
    }
  }

  void _removeSocket(Socket socket) {
    String? removedName;
    String? removedIp;
    String? roomId;
    for (final room in _localRooms.values) {
      String? removedId;
      room.memberSockets.forEach((id, item) {
        if (identical(item, socket)) {
          removedId = id;
        }
      });
      if (removedId != null) {
        final member = room.members.remove(removedId);
        room.memberSockets.remove(removedId);
        removedName = member?.name;
        removedIp = member?.ip;
        roomId = room.info.roomId;
        break;
      }
    }
    if (roomId != null && removedName != null && removedIp != null) {
      _addSystemMessage(roomId!, '$removedName（$removedIp）离开了聊天室');
    }
    socket.destroy();
    _emitRooms();
  }

  ChatPacket _packet(String type, String roomId, [Map<String, dynamic>? payload]) {
    final local = _requireLocal();
    return ChatPacket(
      packetId: ChatIdentity.newId(),
      type: type,
      networkId: local.networkId,
      roomId: roomId,
      senderDeviceId: local.deviceId,
      senderName: local.name,
      senderIp: local.ip,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      payload: payload ?? <String, dynamic>{},
    );
  }

  ChatLocalNode _requireLocal() {
    final local = _local;
    if (local == null) {
      throw StateError('聊天室服务未启动');
    }
    return local;
  }

  List<ChatRoomInfo> _mergedRooms() {
    final list = <ChatRoomInfo>[];
    list.addAll(_localRooms.values.map((room) {
      return room.info.copyWith(
        memberCount: room.members.length,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }));
    list.addAll(_remoteRooms.values);
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  void _emitRooms() {
    _roomsController.add(_mergedRooms());
  }
}
