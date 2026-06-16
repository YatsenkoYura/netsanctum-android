import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../database/db_helper.dart';
import '../models/resource_model.dart';
import 'storage_helper.dart';

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  final Dio _dio = Dio();
  final DBHelper _dbHelper = DBHelper();
  
  // Active downloads map to track progress if needed
  final Map<String, CancelToken> _activeDownloads = {};
  
  // Queue state
  bool _isProcessing = false;
  final List<String> _packageQueue = [];

  // Stream Controllers for broadcasting updates to multiple listeners
  final _progressController = StreamController<DownloadProgressEvent>.broadcast();
  final _statusController = StreamController<DownloadStatusEvent>.broadcast();

  Stream<DownloadProgressEvent> get progressStream => _progressController.stream;
  Stream<DownloadStatusEvent> get statusStream => _statusController.stream;

  // Public getters to inspect active download queue status
  List<String> get activeDownloadIds => _activeDownloads.keys.toList();
  List<String> get queuedDownloadIds => List.from(_packageQueue);
  bool get isAnyDownloadActive => _activeDownloads.isNotEmpty || _isProcessing || _packageQueue.isNotEmpty;

  // Callback to notify UI of progress updates (kept for compatibility)
  Function(String packageId, double progress)? onProgressUpdate;
  Function(String packageId, String status)? onStatusUpdate;

  void addToQueue(String packageId) {
    if (!_packageQueue.contains(packageId)) {
      _packageQueue.add(packageId);
    }
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isProcessing || _packageQueue.isEmpty) return;
    _isProcessing = true;

    final packageId = _packageQueue.removeAt(0);
    try {
      await _downloadPackage(packageId);
    } catch (e) {
      print('Failed to download package $packageId: $e');
      await _dbHelper.updatePackageStatus(packageId, 'failed');
      onStatusUpdate?.call(packageId, 'failed');
      _statusController.add(DownloadStatusEvent(packageId, 'failed'));
    } finally {
      _isProcessing = false;
      // Continue to next package
      _processQueue();
    }
  }

  Future<void> _downloadPackage(String packageId) async {
    final package = await _dbHelper.getPackage(packageId);
    if (package == null) return;

    await _dbHelper.updatePackageStatus(packageId, 'downloading', progress: 0.0);
    onStatusUpdate?.call(packageId, 'downloading');
    _statusController.add(DownloadStatusEvent(packageId, 'downloading'));

    final config = await _getAppConfig();
    final serverUrl = config['serverUrl'] ?? '';
    final apiKey = config['apiKey'] ?? '';

    if (serverUrl.isEmpty) {
      throw Exception('Server URL is not configured.');
    }

    final resources = await _dbHelper.getResourcesForPackage(packageId);
    if (resources.isEmpty) {
      await _dbHelper.updatePackageStatus(packageId, 'completed', progress: 1.0);
      onStatusUpdate?.call(packageId, 'completed');
      return;
    }

    final totalResources = resources.length;
    int downloadedCount = 0;

    final appDocDir = await getCacheDirectory();
    final offlineCacheDir = Directory(p.join(appDocDir.path, 'offline_cache'));
    if (!await offlineCacheDir.exists()) {
      await offlineCacheDir.create(recursive: true);
    }

    final cancelToken = CancelToken();
    _activeDownloads[packageId] = cancelToken;

    for (var resource in resources) {
      if (cancelToken.isCancelled) {
        throw Exception('Download cancelled');
      }

      // Build source URL: combine serverUrl + resource.relativeUrl
      final String sourceUrl = serverUrl.endsWith('/') && resource.relativeUrl.startsWith('/')
          ? serverUrl + resource.relativeUrl.substring(1)
          : serverUrl + resource.relativeUrl;

      // Determine local path
      String cleanPath = resource.relativeUrl;
      if (cleanPath.startsWith('/')) {
        cleanPath = cleanPath.substring(1);
      }

      // For endpoints like /alllib/api/page?path=alllib/manga/.../file.jpg
      // extract the `path` query parameter and use it as the real local path.
      // This ensures each page gets its own unique file rather than all
      // overwriting the same `alllib/api/page.jpg`.
      final uri = Uri.parse(resource.relativeUrl);
      final queryPath = uri.queryParameters['path'];
      if (queryPath != null && queryPath.isNotEmpty) {
        cleanPath = queryPath;
        if (cleanPath.startsWith('/')) {
          cleanPath = cleanPath.substring(1);
        }
      } else {
        // No path param — just strip the query string and use the url path
        cleanPath = uri.path;
        if (cleanPath.startsWith('/')) {
          cleanPath = cleanPath.substring(1);
        }
      }

      // Ensure local extension if none exists (fully module-agnostic extension mapper)
      final extension = p.extension(cleanPath);
      if (extension.isEmpty) {
        final typeLower = resource.type.toLowerCase();
        const typeExtensions = {
          'json': '.json',
          'image': '.jpg',
          'binary': '.bin',
          'html': '.html',
          'text': '.txt',
          'css': '.css',
          'js': '.js',
          'javascript': '.js',
        };
        final ext = typeExtensions[typeLower];
        if (ext != null) {
          cleanPath += ext;
        }
      }

      final String localFilePath = p.join(offlineCacheDir.path, cleanPath);
      final File localFile = File(localFilePath);
      
      bool alreadyDownloaded = await localFile.exists();

      if (!alreadyDownloaded) {
        // Ensure local folders exist
        await localFile.parent.create(recursive: true);

        try {
          await _dio.download(
            sourceUrl,
            localFilePath,
            cancelToken: cancelToken,
            options: Options(
              headers: {
                if (apiKey.isNotEmpty) ...{
                  'X-API-Key': apiKey,
                  'Authorization': 'Bearer $apiKey',
                },
              },
            ),
          );
        } catch (e) {
          print('WARNING: Failed to download resource ${resource.relativeUrl}: $e');
          try {
            if (await localFile.exists()) {
              await localFile.delete();
            }
          } catch (_) {}
          
          // Increment count and progress so we don't get stuck
          downloadedCount++;
          final progress = downloadedCount / totalResources;
          await _dbHelper.updatePackageStatus(packageId, 'downloading', progress: progress);
          onProgressUpdate?.call(packageId, progress);
          _progressController.add(DownloadProgressEvent(packageId, progress));
          continue;
        }
      }

      // Update database with the local path
      final updatedResource = ResourceModel(
        id: resource.id,
        packageId: resource.packageId,
        relativeUrl: resource.relativeUrl,
        localPath: localFilePath,
        type: resource.type,
      );
      await _dbHelper.insertResource(updatedResource);

      downloadedCount++;
      final progress = downloadedCount / totalResources;
      await _dbHelper.updatePackageStatus(packageId, 'downloading', progress: progress);
      onProgressUpdate?.call(packageId, progress);
      _progressController.add(DownloadProgressEvent(packageId, progress));
    }

    _activeDownloads.remove(packageId);
    await _dbHelper.updatePackageStatus(packageId, 'completed', progress: 1.0);
    onStatusUpdate?.call(packageId, 'completed');
    _statusController.add(DownloadStatusEvent(packageId, 'completed'));
  }

  void cancelDownload(String packageId) {
    if (_activeDownloads.containsKey(packageId)) {
      _activeDownloads[packageId]?.cancel();
      _activeDownloads.remove(packageId);
    }
    _packageQueue.remove(packageId);
    _dbHelper.updatePackageStatus(packageId, 'failed');
    onStatusUpdate?.call(packageId, 'failed');
    _statusController.add(DownloadStatusEvent(packageId, 'failed'));
  }

  Future<Map<String, String>> _getAppConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return {
        'serverUrl': prefs.getString('server_url') ?? '',
        'apiKey': prefs.getString('api_key') ?? '',
      };
    } catch (e) {
      return {'serverUrl': '', 'apiKey': ''};
    }
  }
}

class DownloadProgressEvent {
  final String packageId;
  final double progress;
  DownloadProgressEvent(this.packageId, this.progress);
}

class DownloadStatusEvent {
  final String packageId;
  final String status;
  DownloadStatusEvent(this.packageId, this.status);
}
