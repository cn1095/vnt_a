import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vnt_app/chat/chat_file_server.dart';
import 'package:vnt_app/chat/chat_history_store.dart';
import 'package:vnt_app/chat/chat_identity.dart';
import 'package:vnt_app/chat/chat_models.dart';
import 'package:vnt_app/chat/chat_peer_service.dart';
import 'package:vnt_app/chat/chat_platform_permissions.dart';
import 'package:vnt_app/chat/chat_runtime_registry.dart';
import 'package:vnt_app/chat/chat_voice_recorder.dart';
import 'package:vnt_app/network_config.dart';
import 'package:vnt_app/src/rust/api/vnt_api.dart';
import 'package:vnt_app/theme/app_theme.dart';
import 'package:vnt_app/utils/responsive_utils.dart';
import 'package:vnt_app/utils/toast_utils.dart';

class ChatTab extends StatefulWidget {
  final NetworkConfig? config;
  final String? currentIp;
  final List<RustPeerClientInfo> devices;
  final bool isDark;
  final bool isWideScreen;

  const ChatTab({
    super.key,
    required this.config,
    required this.currentIp,
    required this.devices,
    required this.isDark,
    required this.isWideScreen,
  });

  @override
  State<ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<ChatTab> with AutomaticKeepAliveClientMixin {
  final ChatHistoryStore _historyStore = ChatHistoryStore();
  final ChatFileServer _fileServer = ChatFileServer();
  late final ChatPeerService _service;
  final List<ChatRoomInfo> _rooms = <ChatRoomInfo>[];
  final List<ChatMessage> _messages = <ChatMessage>[];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<List<ChatRoomInfo>>? _roomsSub;
  StreamSubscription<ChatMessage>? _messageSub;
  StreamSubscription<ChatSessionState?>? _sessionSub;
  StreamSubscription<String>? _errorSub;
  Timer? _scanTimer;
  bool _started = false;
  bool _loading = false;
  bool _emojiVisible = false;
  bool _voicePressed = false;
  DateTime? _voiceStartAt;
  String? _playingVoiceMessageId;
  ChatSessionState? _session;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _service = ChatPeerService(historyStore: _historyStore);
    ChatRuntimeRegistry.register(this, _stopRuntimeForNetworkShutdown);
    _bindService();
    _startIfReady();
  }

  @override
  void didUpdateWidget(ChatTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config?.itemKey != widget.config?.itemKey) {
      unawaited(_service.leaveRoom(deleteHistory: false));
      _started = false;
      _rooms.clear();
      _messages.clear();
      _session = null;
      _startIfReady();
      return;
    }
    if (!_started &&
        widget.currentIp != null &&
        widget.currentIp!.isNotEmpty) {
      _startIfReady();
    }
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    ChatRuntimeRegistry.unregister(this);
    _roomsSub?.cancel();
    _messageSub?.cancel();
    _sessionSub?.cancel();
    _errorSub?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    unawaited(_fileServer.stop());
    unawaited(_service.dispose());
    super.dispose();
  }

  Future<void> _stopRuntimeForNetworkShutdown() async {
    _scanTimer?.cancel();
    _scanTimer = null;
    _started = false;
    _rooms.clear();
    _messages.clear();
    _session = null;
    _emojiVisible = false;
    _voicePressed = false;
    _voiceStartAt = null;
    _playingVoiceMessageId = null;
    await _fileServer.stop();
    await _service.stop();
    if (mounted) {
      setState(() {});
    }
  }

  void _bindService() {
    _roomsSub = _service.roomsStream.listen((rooms) {
      if (!mounted) {
        return;
      }
      setState(() {
        _rooms
          ..clear()
          ..addAll(rooms);
      });
    });
    _messageSub = _service.messageStream.listen((message) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (!_messages.any((item) => item.messageId == message.messageId)) {
          _messages.add(message);
          _messages.sort((a, b) {
            final timeResult = a.timestamp.compareTo(b.timestamp);
            if (timeResult != 0) {
              return timeResult;
            }
            return a.sequence.compareTo(b.sequence);
          });
        }
      });
      _scrollToBottom();
    });
    _sessionSub = _service.sessionStream.listen((session) async {
      if (!mounted) {
        return;
      }
      setState(() {
        _session = session;
        _messages.clear();
      });
      if (session != null) {
        final messages = await _service.loadCurrentMessages();
        if (mounted) {
          setState(() {
            _messages
              ..clear()
              ..addAll(messages);
          });
          _scrollToBottom();
        }
      }
    });
    _errorSub = _service.errorStream.listen((message) {
      if (mounted) {
        showTopToast(context, message, isSuccess: false);
      }
    });
  }

  Future<void> _startIfReady() async {
    final config = widget.config;
    final currentIp = widget.currentIp;
    if (_started || config == null || currentIp == null || currentIp.isEmpty) {
      return;
    }
    _started = true;
    await ChatRuntimeRegistry.disposeAll(except: this);
    final local = ChatLocalNode(
      networkId: ChatIdentity.networkId(config),
      deviceId: config.deviceID,
      name: config.deviceName.isEmpty ? '当前设备' : config.deviceName,
      ip: currentIp,
    );
    try {
      await _service.start(local);
      await _scanRooms();
      _scanTimer?.cancel();
      _scanTimer = Timer.periodic(const Duration(seconds: 6), (_) {
        _scanRooms();
      });
    } catch (e) {
      if (mounted) {
        showTopToast(context, '聊天室服务启动失败：$e', isSuccess: false);
      }
    }
  }

  Future<void> _scanRooms() async {
    final ips = widget.devices
        .where((device) => device.status.trim().toLowerCase() == 'online')
        .map((device) => device.virtualIp)
        .toList();
    await _service.scanPeers(ips);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.config == null || widget.currentIp == null) {
      return _buildEmpty('未连接组网，无法使用聊天室');
    }
    if (_session != null) {
      return _buildChatRoom();
    }
    return _buildRoomList();
  }

  Widget _buildRoomList() {
    final isDark = widget.isDark;
    final primaryColor = Theme.of(context).primaryColor;
    return RefreshIndicator(
      color: primaryColor,
      onRefresh: _scanRooms,
      child: ListView(
        padding: EdgeInsets.all(
          widget.isWideScreen ? context.spacingXLarge : context.spacingMedium,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '在线聊天室',
                  style: TextStyle(
                    fontSize: context.fontLarge,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                onPressed: _scanRooms,
                icon: const Icon(Icons.refresh),
              ),
              ElevatedButton.icon(
                onPressed: _showCreateRoomDialog,
                icon: const Icon(Icons.add),
                label: const Text('创建'),
              ),
            ],
          ),
          SizedBox(height: context.spacingMedium),
          if (_loading) const LinearProgressIndicator(),
          if (_loading) SizedBox(height: context.spacingMedium),
          if (_rooms.isEmpty)
            _buildEmpty('当前组网内暂无在线聊天室')
          else
            ..._rooms.map((room) => Padding(
                  padding: EdgeInsets.only(bottom: context.cardSpacing),
                  child: _buildRoomCard(room),
                )),
        ],
      ),
    );
  }

  Widget _buildRoomCard(ChatRoomInfo room) {
    final isDark = widget.isDark;
    final primaryColor = Theme.of(context).primaryColor;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground,
        borderRadius: BorderRadius.circular(context.cardRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        leading: Container(
          width: context.listItemIconContainerSize,
          height: context.listItemIconContainerSize,
          decoration: BoxDecoration(
            color: primaryColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(context.cardRadius),
          ),
          child: Icon(Icons.forum_outlined, color: primaryColor, size: context.iconMedium),
        ),
        title: Text(
          room.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
          ),
        ),
        subtitle: Text(
          '${room.ownerName}（${room.ownerIp}） · ${room.memberCount} 人在线',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (room.hasPassword)
              Icon(Icons.lock_outline, size: context.iconSmall, color: AppTheme.warningColor),
            IconButton(
              tooltip: '加入',
              onPressed: () => _joinRoom(room),
              icon: const Icon(Icons.login),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatRoom() {
    final session = _session!;
    final isDark = widget.isDark;
    return Column(
      children: [
        _buildChatHeader(session),
        if (_loading) const LinearProgressIndicator(),
        if (_fileServer.isRunning) _buildSharingBar(),
        Expanded(
          child: _messages.isEmpty
              ? _buildEmpty('还没有聊天消息')
              : ListView.builder(
                  controller: _scrollController,
                  padding: EdgeInsets.all(
                    widget.isWideScreen ? context.spacingXLarge : context.spacingMedium,
                  ),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    return _buildMessageBubble(_messages[index]);
                  },
                ),
        ),
        Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
            border: Border(
              top: BorderSide(
                color: isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
              ),
            ),
          ),
          padding: EdgeInsets.all(context.spacingSmall),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                IconButton(
                  tooltip: '共享文件',
                  onPressed: _showShareMenu,
                  icon: const Icon(Icons.attach_file),
                ),
                IconButton(
                  tooltip: '表情',
                  onPressed: _toggleEmojiPanel,
                  icon: Icon(_emojiVisible ? Icons.keyboard_alt_outlined : Icons.emoji_emotions_outlined),
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendText(),
                    decoration: const InputDecoration(
                      hintText: '输入消息',
                    ),
                  ),
                ),
                SizedBox(width: context.spacingXSmall),
                IconButton(
                  tooltip: '发送',
                  onPressed: _sendText,
                  icon: const Icon(Icons.send),
                ),
                SizedBox(width: context.spacingXSmall),
                GestureDetector(
                  onLongPressStart: (_) => _startVoiceHold(),
                  onLongPressEnd: (_) => _finishVoiceHold(cancel: false),
                  onLongPressCancel: () => _finishVoiceHold(cancel: true),
                  child: Container(
                    height: context.w(40),
                    width: context.w(40),
                    decoration: BoxDecoration(
                      color: _voicePressed
                          ? Theme.of(context).primaryColor.withOpacity(0.22)
                          : Theme.of(context).primaryColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(context.cardRadius),
                    ),
                    child: Icon(
                      Icons.keyboard_voice_outlined,
                      color: Theme.of(context).primaryColor,
                      size: context.iconSmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_emojiVisible) _buildEmojiPanel(),
      ],
    );
  }

  Widget _buildChatHeader(ChatSessionState session) {
    final isDark = widget.isDark;
    final primaryColor = Theme.of(context).primaryColor;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.isWideScreen ? context.spacingXLarge : context.spacingMedium,
        vertical: context.spacingSmall,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        border: Border(
          bottom: BorderSide(
            color: isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回聊天室列表',
            onPressed: () => _service.leaveRoom(deleteHistory: true),
            icon: const Icon(Icons.arrow_back),
          ),
          SizedBox(width: context.spacingXSmall),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.room.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: context.fontMedium,
                    fontWeight: FontWeight.w700,
                    color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                  ),
                ),
                Text(
                  session.isOwner ? '本机房主 · ${session.members.length} 人' : '已加入 · ${session.members.length} 人',
                  style: TextStyle(
                    fontSize: context.fontSmall,
                    color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '成员',
            onPressed: _showMembers,
            icon: Icon(Icons.people_outline, color: primaryColor),
          ),
          IconButton(
            tooltip: '语音',
            onPressed: () => _sendCallAction('voice'),
            icon: const Icon(Icons.mic_none),
          ),
          IconButton(
            tooltip: '视频',
            onPressed: () => _sendCallAction('video'),
            icon: const Icon(Icons.videocam_outlined),
          ),
          IconButton(
            tooltip: '屏幕共享',
            onPressed: _sendScreenShareAction,
            icon: const Icon(Icons.screen_share_outlined),
          ),
          IconButton(
            tooltip: '远程协助',
            onPressed: _sendRemoteAssistAction,
            icon: const Icon(Icons.settings_remote_outlined),
          ),
        ],
      ),
    );
  }

  Widget _buildSharingBar() {
    final primaryColor = Theme.of(context).primaryColor;
    final count = _fileServer.entries.length;
    return Material(
      color: primaryColor.withOpacity(0.12),
      child: InkWell(
        onTap: () async {
          await _fileServer.stop();
          if (mounted) {
            setState(() {});
          }
        },
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: context.spacingMedium,
            vertical: context.spacingXSmall,
          ),
          child: Row(
            children: [
              Icon(Icons.cloud_upload_outlined, color: primaryColor, size: context.iconSmall),
              SizedBox(width: context.spacingXSmall),
              Expanded(
                child: Text(
                  '正在共享 $count 个文件或文件夹（点击关闭共享）',
                  style: TextStyle(
                    color: primaryColor,
                    fontSize: context.fontSmall,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final isDark = widget.isDark;
    final localIp = widget.currentIp ?? '';
    final isMe = message.senderIp == localIp && !message.isSystem;
    if (message.isSystem) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: context.spacingXSmall),
        child: Center(
          child: Text(
            message.content,
            style: TextStyle(
              fontSize: context.fontSmall,
              color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
            ),
          ),
        ),
      );
    }
    final background = isMe
        ? Theme.of(context).primaryColor.withOpacity(0.18)
        : (isDark ? AppTheme.darkCardBackground : AppTheme.lightCardBackground);
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        margin: EdgeInsets.only(bottom: context.spacingSmall),
        padding: EdgeInsets.all(context.spacingSmall),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(context.cardRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${message.senderName}（${message.senderIp}）',
              style: TextStyle(
                fontSize: context.fontSmall,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
            SizedBox(height: context.spacingXXSmall),
            _buildMessageContent(message),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageContent(ChatMessage message) {
    if (message.type == ChatMessageType.voice) {
      return _buildVoiceMessage(message);
    }
    if (message.type == ChatMessageType.image) {
      return _buildImageMessage(message);
    }
    if (message.type == ChatMessageType.video) {
      return _buildVideoMessage(message);
    }
    if (message.type == ChatMessageType.file ||
        message.type == ChatMessageType.image) {
      return _buildFileMessage(message);
    }
    if (message.type == ChatMessageType.call) {
      return Text(message.content);
    }
    return SelectableText(
      message.content,
      style: TextStyle(
        fontSize: context.fontBody,
        color: widget.isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
      ),
    );
  }

  Widget _buildVideoMessage(ChatMessage message) {
    final name = message.extra['name']?.toString() ?? message.content;
    final size = message.extra['size'] is int ? message.extra['size'] as int : 0;
    final url = message.extra['url']?.toString() ?? '';
    return Container(
      constraints: BoxConstraints(maxWidth: context.w(260)),
      padding: EdgeInsets.all(context.spacingSmall),
      decoration: BoxDecoration(
        color: widget.isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        borderRadius: BorderRadius.circular(context.cardRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => _openVideoMessage(url),
            borderRadius: BorderRadius.circular(context.cardRadius),
            child: Container(
              height: context.w(130),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(context.cardRadius),
              ),
              child: Icon(
                Icons.play_circle_fill,
                color: Colors.white,
                size: context.iconXLarge,
              ),
            ),
          ),
          SizedBox(height: context.spacingXSmall),
          Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: context.fontBody,
              fontWeight: FontWeight.w600,
              color: widget.isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
            ),
          ),
          SizedBox(height: context.spacingXXSmall),
          Row(
            children: [
              Expanded(
                child: Text(
                  size > 0 ? _formatSize(size) : '视频文件',
                  style: TextStyle(
                    fontSize: context.fontSmall,
                    color: widget.isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
                ),
              ),
              IconButton(
                tooltip: '打开',
                onPressed: () => _openVideoMessage(url),
                icon: Icon(Icons.open_in_new, size: context.iconSmall),
              ),
              IconButton(
                tooltip: '下载',
                onPressed: () => _downloadSharedFile(message),
                icon: Icon(Icons.download_outlined, size: context.iconSmall),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildImageMessage(ChatMessage message) {
    final name = message.extra['name']?.toString() ?? message.content;
    final url = message.extra['url']?.toString() ?? '';
    if (url.isEmpty) {
      return _buildFileMessage(message);
    }
    return InkWell(
      onTap: () => _showImagePreview(name, url),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(context.cardRadius),
            child: Image.network(
              url,
              width: context.w(220),
              height: context.w(160),
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: context.w(220),
                  height: context.w(120),
                  alignment: Alignment.center,
                  color: widget.isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.broken_image_outlined),
                      SizedBox(height: context.spacingXSmall),
                      Text(
                        '图片不可预览',
                        style: TextStyle(fontSize: context.fontSmall),
                      ),
                    ],
                  ),
                );
              },
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) {
                  return child;
                }
                return Container(
                  width: context.w(220),
                  height: context.w(120),
                  alignment: Alignment.center,
                  color: widget.isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
                  child: const CircularProgressIndicator(),
                );
              },
            ),
          ),
          SizedBox(height: context.spacingXSmall),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: context.fontSmall),
                ),
              ),
              SizedBox(width: context.spacingXSmall),
              InkWell(
                onTap: () => _downloadSharedFile(message),
                child: Icon(Icons.download_outlined, size: context.iconSmall),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVoiceMessage(ChatMessage message) {
    final durationMs = message.extra['durationMs'] is int
        ? message.extra['durationMs'] as int
        : 0;
    final seconds = (durationMs / 1000).ceil().clamp(1, 600);
    final url = message.extra['url']?.toString() ?? '';
    final isPlaying = _playingVoiceMessageId == message.messageId;
    return InkWell(
      onTap: () => _playVoiceMessage(message),
      child: Container(
        constraints: BoxConstraints(minWidth: context.w(120)),
        padding: EdgeInsets.symmetric(
          horizontal: context.spacingSmall,
          vertical: context.spacingXSmall,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).primaryColor.withOpacity(0.12),
          borderRadius: BorderRadius.circular(context.cardRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isPlaying ? Icons.stop_circle_outlined : Icons.play_circle_outline,
              color: Theme.of(context).primaryColor,
            ),
            SizedBox(width: context.spacingXSmall),
            Icon(
              Icons.graphic_eq,
              color: Theme.of(context).primaryColor,
              size: context.iconSmall,
            ),
            SizedBox(width: context.spacingXSmall),
            Text(
              '$seconds"',
              style: TextStyle(
                fontSize: context.fontBody,
                fontWeight: FontWeight.w600,
                color: widget.isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
              ),
            ),
            if (url.isEmpty) ...[
              SizedBox(width: context.spacingXSmall),
              Text(
                '未录音',
                style: TextStyle(
                  fontSize: context.fontSmall,
                  color: widget.isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _playVoiceMessage(ChatMessage message) async {
    final url = message.extra['url']?.toString() ?? '';
    if (_playingVoiceMessageId == message.messageId) {
      await ChatVoiceRecorder.stopPlay();
      if (mounted) {
        setState(() {
          _playingVoiceMessageId = null;
        });
      }
      return;
    }
    if (url.isEmpty) {
      showTopToast(context, '该语音没有可播放录音文件', isSuccess: false);
      return;
    }
    final started = await ChatVoiceRecorder.play(url);
    if (!mounted) {
      return;
    }
    if (started) {
      setState(() {
        _playingVoiceMessageId = message.messageId;
      });
      Future<void>.delayed(const Duration(seconds: 1), () {
        final durationMs = message.extra['durationMs'] is int
            ? message.extra['durationMs'] as int
            : 0;
        Future<void>.delayed(Duration(milliseconds: durationMs), () {
          if (mounted && _playingVoiceMessageId == message.messageId) {
            setState(() {
              _playingVoiceMessageId = null;
            });
          }
        });
      });
    } else {
      showTopToast(context, '当前平台暂不支持直接播放语音，请在 Android 端使用', isSuccess: false);
    }
  }

  Widget _buildEmojiPanel() {
    final groups = _emojiGroups();
    final isDark = widget.isDark;
    return Container(
      height: context.w(230),
      padding: EdgeInsets.all(context.spacingSmall),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : AppTheme.lightSurface,
        border: Border(
          top: BorderSide(
            color: isDark ? AppTheme.darkDivider : AppTheme.lightDivider,
          ),
        ),
      ),
      child: DefaultTabController(
        length: groups.length,
        child: Column(
          children: [
            SizedBox(
              height: context.w(34),
              child: TabBar(
                isScrollable: true,
                indicatorColor: Theme.of(context).primaryColor,
                labelColor: Theme.of(context).primaryColor,
                unselectedLabelColor: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                tabs: groups.map((group) => Tab(text: group.title)).toList(),
              ),
            ),
            SizedBox(height: context.spacingXSmall),
            Expanded(
              child: TabBarView(
                children: groups.map((group) {
                  return GridView.builder(
                    itemCount: group.emojis.length,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 8,
                      mainAxisSpacing: 6,
                      crossAxisSpacing: 6,
                    ),
                    itemBuilder: (context, index) {
                      final emoji = group.emojis[index];
                      return InkWell(
                        borderRadius: BorderRadius.circular(context.cardRadius),
                        onTap: () => _insertEmoji(emoji),
                        child: Center(
                          child: Text(
                            emoji,
                            style: TextStyle(fontSize: context.sp(22)),
                          ),
                        ),
                      );
                    },
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<_EmojiGroup> _emojiGroups() {
    return const <_EmojiGroup>[
      _EmojiGroup('常用', <String>[
        '😀', '😁', '😂', '🤣', '😊', '😍', '😘', '😎', '😭', '😡', '👍', '👎',
        '👏', '🙏', '💪', '🎉', '❤️', '🔥', '⭐', '✅', '❌', '⚠️', '📎', '💯',
      ]),
      _EmojiGroup('笑脸', <String>[
        '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃', '😉', '😊',
        '😇', '🥰', '😍', '🤩', '😘', '😗', '☺️', '😚', '😙', '🥲', '😋', '😛',
        '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🫢', '🫣', '🤫', '🤔', '🫡', '🤐',
        '🤨', '😐', '😑', '😶', '🫥', '😶‍🌫️', '😏', '😒', '🙄', '😬', '😮‍💨', '🤥',
        '😌', '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮', '🤧', '🥵',
        '🥶', '🥴', '😵', '😵‍💫', '🤯', '🤠', '🥳', '🥸', '😎', '🤓', '🧐', '😕',
        '🫤', '😟', '🙁', '☹️', '😮', '😯', '😲', '😳', '🥺', '🥹', '😦', '😧',
        '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞', '😓', '😩', '😫',
        '🥱', '😤', '😡', '😠', '🤬', '😈', '👿', '💀', '☠️', '💩', '🤡', '👻',
      ]),
      _EmojiGroup('手势', <String>[
        '👋', '🤚', '🖐️', '✋', '🖖', '👌', '🤌', '🤏', '✌️', '🤞', '🫰', '🤟',
        '🤘', '🤙', '👈', '👉', '👆', '🖕', '👇', '☝️', '🫵', '👍', '👎', '✊',
        '👊', '🤛', '🤜', '👏', '🙌', '🫶', '👐', '🤲', '🤝', '🙏', '✍️', '💅',
        '🤳', '💪', '🦾', '🦿', '🦵', '🦶', '👂', '🦻', '👃', '🧠', '🫀', '🫁',
        '🦷', '🦴', '👀', '👁️', '👅', '👄', '🫦',
      ]),
      _EmojiGroup('人物', <String>[
        '👶', '🧒', '👦', '👧', '🧑', '👱', '👨', '🧔', '👩', '🧓', '👴', '👵',
        '🙍', '🙎', '🙅', '🙆', '💁', '🙋', '🧏', '🙇', '🤦', '🤷', '👮', '🕵️',
        '💂', '🥷', '👷', '🫅', '🤴', '👸', '👳', '👲', '🧕', '🤵', '👰', '🤰',
        '🫃', '🫄', '🤱', '👼', '🎅', '🤶', '🦸', '🦹', '🧙', '🧚', '🧛', '🧜',
        '🧝', '🧞', '🧟', '💆', '💇', '🚶', '🧍', '🧎', '🏃', '💃', '🕺', '🕴️',
        '👯', '🧖', '🧗', '🤺', '🏇', '⛷️', '🏂', '🏌️', '🏄', '🚣', '🏊', '⛹️',
        '🏋️', '🚴', '🚵', '🤸', '🤼', '🤽', '🤾', '🤹', '🧘',
      ]),
      _EmojiGroup('动物', <String>[
        '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐻‍❄️', '🐨', '🐯', '🦁',
        '🐮', '🐷', '🐽', '🐸', '🐵', '🙈', '🙉', '🙊', '🐒', '🐔', '🐧', '🐦',
        '🐤', '🐣', '🐥', '🦆', '🦅', '🦉', '🦇', '🐺', '🐗', '🐴', '🦄', '🐝',
        '🪱', '🐛', '🦋', '🐌', '🐞', '🐜', '🪰', '🪲', '🪳', '🦟', '🦗', '🕷️',
        '🦂', '🐢', '🐍', '🦎', '🦖', '🦕', '🐙', '🦑', '🦐', '🦞', '🦀', '🐡',
        '🐠', '🐟', '🐬', '🐳', '🐋', '🦈', '🐊', '🐅', '🐆', '🦓', '🦍', '🦧',
        '🦣', '🐘', '🦛', '🦏', '🐪', '🐫', '🦒', '🦘', '🦬', '🐃', '🐂', '🐄',
      ]),
      _EmojiGroup('食物', <String>[
        '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐', '🍈', '🍒',
        '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑', '🥦', '🥬', '🥒', '🌶️',
        '🫑', '🌽', '🥕', '🫒', '🧄', '🧅', '🥔', '🍠', '🥐', '🥯', '🍞', '🥖',
        '🥨', '🧀', '🥚', '🍳', '🧈', '🥞', '🧇', '🥓', '🥩', '🍗', '🍖', '🦴',
        '🌭', '🍔', '🍟', '🍕', '🫓', '🥪', '🥙', '🧆', '🌮', '🌯', '🫔', '🥗',
        '🥘', '🫕', '🥫', '🍝', '🍜', '🍲', '🍛', '🍣', '🍱', '🥟', '🦪', '🍤',
        '🍙', '🍚', '🍘', '🍥', '🥠', '🥮', '🍢', '🍡', '🍧', '🍨', '🍦', '🥧',
        '🧁', '🍰', '🎂', '🍮', '🍭', '🍬', '🍫', '🍿', '🍩', '🍪', '🌰', '🥜',
      ]),
      _EmojiGroup('活动', <String>[
        '⚽', '🏀', '🏈', '⚾', '🥎', '🎾', '🏐', '🏉', '🥏', '🎱', '🪀', '🏓',
        '🏸', '🏒', '🏑', '🥍', '🏏', '🪃', '🥅', '⛳', '🪁', '🏹', '🎣', '🤿',
        '🥊', '🥋', '🎽', '🛹', '🛼', '🛷', '⛸️', '🥌', '🎿', '⛷️', '🏂', '🪂',
        '🏋️', '🤼', '🤸', '⛹️', '🤺', '🤾', '🏌️', '🏇', '🧘', '🏄', '🏊', '🤽',
        '🚣', '🧗', '🚵', '🚴', '🏆', '🥇', '🥈', '🥉', '🏅', '🎖️', '🏵️', '🎗️',
        '🎫', '🎟️', '🎪', '🤹', '🎭', '🩰', '🎨', '🎬', '🎤', '🎧', '🎼', '🎹',
        '🥁', '🪘', '🎷', '🎺', '🪗', '🎸', '🪕', '🎻', '🎲', '♟️', '🎯', '🎳',
      ]),
      _EmojiGroup('旅行', <String>[
        '🚗', '🚕', '🚙', '🚌', '🚎', '🏎️', '🚓', '🚑', '🚒', '🚐', '🛻', '🚚',
        '🚛', '🚜', '🦯', '🦽', '🦼', '🛴', '🚲', '🛵', '🏍️', '🛺', '🚨', '🚔',
        '🚍', '🚘', '🚖', '🚡', '🚠', '🚟', '🚃', '🚋', '🚞', '🚝', '🚄', '🚅',
        '🚈', '🚂', '🚆', '🚇', '🚊', '🚉', '✈️', '🛫', '🛬', '🛩️', '💺', '🛰️',
        '🚀', '🛸', '🚁', '🛶', '⛵', '🚤', '🛥️', '🛳️', '⛴️', '🚢', '⚓', '🛟',
        '🗺️', '🗿', '🗽', '🗼', '🏰', '🏯', '🏟️', '🎡', '🎢', '🎠', '⛲', '⛱️',
        '🏖️', '🏝️', '🏜️', '🌋', '⛰️', '🏔️', '🗻', '🏕️', '⛺', '🛖', '🏠', '🏡',
      ]),
      _EmojiGroup('物品', <String>[
        '⌚', '📱', '📲', '💻', '⌨️', '🖥️', '🖨️', '🖱️', '🖲️', '🕹️', '🗜️', '💽',
        '💾', '💿', '📀', '📼', '📷', '📸', '📹', '🎥', '📽️', '🎞️', '📞', '☎️',
        '📟', '📠', '📺', '📻', '🎙️', '🎚️', '🎛️', '🧭', '⏱️', '⏲️', '⏰', '🕰️',
        '⌛', '⏳', '📡', '🔋', '🪫', '🔌', '💡', '🔦', '🕯️', '🪔', '🧯', '🛢️',
        '💸', '💵', '💴', '💶', '💷', '🪙', '💰', '💳', '💎', '⚖️', '🪜', '🧰',
        '🪛', '🔧', '🔨', '⚒️', '🛠️', '⛏️', '🪚', '🔩', '⚙️', '🪤', '🧱', '⛓️',
        '🧲', '🔫', '💣', '🧨', '🪓', '🔪', '🗡️', '⚔️', '🛡️', '🚬', '⚰️', '🪦',
        '⚱️', '🏺', '🔮', '📿', '🧿', '💈', '⚗️', '🔭', '🔬', '🕳️', '🩹', '🩺',
      ]),
      _EmojiGroup('符号', <String>[
        '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍', '🤎', '💔', '❣️', '💕',
        '💞', '💓', '💗', '💖', '💘', '💝', '💟', '☮️', '✝️', '☪️', '🕉️', '☸️',
        '✡️', '🔯', '🕎', '☯️', '☦️', '🛐', '⛎', '♈', '♉', '♊', '♋', '♌',
        '♍', '♎', '♏', '♐', '♑', '♒', '♓', '🆔', '⚛️', '🉑', '☢️', '☣️',
        '📴', '📳', '🈶', '🈚', '🈸', '🈺', '🈷️', '✴️', '🆚', '💮', '🉐', '㊙️',
        '㊗️', '🈴', '🈵', '🈹', '🈲', '🅰️', '🅱️', '🆎', '🆑', '🅾️', '🆘', '❌',
        '⭕', '🛑', '⛔', '📛', '🚫', '💯', '💢', '♨️', '🚷', '🚯', '🚳', '🚱',
        '🔞', '📵', '🚭', '❗', '❕', '❓', '❔', '‼️', '⁉️', '🔅', '🔆', '〽️',
      ]),
      _EmojiGroup('旗帜', <String>[
        '🏳️', '🏴', '🏁', '🚩', '🏳️‍🌈', '🏳️‍⚧️', '🇨🇳', '🇭🇰', '🇲🇴', '🇹🇼', '🇺🇸', '🇬🇧',
        '🇯🇵', '🇰🇷', '🇸🇬', '🇲🇾', '🇹🇭', '🇻🇳', '🇮🇩', '🇵🇭', '🇮🇳', '🇦🇺', '🇳🇿', '🇨🇦',
        '🇩🇪', '🇫🇷', '🇮🇹', '🇪🇸', '🇵🇹', '🇳🇱', '🇧🇪', '🇨🇭', '🇦🇹', '🇸🇪', '🇳🇴', '🇩🇰',
        '🇫🇮', '🇮🇸', '🇮🇪', '🇵🇱', '🇨🇿', '🇭🇺', '🇬🇷', '🇹🇷', '🇷🇺', '🇺🇦', '🇧🇷', '🇦🇷',
        '🇲🇽', '🇿🇦', '🇪🇬', '🇸🇦', '🇦🇪', '🇮🇱',
      ]),
    ];
  }

  Widget _buildFileMessage(ChatMessage message) {
    final name = message.extra['name']?.toString() ?? message.content;
    final size = message.extra['size'] is int ? message.extra['size'] as int : 0;
    return InkWell(
      onTap: () => _downloadSharedFile(message),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file_outlined),
          SizedBox(width: context.spacingXSmall),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  size > 0 ? _formatSize(size) : '文件夹 / 点击查看',
                  style: TextStyle(
                    fontSize: context.fontSmall,
                    color: widget.isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(String text) {
    final isDark = widget.isDark;
    return Center(
      child: Padding(
        padding: EdgeInsets.all(context.spacingXLarge),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline,
              size: context.w(64),
              color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
            ),
            SizedBox(height: context.spacingMedium),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: context.fontBody,
                color: isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateRoomDialog() async {
    final nameController = TextEditingController();
    final passwordController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('创建聊天室'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '聊天室名称'),
              ),
              SizedBox(height: context.spacingSmall),
              TextField(
                controller: passwordController,
                obscureText: true,
                decoration: const InputDecoration(labelText: '房间密码（可选）'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('创建'),
            ),
          ],
        );
      },
    );
    if (result == true) {
      await _service.createRoom(nameController.text, passwordController.text);
    }
  }

  Future<void> _joinRoom(ChatRoomInfo room) async {
    var password = '';
    if (room.hasPassword) {
      final controller = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: const Text('输入房间密码'),
            content: TextField(
              controller: controller,
              obscureText: true,
              decoration: const InputDecoration(labelText: '房间密码'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('加入'),
              ),
            ],
          );
        },
      );
      if (ok != true) {
        return;
      }
      password = controller.text;
    }
    setState(() {
      _loading = true;
    });
    final joined = await _service.joinRoom(room, password);
    if (mounted) {
      setState(() {
        _loading = false;
      });
      if (!joined) {
        showTopToast(context, '加入聊天室失败', isSuccess: false);
      }
    }
  }

  Future<void> _sendText() async {
    final text = _messageController.text;
    if (text.trim().isEmpty) {
      return;
    }
    try {
      await _service.sendText(text);
      _messageController.clear();
    } catch (e) {
      _messageController.text = text;
      _messageController.selection = TextSelection.collapsed(offset: text.length);
      if (mounted) {
        showTopToast(context, '发送失败：$e', isSuccess: false);
      }
    }
  }

  void _toggleEmojiPanel() {
    setState(() {
      _emojiVisible = !_emojiVisible;
    });
  }

  void _insertEmoji(String emoji) {
    final value = _messageController.value;
    final selection = value.selection;
    final start = selection.start < 0 ? value.text.length : selection.start;
    final end = selection.end < 0 ? value.text.length : selection.end;
    final nextText = value.text.replaceRange(start, end, emoji);
    final nextOffset = start + emoji.length;
    _messageController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
  }

  void _startVoiceHold() {
    setState(() {
      _emojiVisible = false;
      _voicePressed = true;
      _voiceStartAt = DateTime.now();
    });
    showTopToast(context, '正在录制语音，松开发送', isSuccess: true);
    unawaited(ChatVoiceRecorder.start());
  }

  Future<void> _finishVoiceHold({required bool cancel}) async {
    final start = _voiceStartAt;
    setState(() {
      _voicePressed = false;
      _voiceStartAt = null;
    });
    if (cancel || start == null) {
      await ChatVoiceRecorder.cancel();
      return;
    }
    final durationMs = DateTime.now().difference(start).inMilliseconds;
    if (durationMs < 600) {
      await ChatVoiceRecorder.cancel();
      showTopToast(context, '语音时间太短', isSuccess: false);
      return;
    }
    try {
      final record = await ChatVoiceRecorder.stop();
      if (record != null) {
        final entry = await _fileServer.shareExistingFile(
          record.path,
          displayName: '语音_${DateTime.now().millisecondsSinceEpoch}.m4a',
        );
        if (entry != null) {
          setState(() {});
          final payload = entry.toJson(widget.currentIp ?? '');
          payload['durationMs'] = record.durationMs;
          payload['recorded'] = true;
          await _service.sendMessage(
            ChatMessageType.voice,
            entry.name,
            payload,
          );
          return;
        }
      }
      await _service.sendMessage(
        ChatMessageType.voice,
        '语音消息',
        <String, dynamic>{
          'durationMs': durationMs,
          'recorded': false,
          'note': '真实录音文件采集待接入平台原生录音模块',
        },
      );
    } catch (e) {
      if (mounted) {
        showTopToast(context, '语音消息发送失败：$e', isSuccess: false);
      }
    }
  }

  Future<void> _showShareMenu() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.insert_drive_file_outlined),
                title: const Text('共享文件'),
                onTap: () => Navigator.of(context).pop('file'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('共享文件夹'),
                onTap: () => Navigator.of(context).pop('dir'),
              ),
            ],
          ),
        );
      },
    );
    if (value == null) {
      return;
    }
    SharedFileEntry? entry;
    if (value == 'file') {
      entry = await _fileServer.pickAndShareFile();
    } else {
      entry = await _fileServer.pickAndShareDirectory();
    }
    if (entry == null) {
      return;
    }
    setState(() {});
    final currentIp = widget.currentIp ?? '';
    final payload = entry.toJson(currentIp);
    final type = entry.isDirectory ? ChatMessageType.file : _guessFileMessageType(entry.name);
    await _service.sendMessage(type, entry.name, payload);
  }

  Future<void> _downloadSharedFile(ChatMessage message) async {
    final isDirectory = message.extra['isDirectory'] == true;
    final url = message.extra['url']?.toString() ?? '';
    final listUrl = message.extra['listUrl']?.toString() ?? '';
    if (isDirectory && listUrl.isNotEmpty) {
      await _showSharedFolder(listUrl);
      return;
    }
    if (url.isEmpty) {
      return;
    }
    final name = message.extra['name']?.toString() ?? message.content;
    final savePath = await FilePicker.platform.saveFile(fileName: name);
    if (savePath == null) {
      return;
    }
    setState(() {
      _loading = true;
    });
    try {
      final request = await HttpClient().getUrl(Uri.parse(url));
      final response = await request.close();
      final file = File(savePath);
      final sink = file.openWrite();
      await response.pipe(sink);
      if (mounted) {
        showTopToast(context, '文件已保存：$savePath', isSuccess: true);
      }
    } catch (e) {
      if (mounted) {
        showTopToast(context, '下载失败：$e', isSuccess: false);
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _showSharedFolder(String listUrl) async {
    final first = await _fetchSharedFolder(listUrl);
    if (!mounted || first == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        Map<String, dynamic> folder = first;
        return SafeArea(
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              final path = folder['path']?.toString() ?? '';
              final parentUrl = folder['parentUrl']?.toString();
              final filesValue = folder['files'];
              final files = filesValue is List
                  ? filesValue.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList()
                  : <Map<String, dynamic>>[];
              return SizedBox(
                height: MediaQuery.of(context).size.height * 0.72,
                child: Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.all(_ChatTabState.this.context.spacingMedium),
                      child: Row(
                        children: [
                          IconButton(
                            tooltip: '上级目录',
                            onPressed: parentUrl == null
                                ? null
                                : () async {
                                    final parent = await _fetchSharedFolder(parentUrl);
                                    if (parent != null) {
                                      setSheetState(() {
                                        folder = parent;
                                      });
                                    }
                                  },
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          Expanded(
                            child: Text(
                              path.isEmpty ? '共享文件夹' : path,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: _ChatTabState.this.context.fontMedium,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: files.isEmpty
                          ? _buildEmpty('当前文件夹为空')
                          : ListView.builder(
                              itemCount: files.length,
                              itemBuilder: (context, index) {
                                final item = files[index];
                                final name = item['name']?.toString() ?? '';
                                final isDir = item['isDirectory'] == true;
                                final size = item['size'] is int ? item['size'] as int : 0;
                                return ListTile(
                                  leading: Icon(isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined),
                                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text(isDir ? '文件夹' : _formatSize(size)),
                                  trailing: isDir ? const Icon(Icons.chevron_right) : const Icon(Icons.download_outlined),
                                  onTap: () async {
                                    if (isDir) {
                                      final nextUrl = item['listUrl']?.toString() ?? '';
                                      final next = await _fetchSharedFolder(nextUrl);
                                      if (next != null) {
                                        setSheetState(() {
                                          folder = next;
                                        });
                                      }
                                    } else {
                                      Navigator.of(context).pop();
                                      final url = item['url']?.toString() ?? '';
                                      _downloadUrl(url, name);
                                    }
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<Map<String, dynamic>?> _fetchSharedFolder(String listUrl) async {
    if (listUrl.isEmpty) {
      return null;
    }
    setState(() {
      _loading = true;
    });
    try {
      final request = await HttpClient().getUrl(Uri.parse(listUrl));
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      final json = text.isEmpty ? null : jsonDecode(text);
      if (json is Map) {
        return Map<String, dynamic>.from(json);
      }
    } catch (e) {
      if (mounted) {
        showTopToast(context, '读取文件夹失败：$e', isSuccess: false);
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
    return null;
  }

  Future<void> _downloadUrl(String url, String name) async {
    if (url.isEmpty) {
      return;
    }
    final savePath = await FilePicker.platform.saveFile(fileName: name);
    if (savePath == null) {
      return;
    }
    setState(() {
      _loading = true;
    });
    try {
      final request = await HttpClient().getUrl(Uri.parse(url));
      final response = await request.close();
      final file = File(savePath);
      final sink = file.openWrite();
      await response.pipe(sink);
      if (mounted) {
        showTopToast(context, '文件已保存：$savePath', isSuccess: true);
      }
    } catch (e) {
      if (mounted) {
        showTopToast(context, '下载失败：$e', isSuccess: false);
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _showImagePreview(String name, String url) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return Dialog(
          insetPadding: EdgeInsets.all(this.context.spacingMedium),
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              Positioned.fill(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4,
                  child: Center(
                    child: Image.network(
                      url,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        return const Text(
                          '图片加载失败',
                          style: TextStyle(color: Colors.white),
                        );
                      },
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 8,
                top: 8,
                right: 8,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    IconButton(
                      tooltip: '下载',
                      onPressed: () {
                        Navigator.of(context).pop();
                        _downloadUrl(url, name);
                      },
                      icon: const Icon(Icons.download_outlined, color: Colors.white),
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, color: Colors.white),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openVideoMessage(String url) async {
    if (url.isEmpty) {
      showTopToast(context, '视频地址无效', isSuccess: false);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      showTopToast(context, '视频地址无效', isSuccess: false);
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      showTopToast(context, '无法打开视频，请尝试下载后播放', isSuccess: false);
    }
  }

  Future<void> _sendCallAction(String mode) async {
    final result = await ChatPlatformPermissions.requestAudioVideo();
    if (!mounted) {
      return;
    }
    showTopToast(context, result.message, isSuccess: result.granted);
    if (!result.granted) {
      return;
    }
    await _service.sendMessage(ChatMessageType.call, mode == 'voice' ? '发起了语音聊天邀请' : '发起了视频聊天邀请', <String, dynamic>{
      'mode': mode,
    });
    await _service.sendCallPacket(ChatPacketType.callInvite, <String, dynamic>{
      'mode': mode,
      'state': 'invite',
    });
  }

  Future<void> _sendScreenShareAction() async {
    final result = await ChatPlatformPermissions.requestScreenShare();
    if (!mounted) {
      return;
    }
    showTopToast(context, result.message, isSuccess: result.granted);
    if (!result.granted) {
      return;
    }
    await _service.sendMessage(ChatMessageType.call, '发起了屏幕共享邀请', <String, dynamic>{
      'mode': 'screen',
    });
    await _service.sendCallPacket(ChatPacketType.screenShare, <String, dynamic>{
      'state': 'invite',
    });
  }

  Future<void> _sendRemoteAssistAction() async {
    final result = await ChatPlatformPermissions.requestRemoteAssist();
    if (!mounted) {
      return;
    }
    showTopToast(context, result.message, isSuccess: result.granted);
    if (!result.granted) {
      return;
    }
    await _service.sendMessage(ChatMessageType.call, '发起了远程协助邀请', <String, dynamic>{
      'mode': 'remoteAssist',
    });
    await _service.sendCallPacket(ChatPacketType.remoteControl, <String, dynamic>{
      'state': 'invite',
    });
  }

  void _showMembers() {
    final session = _session;
    if (session == null) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: session.members.map((member) {
              return ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(member.name),
                subtitle: Text(member.ip),
              );
            }).toList(),
          ),
        );
      },
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String _guessFileMessageType(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.gif') || lower.endsWith('.webp')) {
      return ChatMessageType.image;
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.mov') || lower.endsWith('.mkv') || lower.endsWith('.avi')) {
      return ChatMessageType.video;
    }
    if (lower.endsWith('.mp3') || lower.endsWith('.aac') || lower.endsWith('.wav') || lower.endsWith('.m4a')) {
      return ChatMessageType.voice;
    }
    return ChatMessageType.file;
  }

  String _formatSize(int size) {
    if (size >= 1024 * 1024 * 1024) {
      return '${(size / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    if (size >= 1024 * 1024) {
      return '${(size / 1024 / 1024).toStringAsFixed(2)} MB';
    }
    if (size >= 1024) {
      return '${(size / 1024).toStringAsFixed(2)} KB';
    }
    return '$size B';
  }
}

class _EmojiGroup {
  final String title;
  final List<String> emojis;

  const _EmojiGroup(this.title, this.emojis);
}
