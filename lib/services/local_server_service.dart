import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:path/path.dart' as p;
import '../database/db_helper.dart';
import 'storage_helper.dart';
import 'nsp_reader.dart';

class LocalServerService {
  static final LocalServerService _instance = LocalServerService._internal();
  factory LocalServerService() => _instance;
  LocalServerService._internal();

  HttpServer? _server;
  final DBHelper _dbHelper = DBHelper();
  String? _activePackageId;
  final Map<String, NspReader> _nspReaders = {};

  late final String _secureToken = _generateSecureToken();
  String get secureToken => _secureToken;

  String _generateSecureToken() {
    final random = Random.secure();
    final values = List<int>.generate(16, (i) => random.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '').replaceAll('-', '').replaceAll('_', '');
  }

  bool get isRunning => _server != null;

  Future<void> start() async {
    if (_server != null) return;

    var handler = const Pipeline()
        .addMiddleware(logRequests())
        .addMiddleware(_addCorsHeaders())
        .addMiddleware(_verifySecureToken())
        .addHandler(_handleRequest);

    try {
      _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 9000);
      print('Local Outpost Server running on http://127.0.0.1:9000');
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

  Middleware _verifySecureToken() {
    return (Handler innerHandler) {
      return (Request request) async {
        final userAgent = request.headers['user-agent'] ?? '';
        bool isAuthorized = userAgent.contains(_secureToken);

        // Fallback for native Android media players which request video/audio/images
        if (!isAuthorized) {
          final uaLower = userAgent.toLowerCase();
          if (uaLower.contains('stagefright') ||
              uaLower.contains('exoplayer') ||
              uaLower.contains('mediaplayer') ||
              uaLower.contains('dalvik') ||
              uaLower.contains('android')) {
            final path = request.url.path.toLowerCase();
            final isMediaRequest = request.headers.containsKey('range') ||
                path.endsWith('.mp4') ||
                path.endsWith('.mp3') ||
                path.endsWith('.m4a') ||
                path.endsWith('.png') ||
                path.endsWith('.jpg') ||
                path.endsWith('.jpeg') ||
                path.endsWith('.webp');
            if (isMediaRequest) {
              isAuthorized = true;
            }
          }
        }

        if (!isAuthorized) {
          print('Blocking unauthorized request to local server: ${request.url.path} (UA: $userAgent)');
          return Response.forbidden('Forbidden: Unauthorized connection');
        }

        return await innerHandler(request);
      };
    };
  }

  Future<Response> _handleRequest(Request request) async {
    // Normalise request URL path (include query string for accurate lookup).
    final path = request.url.path;
    final query = request.url.query;
    final String lookupPath = query.isNotEmpty ? '/' + path + '?' + query : '/' + path;

    print('Local server request: $lookupPath');

    // 1. Determine active package ID if present in query parameters
    final String? pkgId = request.url.queryParameters['package_id'];
    if (pkgId != null && pkgId.isNotEmpty) {
      _activePackageId = pkgId;
    }

    // 2. If we have an active package, check if its .nsp container exists and contains the resource
    if (_activePackageId != null) {
      try {
        final appDocDir = await getCacheDirectory();
        final nspPath = p.join(appDocDir.path, 'offline_cache', '${_activePackageId}.nsp');
        final nspFile = File(nspPath);
        if (await nspFile.exists()) {
          var reader = _nspReaders[_activePackageId!];
          if (reader == null) {
            reader = NspReader(nspPath);
            await reader.init();
            _nspReaders[_activePackageId!] = reader;
          }

          if (reader.hasResource(lookupPath)) {
            final bytes = await reader.getResourceBytes(lookupPath);
            if (bytes != null) {
              final mime = reader.getMimeType(lookupPath);
              return Response.ok(
                bytes,
                headers: {
                  'Content-Type': mime,
                  'Access-Control-Allow-Origin': '*',
                },
              );
            }
          }
        }
      } catch (e) {
        print('Error reading from NSP container for $_activePackageId: $e');
      }
    }

    // Try to find the resource in DB by exact relative_url match (includes query string).
    var resource = await _dbHelper.getResourceByUrl(lookupPath);
    
    // Prefix-mismatch fallback: match by last 2 path segments ONLY if query strings also match.
    // This prevents all /alllib/api/page?path=X resources collapsing into the same file.
    if (resource == null) {
      final reqUri = Uri.parse(lookupPath);
      final segments = reqUri.pathSegments;
      if (segments.isNotEmpty) {
        final allPackages = await _dbHelper.getAllPackages();
        outer:
        for (var pkg in allPackages) {
          final resources = await _dbHelper.getResourcesForPackage(pkg.id);
          for (var res in resources) {
            final resUri = Uri.parse(res.relativeUrl);
            // Query params must match to avoid false positives (e.g. all api/page?path=X)
            if (resUri.queryParameters != reqUri.queryParameters) continue;
            if (resUri.pathSegments.length >= 2 && segments.length >= 2) {
              final resSuffix = resUri.pathSegments.sublist(resUri.pathSegments.length - 2).join('/');
              final reqSuffix = segments.sublist(segments.length - 2).join('/');
              if (resSuffix == reqSuffix) {
                resource = res;
                break outer;
              }
            } else if (resUri.pathSegments.isNotEmpty && segments.isNotEmpty) {
              if (resUri.pathSegments.last == segments.last) {
                resource = res;
                break outer;
              }
            }
          }
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
