import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/db_helper.dart';
import '../models/package_model.dart';
import '../models/resource_model.dart';
import '../services/download_service.dart';

class WebViewScreen extends StatefulWidget {
  final String initialUrl;
  final bool isOfflineMode;

  const WebViewScreen({
    Key? key,
    required this.initialUrl,
    required this.isOfflineMode,
  }) : super(key: key);

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  InAppWebViewController? _webViewController;
  final DBHelper _dbHelper = DBHelper();
  final DownloadService _downloadService = DownloadService();
  
  double _progress = 0.0;
  String _apiKey = '';
  bool _isLoading = true;

  // Background download status subscriptions and variables
  StreamSubscription? _downloadProgressSubscription;
  StreamSubscription? _downloadStatusSubscription;
  String? _activeDownloadPackageId;
  String? _activeDownloadPackageTitle;
  double _activeDownloadProgress = 0.0;
  String _activeDownloadStatus = '';

  @override
  void initState() {
    super.initState();
    _loadApiKey();
    _subscribeToDownloads();
  }

  @override
  void dispose() {
    _downloadProgressSubscription?.cancel();
    _downloadStatusSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKey = prefs.getString('api_key') ?? '';
    });
  }

  void _subscribeToDownloads() {
    _downloadProgressSubscription = _downloadService.progressStream.listen((event) async {
      if (mounted) {
        final pkg = await _dbHelper.getPackage(event.packageId);
        setState(() {
          _activeDownloadPackageId = event.packageId;
          _activeDownloadPackageTitle = pkg?.title ?? event.packageId;
          _activeDownloadProgress = event.progress;
          _activeDownloadStatus = 'downloading';
        });
      }
    });

    _downloadStatusSubscription = _downloadService.statusStream.listen((event) async {
      if (mounted) {
        final pkg = await _dbHelper.getPackage(event.packageId);
        final titleStr = pkg?.title ?? event.packageId;
        setState(() {
          _activeDownloadPackageTitle = titleStr;
          if (event.status == 'completed' || event.status == 'failed') {
            _activeDownloadStatus = event.status;
            if (event.status == 'completed') {
              _activeDownloadProgress = 1.0;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Package "$titleStr" downloaded successfully!'),
                  backgroundColor: Colors.teal,
                ),
              );
            } else {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Package "$titleStr" download failed.'),
                  backgroundColor: Colors.redAccent,
                ),
              );
            }
            Future.delayed(const Duration(seconds: 3), () {
              if (mounted && _activeDownloadPackageId == event.packageId) {
                setState(() {
                  _activeDownloadPackageId = null;
                  _activeDownloadPackageTitle = null;
                });
              }
            });
          } else {
            _activeDownloadPackageId = event.packageId;
            _activeDownloadStatus = event.status;
          }
        });
      }
    });

    // Check if any download is already running when this screen is initialized
    final activeIds = _downloadService.activeDownloadIds;
    if (activeIds.isNotEmpty) {
      final activeId = activeIds.first;
      _dbHelper.getPackage(activeId).then((pkg) {
        if (mounted) {
          setState(() {
            _activeDownloadPackageId = activeId;
            _activeDownloadPackageTitle = pkg?.title ?? activeId;
            _activeDownloadStatus = 'downloading';
            _activeDownloadProgress = 0.0;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Inject custom bridge script AT_DOCUMENT_START
    // This defines window.NetOutpostBridge to match the client requirement
    final initialUserScripts = UnmodifiableListView<UserScript>([
      UserScript(
        source: """
          (function() {
            if (!window.NetOutpostBridge) {
              window.NetOutpostBridge = {
                postMessage: function(message) {
                  window.flutter_inappwebview.callHandler('NetOutpostBridge', message);
                }
              };
            }
          })();
        """,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ]);

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: Text(widget.isOfflineMode ? 'Offline Sandbox' : 'NetSanctum Live'),
        backgroundColor: const Color(0xFF1E293B),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => _webViewController?.reload(),
          ),
          if (_webViewController != null)
            FutureBuilder<bool>(
              future: _webViewController!.canGoBack(),
              builder: (context, snapshot) {
                final canGoBack = snapshot.data ?? false;
                return IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new, size: 18),
                  onPressed: canGoBack ? () => _webViewController!.goBack() : null,
                );
              },
            ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri(widget.initialUrl),
              headers: {
                if (_apiKey.isNotEmpty) 'X-API-Key': _apiKey,
              },
            ),
            initialUserScripts: initialUserScripts,
            initialSettings: InAppWebViewSettings(
              useShouldOverrideUrlLoading: true,
              mediaPlaybackRequiresUserGesture: false,
              javaScriptEnabled: true,
              domStorageEnabled: true,
              allowsInlineMediaPlayback: true,
              // Allows localhost requests on older Android versions
              mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
            ),
            onWebViewCreated: (controller) {
              _webViewController = controller;
              _setupJavaScriptBridge(controller);
            },
            shouldOverrideUrlLoading: (controller, navigationAction) async {
              print('WebView redirecting/loading: ${navigationAction.request.url}');
              return NavigationActionPolicy.ALLOW;
            },
            onReceivedServerTrustAuthRequest: (controller, challenge) async {
              print('WebView SSL Trust Request for: ${challenge.protectionSpace.host}');
              // Allow self-signed certificates for self-hosted media registry
              return ServerTrustAuthResponse(action: ServerTrustAuthResponseAction.PROCEED);
            },
            onConsoleMessage: (controller, consoleMessage) {
              print('WebView Console [${consoleMessage.messageLevel}]: ${consoleMessage.message}');
            },
            onReceivedError: (controller, request, error) {
              print('WebView Error for ${request.url}: ${error.description} (code: ${error.type})');
            },
            onReceivedHttpError: (controller, request, errorResponse) {
              print('WebView HTTP Error for ${request.url}: Status ${errorResponse.statusCode}');
            },
            onLoadStart: (controller, url) {
              setState(() => _isLoading = true);
            },
            onLoadStop: (controller, url) async {
              setState(() => _isLoading = false);
              // Inject API key into local storage so that API requests inside the webpage can access it
              if (_apiKey.isNotEmpty) {
                await controller.evaluateJavascript(source: """
                  localStorage.setItem('X-API-Key', '$_apiKey');
                  window.X_API_KEY = '$_apiKey';
                """);
              }
            },
            onProgressChanged: (controller, progress) {
              setState(() {
                _progress = progress / 100;
                if (progress == 100) {
                  _isLoading = false;
                }
              });
            },
          ),
          // Loading Progress Bar
          if (_isLoading || _progress < 1.0)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                value: _progress > 0.0 ? _progress : null,
                backgroundColor: Colors.transparent,
                valueColor: const AlwaysStoppedAnimation<Color>(Colors.blueAccent),
                minHeight: 3,
              ),
            ),
          // Floating Download HUD Card
          if (_activeDownloadPackageId != null)
            Positioned(
              bottom: 16,
              left: 16,
              right: 16,
              child: _buildDownloadHUDCard(),
            ),
        ],
      ),
    );
  }

  void _setupJavaScriptBridge(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'NetOutpostBridge',
      callback: (args) async {
        if (args.isEmpty) return;

        print('Bridge message received: $args');
        try {
          final dynamic rawData = args.first;
          Map<String, dynamic> data;
          
          if (rawData is String) {
            data = jsonDecode(rawData);
          } else if (rawData is Map) {
            data = Map<String, dynamic>.from(rawData);
          } else {
            print('Bridge Error: Unsupported message type');
            return;
          }

          final action = data['action'];
          if (action == 'DOWNLOAD_PACKAGE') {
            final manifest = data['manifest'];
            final packageId = manifest['package_id'];
            final rootUrl = manifest['root_url'];
            final resourcesList = manifest['resources'] as List<dynamic>;
            final packageTitle = manifest['package_title'] ?? manifest['title'] ?? manifest['name'] ?? manifest['package_name'] ?? packageId;

            // 1. Store Package details with 'pending' state
            final package = PackageModel(
              id: packageId,
              title: packageTitle,
              rootUrl: rootUrl,
              status: 'pending',
              progress: 0.0,
              date: DateTime.now().toIso8601String(),
            );
            await _dbHelper.insertPackage(package);

            // 2. Store individual resources to be downloaded
            for (var res in resourcesList) {
              final resUrl = res['url'] as String;
              final resType = res['type'] as String;

              final resource = ResourceModel(
                packageId: packageId,
                relativeUrl: resUrl,
                localPath: '', // to be populated on completion
                type: resType,
              );
              await _dbHelper.insertResource(resource);
            }

            // 3. Queue download sequence
            _downloadService.addToQueue(packageId);

            // 4. Notify User
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Download of package "$packageId" added to queue.'),
                backgroundColor: Colors.indigo,
                duration: const Duration(seconds: 4),
              ),
            );
          }
        } catch (e) {
          print('Bridge Error: failed to process request payload. Exception: $e');
        }
      },
    );
  }
  Widget _buildDownloadHUDCard() {
    Color cardBorderColor = const Color(0xFF334155);
    Color accentColor = Colors.amber;
    IconData statusIcon = Icons.cloud_download;
    String statusText = 'Syncing...';

    if (_activeDownloadStatus == 'completed') {
      cardBorderColor = Colors.teal;
      accentColor = Colors.teal;
      statusIcon = Icons.check_circle;
      statusText = 'Completed';
    } else if (_activeDownloadStatus == 'failed') {
      cardBorderColor = Colors.redAccent;
      accentColor = Colors.redAccent;
      statusIcon = Icons.error_outline;
      statusText = 'Failed';
    }

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B).withOpacity(0.95), // Slate 800 with slight transparency
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cardBorderColor, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 12,
            offset: const Offset(0, 6),
          )
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(statusIcon, color: accentColor, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'OFFLINE SYNC PROGRESS',
                          style: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(right: 8.0),
                          child: Text(
                            statusText.toUpperCase(),
                            style: TextStyle(
                              color: accentColor,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _activeDownloadPackageTitle ?? _activeDownloadPackageId ?? '',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_activeDownloadStatus == 'downloading')
                IconButton(
                  icon: const Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 20),
                  onPressed: () {
                    if (_activeDownloadPackageId != null) {
                      _downloadService.cancelDownload(_activeDownloadPackageId!);
                    }
                  },
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _activeDownloadProgress,
                    backgroundColor: const Color(0xFF0F172A),
                    valueColor: AlwaysStoppedAnimation<Color>(accentColor),
                    minHeight: 5,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${(_activeDownloadProgress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: accentColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
