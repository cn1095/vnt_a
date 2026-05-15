import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';

import 'chat_models.dart';

class SharedFileEntry {
  final String id;
  final String name;
  final String path;
  final int size;
  final bool isDirectory;

  const SharedFileEntry({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.isDirectory,
  });

  Map<String, dynamic> toJson(String ownerIp) {
    return {
      'id': id,
      'name': name,
      'size': size,
      'isDirectory': isDirectory,
      'url': 'http://$ownerIp:${ChatPorts.files}/files/$id',
      'listUrl': isDirectory ? 'http://$ownerIp:${ChatPorts.files}/list/$id' : '',
    };
  }
}

class ChatFileServer {
  HttpServer? _server;
  final Map<String, SharedFileEntry> _entries = <String, SharedFileEntry>{};

  bool get isRunning => _server != null;
  List<SharedFileEntry> get entries => List<SharedFileEntry>.from(_entries.values);

  Future<void> start() async {
    if (_server != null) {
      return;
    }
    _server = await HttpServer.bind(InternetAddress.anyIPv4, ChatPorts.files, shared: true);
    _server!.listen(_handleRequest, onError: (_) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _entries.clear();
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<SharedFileEntry?> pickAndShareFile() async {
    final result = await FilePicker.platform.pickFiles(withData: false);
    if (result == null || result.files.isEmpty || result.files.first.path == null) {
      return null;
    }
    await start();
    final file = File(result.files.first.path!);
    if (!await file.exists()) {
      return null;
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final entry = SharedFileEntry(
      id: id,
      name: result.files.first.name,
      path: file.path,
      size: await file.length(),
      isDirectory: false,
    );
    _entries[id] = entry;
    return entry;
  }

  Future<SharedFileEntry?> pickAndShareDirectory() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null || path.isEmpty) {
      return null;
    }
    await start();
    final dir = Directory(path);
    if (!await dir.exists()) {
      return null;
    }
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    final entry = SharedFileEntry(
      id: id,
      name: path.split(Platform.pathSeparator).last,
      path: dir.path,
      size: 0,
      isDirectory: true,
    );
    _entries[id] = entry;
    return entry;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2) {
        await _writeJson(request, 404, <String, dynamic>{'error': 'not_found'});
        return;
      }
      final action = segments[0];
      final id = segments[1];
      final entry = _entries[id];
      if (entry == null) {
        await _writeJson(request, 404, <String, dynamic>{'error': 'not_found'});
        return;
      }
      if (action == 'list' && entry.isDirectory) {
        await _writeDirectoryList(request, entry);
        return;
      }
      if (action == 'files') {
        await _writeFile(request, entry, segments.length > 2 ? segments.sublist(2).join('/') : '');
        return;
      }
      await _writeJson(request, 404, <String, dynamic>{'error': 'not_found'});
    } catch (e) {
      await _writeJson(request, 500, <String, dynamic>{'error': e.toString()});
    }
  }

  Future<void> _writeDirectoryList(HttpRequest request, SharedFileEntry entry) async {
    final relative = _normalizeRelativePath(request.uri.queryParameters['path'] ?? '');
    final dir = Directory(_joinSharedPath(entry.path, relative));
    if (!await dir.exists()) {
      await _writeJson(request, 404, <String, dynamic>{'error': 'not_found'});
      return;
    }
    final list = <Map<String, dynamic>>[];
    await for (final entity in dir.list(followLinks: false)) {
      final stat = await entity.stat();
      final name = entity.path.split(Platform.pathSeparator).last;
      final childRelative = relative.isEmpty ? name : '$relative/$name';
      final encodedPath = Uri.encodeComponent(childRelative);
      list.add({
        'name': name,
        'isDirectory': entity is Directory,
        'size': entity is File ? stat.size : 0,
        'path': childRelative,
        'url': entity is File ? 'http://${request.headers.host}/files/${entry.id}/$encodedPath' : '',
        'listUrl': entity is Directory ? 'http://${request.headers.host}/list/${entry.id}?path=$encodedPath' : '',
      });
    }
    list.sort((a, b) {
      final aDir = a['isDirectory'] == true;
      final bDir = b['isDirectory'] == true;
      if (aDir != bDir) {
        return aDir ? -1 : 1;
      }
      return a['name'].toString().toLowerCase().compareTo(b['name'].toString().toLowerCase());
    });
    final parent = relative.contains('/')
        ? relative.substring(0, relative.lastIndexOf('/'))
        : '';
    await _writeJson(request, 200, <String, dynamic>{
      'path': relative,
      'parentPath': relative.isEmpty ? null : parent,
      'parentUrl': relative.isEmpty
          ? null
          : 'http://${request.headers.host}/list/${entry.id}?path=${Uri.encodeComponent(parent)}',
      'files': list,
    });
  }

  Future<void> _writeFile(HttpRequest request, SharedFileEntry entry, String relative) async {
    File file;
    if (entry.isDirectory) {
      final safeRelative = _normalizeRelativePath(Uri.decodeComponent(relative));
      if (safeRelative.isEmpty) {
        await _writeJson(request, 403, <String, dynamic>{'error': 'forbidden'});
        return;
      }
      file = File(_joinSharedPath(entry.path, safeRelative));
    } else {
      file = File(entry.path);
    }
    if (!await file.exists()) {
      await _writeJson(request, 404, <String, dynamic>{'error': 'not_found'});
      return;
    }
    final total = await file.length();
    var start = 0;
    var end = total - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    if (range != null && range.startsWith('bytes=')) {
      final parts = range.substring(6).split('-');
      start = int.tryParse(parts[0]) ?? 0;
      if (parts.length > 1 && parts[1].isNotEmpty) {
        end = int.tryParse(parts[1]) ?? end;
      }
      if (start < 0 || start >= total || end < start) {
        request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await request.response.close();
        return;
      }
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$total');
    } else {
      request.response.statusCode = HttpStatus.ok;
    }
    final count = end - start + 1;
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    request.response.headers.set(HttpHeaders.contentLengthHeader, count);
    request.response.headers.set(
      'content-disposition',
      'attachment; filename="${Uri.encodeComponent(file.path.split(Platform.pathSeparator).last)}"',
    );
    await request.response.addStream(file.openRead(start, end + 1));
    await request.response.close();
  }

  Future<void> _writeJson(HttpRequest request, int status, Map<String, dynamic> body) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  String _normalizeRelativePath(String value) {
    final decoded = Uri.decodeComponent(value).replaceAll('\\', '/');
    final parts = decoded
        .split('/')
        .where((part) => part.isNotEmpty && part != '.' && part != '..')
        .toList();
    return parts.join('/');
  }

  String _joinSharedPath(String root, String relative) {
    if (relative.isEmpty) {
      return root;
    }
    return '$root${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';
  }
}
