import 'dart:io';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:path/path.dart' as p;
import '../database/db_helper.dart';

class LocalServerService {
  static final LocalServerService _instance = LocalServerService._internal();
  factory LocalServerService() => _instance;
  LocalServerService._internal();

  HttpServer? _server;
  final DBHelper _dbHelper = DBHelper();

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;

    var handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_addCorsHeaders())
        .addHandler(_handleRequest);

    try {
      _server = await shelf_io.serve(handler, 'localhost', 9000);
      print('Local Outpost Server running on http://localhost:9000');
    } catch (e) {
      print('Failed to start local server: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    print('Local Outpost Server stopped');
  }

  Middleware _addCorsHeaders() {
    return (Handler innerHandler) {
      return (Request request) async {
        if (request.method == 'OPTIONS') {
          return Response.ok('', headers: {
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Methods': 'GET, POST, OPTIONS, PUT, DELETE',
            'Access-Control-Allow-Headers': '*',
          });
        }
        final response = await innerHandler(request);
        return response.change(headers: {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS, PUT, DELETE',
          'Access-Control-Allow-Headers': '*',
        });
      };
    };
  }

  Future<Response> _handleRequest(Request request) async {
    // Normalise request URL path.
    final path = request.url.path;
    final String lookupPath = '/' + path;

    print('Local server request: $lookupPath');

    // Try to find the resource in DB.
    var resource = await _dbHelper.getResourceByUrl(lookupPath);
    
    // Prefix-mismatch fallback lookup (fully module-agnostic suffix matching)
    if (resource == null) {
      final segments = request.url.pathSegments;
      if (segments.isNotEmpty) {
        final allPackages = await _dbHelper.getAllPackages();
        for (var pkg in allPackages) {
          final resources = await _dbHelper.getResourcesForPackage(pkg.id);
          for (var res in resources) {
            final resUri = Uri.parse(res.relativeUrl);
            if (resUri.pathSegments.length >= 2 && segments.length >= 2) {
              final resSuffix = resUri.pathSegments.sublist(resUri.pathSegments.length - 2).join('/');
              final reqSuffix = segments.sublist(segments.length - 2).join('/');
              if (resSuffix == reqSuffix) {
                resource = res;
                break;
              }
            } else if (resUri.pathSegments.isNotEmpty && segments.isNotEmpty) {
              if (resUri.pathSegments.last == segments.last) {
                resource = res;
                break;
              }
            }
          }
          if (resource != null) break;
        }
      }
    }

    if (resource == null) {
      return Response.notFound('Resource not found: $lookupPath');
    }

    final file = File(resource.localPath);
    if (!await file.exists()) {
      return Response.notFound('Cached file not found on disk at: ${resource.localPath}');
    }

    // Dynamic filtering for any JSON list resource
    if (resource.type.toLowerCase() == 'json' || resource.type.toLowerCase() == 'application/json' || file.path.endsWith('.json')) {
      try {
        final content = await file.readAsString();
        final dynamic decoded = jsonDecode(content);
        if (decoded is List) {
          final List<dynamic> filteredList = [];
          final allPackages = await _dbHelper.getAllPackages();

          for (var item in decoded) {
            if (item is Map) {
              final id = item['id'];
              if (id != null) {
                final String idStr = id.toString();
                bool isDownloaded = false;

                // 1. Check completed packages by ID matching (e.g. pkg.id is "novel_4" or "video_A5j" and matches id "4" / "A5j")
                for (var pkg in allPackages) {
                  if (pkg.status == 'completed') {
                    if (pkg.id == idStr || pkg.id.endsWith('_$idStr')) {
                      isDownloaded = true;
                      break;
                    }
                  }
                }

                // 2. Check individual resources of completed packages (ends with id segment, e.g. /music/audio/15 matches 15)
                if (!isDownloaded) {
                  for (var pkg in allPackages) {
                    if (pkg.status == 'completed') {
                      final resources = await _dbHelper.getResourcesForPackage(pkg.id);
                      for (var res in resources) {
                        if (res.localPath.isNotEmpty) {
                          final resUri = Uri.parse(res.relativeUrl);
                          if (resUri.pathSegments.isNotEmpty && resUri.pathSegments.last == idStr) {
                            isDownloaded = true;
                            break;
                          }
                        }
                      }
                    }
                    if (isDownloaded) break;
                  }
                }

                if (isDownloaded) {
                  filteredList.add(item);
                }
              } else {
                // If item doesn't have an id, keep it
                filteredList.add(item);
              }
            } else {
              filteredList.add(item);
            }
          }

          final filteredContent = jsonEncode(filteredList);
          final headers = {
            'Content-Type': 'application/json; charset=utf-8',
            'Accept-Ranges': 'bytes',
            'Access-Control-Allow-Origin': '*',
          };
          return Response.ok(filteredContent, headers: headers);
        }
      } catch (e) {
        print('Error filtering dynamic offline JSON list for $lookupPath: $e');
      }
    }

    final contentType = _getContentType(resource.type, file.path);
    final headers = {
      'Content-Type': contentType,
      'Accept-Ranges': 'bytes',
    };

    // Range Request Handling (HTTP 206) for video/audio seek
    final rangeHeader = request.headers['range'];
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      return await _handleRangeRequest(file, rangeHeader, headers);
    }

    // Standard Response
    final length = await file.length();
    headers['Content-Length'] = length.toString();
    return Response.ok(file.openRead(), headers: headers);
  }

  Future<Response> _handleRangeRequest(File file, String rangeHeader, Map<String, String> headers) async {
    final fileLength = await file.length();
    final parts = rangeHeader.substring(6).split('-');
    
    int start = int.parse(parts[0]);
    int end = parts.length > 1 && parts[1].isNotEmpty
        ? int.parse(parts[1])
        : fileLength - 1;

    if (start >= fileLength) {
      return Response(416, body: 'Requested Range Not Satisfiable', headers: {
        'Content-Range': 'bytes */$fileLength',
      });
    }

    if (end >= fileLength) {
      end = fileLength - 1;
    }

    final chunkLength = end - start + 1;
    headers['Content-Range'] = 'bytes $start-$end/$fileLength';
    headers['Content-Length'] = chunkLength.toString();

    final stream = file.openRead(start, end + 1);
    return Response(206, body: stream, headers: headers);
  }

  String _getContentType(String type, String filePath) {
    final typeLower = type.toLowerCase();
    
    // Direct type mappings first
    if (typeLower == 'json') return 'application/json; charset=utf-8';
    if (typeLower == 'html') return 'text/html; charset=utf-8';
    if (typeLower == 'css') return 'text/css; charset=utf-8';
    if (typeLower == 'js' || typeLower == 'javascript') return 'application/javascript; charset=utf-8';
    if (typeLower == 'text') return 'text/plain; charset=utf-8';

    if (typeLower == 'image') {
      if (filePath.endsWith('.png')) return 'image/png';
      if (filePath.endsWith('.webp')) return 'image/webp';
      if (filePath.endsWith('.gif')) return 'image/gif';
      return 'image/jpeg';
    }
    if (typeLower == 'binary') {
      if (filePath.endsWith('.mp4')) return 'video/mp4';
      if (filePath.endsWith('.m4a')) return 'audio/mp4';
      if (filePath.endsWith('.mp3')) return 'audio/mpeg';
      if (filePath.endsWith('.epub')) return 'application/epub+zip';
    }

    // Fallback based on extension
    final ext = p.extension(filePath).toLowerCase();
    switch (ext) {
      case '.html':
      case '.htm': return 'text/html; charset=utf-8';
      case '.js': return 'application/javascript; charset=utf-8';
      case '.css': return 'text/css; charset=utf-8';
      case '.png': return 'image/png';
      case '.webp': return 'image/webp';
      case '.gif': return 'image/gif';
      case '.jpg':
      case '.jpeg': return 'image/jpeg';
      case '.mp4': return 'video/mp4';
      case '.mp3': return 'audio/mpeg';
      case '.epub': return 'application/epub+zip';
      case '.json': return 'application/json; charset=utf-8';
      case '.txt': return 'text/plain; charset=utf-8';
      default: return 'application/octet-stream';
    }
  }
}
