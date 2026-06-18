import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../database/db_helper.dart';
import '../models/resource_model.dart';
import 'storage_helper.dart';

class DownloadService {
  static final DownloadService _instance = DownloadService._internal();
  factory DownloadService() => _instance;
  DownloadService._internal();

  static const _channel = MethodChannel('com.example.netoutpost/sync');

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
      
      // Stop native foreground service
      try {
        await _channel.invokeMethod('stopService');
      } catch (_) {}
    } finally {
      _isProcessing = false;
      // Continue to next package
      _processQueue();
    }
  }

  Future<void> _downloadPackage(String packageId) async {
    final package = await _dbHelper.getPackage(packageId);
    if (package == null) return;

    // Request notification permission if needed
    try {
      final status = await Permission.notification.status;
      if (!status.isGranted) {
        await Permission.notification.request();
      }
    } catch (e) {
      print('Failed to request notification permission: $e');
    }

    // Start native foreground service
    try {
      await _channel.invokeMethod('startService', {
        'title': package.title.isNotEmpty ? package.title : 'Syncing Package',
      });
    } catch (e) {
      print('Failed to start foreground service: $e');
    }

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
      
      try {
        await _channel.invokeMethod('stopService');
      } catch (_) {}
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

    // Speed and remaining time calculation trackers
    final DateTime startTime = DateTime.now();
    DateTime lastUiUpdateTime = DateTime.now();
    int bytesFromCompletedFiles = 0;
    int bytesFromCurrentFile = 0;

    String formatSpeed(double bytesPerSecond) {
      if (bytesPerSecond >= 1024 * 1024) {
        return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
      } else if (bytesPerSecond >= 1024) {
        return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
      } else {
        return '${bytesPerSecond.toStringAsFixed(0)} B/s';
      }
    }

    String formatRemaining(int seconds, int remainingFiles) {
      if (seconds <= 0) return '$remainingFiles files left';
      if (seconds < 60) {
        return '$seconds sec left ($remainingFiles left)';
      } else {
        final minutes = seconds ~/ 60;
        return '$minutes min left ($remainingFiles left)';
      }
    }

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

      // Ensure local extension if none exists
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

      final String localFilePath = resource.type.toLowerCase() == 'container'
          ? p.join(offlineCacheDir.path, '${packageId}.nsp')
          : p.join(offlineCacheDir.path, cleanPath);
      final File localFile = File(localFilePath);
      
      bool alreadyDownloaded = await localFile.exists();

      if (!alreadyDownloaded) {
        await localFile.parent.create(recursive: true);

        try {
          bytesFromCurrentFile = 0;
          await _dio.download(
            sourceUrl,
            localFilePath,
            cancelToken: cancelToken,
            onReceiveProgress: (received, total) {
              if (received > 0) {
                bytesFromCurrentFile = received;
                final totalDownloadedSoFar = bytesFromCompletedFiles + bytesFromCurrentFile;
                final elapsedSeconds = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
                
                if (elapsedSeconds > 0) {
                  final double bytesPerSecond = totalDownloadedSoFar / elapsedSeconds;
                  final String speedText = formatSpeed(bytesPerSecond);
                  
                  final double avgSecondsPerFile = downloadedCount > 0 ? elapsedSeconds / downloadedCount : elapsedSeconds;
                  final int remainingFiles = totalResources - downloadedCount;
                  final int remainingSeconds = (remainingFiles * avgSecondsPerFile).round();
                  final String remainingText = formatRemaining(remainingSeconds, remainingFiles);
                  
                  final progressVal = (downloadedCount + (total > 0 ? (received / total) : 0.0)) / totalResources;
                  final progressPercent = (progressVal * 100).round().clamp(0, 100);
                  
                  _channel.invokeMethod('updateProgress', {
                    'title': package.title.isNotEmpty ? package.title : 'Syncing Package',
                    'progress': progressPercent,
                    'speed': speedText,
                    'remaining': remainingText,
                  }).catchError((_) {});

                  final now = DateTime.now();
                  if (now.difference(lastUiUpdateTime).inMilliseconds > 250) {
                    lastUiUpdateTime = now;
                    _progressController.add(DownloadProgressEvent(
                      packageId,
                      progressVal,
                      speed: speedText,
                      remaining: remainingText,
                    ));
                  }
                }
              }
            },
            options: Options(
              headers: {
                if (apiKey.isNotEmpty) ...{
                  'X-API-Key': apiKey,
                  'Authorization': 'Bearer $apiKey',
                },
              },
            ),
          );

          if (await localFile.exists()) {
            bytesFromCompletedFiles += await localFile.length();
          }
          bytesFromCurrentFile = 0;
        } catch (e) {
          print('WARNING: Failed to download resource ${resource.relativeUrl}: $e');
          try {
            if (await localFile.exists()) {
              await localFile.delete();
            }
          } catch (_) {}
          
          downloadedCount++;
          final progress = downloadedCount / totalResources;
          await _dbHelper.updatePackageStatus(packageId, 'downloading', progress: progress);
          onProgressUpdate?.call(packageId, progress);
          _progressController.add(DownloadProgressEvent(packageId, progress, speed: '', remaining: ''));
          continue;
        }
      } else {
        try {
          bytesFromCompletedFiles += await localFile.length();
        } catch (_) {}
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

      // Notify progress update with speed and remaining text
      final elapsedSeconds = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
      final double bytesPerSecond = elapsedSeconds > 0 ? bytesFromCompletedFiles / elapsedSeconds : 0.0;
      final String speedText = formatSpeed(bytesPerSecond);
      final double avgSecondsPerFile = elapsedSeconds / downloadedCount;
      final int remainingFiles = totalResources - downloadedCount;
      final int remainingSeconds = (remainingFiles * avgSecondsPerFile).round();
      final String remainingText = formatRemaining(remainingSeconds, remainingFiles);

      _progressController.add(DownloadProgressEvent(
        packageId, 
        progress,
        speed: speedText,
        remaining: remainingText,
      ));

      try {
        final progressPercent = (progress * 100).round().clamp(0, 100);
        await _channel.invokeMethod('updateProgress', {
          'title': package.title.isNotEmpty ? package.title : 'Syncing Package',
          'progress': progressPercent,
          'speed': speedText,
          'remaining': remainingText,
        });
      } catch (_) {}
    }

    _activeDownloads.remove(packageId);
    await _dbHelper.updatePackageStatus(packageId, 'completed', progress: 1.0);
    onStatusUpdate?.call(packageId, 'completed');
    _statusController.add(DownloadStatusEvent(packageId, 'completed'));

    // Stop native foreground service
    try {
      await _channel.invokeMethod('stopService');
    } catch (_) {}
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

    // Stop native foreground service
    try {
      _channel.invokeMethod('stopService');
    } catch (_) {}
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
  final String speed;
  final String remaining;
  DownloadProgressEvent(this.packageId, this.progress, {this.speed = '', this.remaining = ''});
}

class DownloadStatusEvent {
  final String packageId;
  final String status;
  DownloadStatusEvent(this.packageId, this.status);
}
