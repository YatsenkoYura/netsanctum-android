import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_cef/webview_cef.dart';

import '../database/db_helper.dart';
import '../models/package_model.dart';
import '../models/resource_model.dart';
import '../services/credential_store.dart';
import '../services/download_service.dart';
import '../services/session_store.dart';
import '../services/web_auth_script.dart';

class LinuxWebViewScreen extends StatefulWidget {
  final String initialUrl;
  final String serverUrl;
  final bool isOfflineMode;

  const LinuxWebViewScreen({
    super.key,
    required this.initialUrl,
    required this.serverUrl,
    required this.isOfflineMode,
  });

  @override
  State<LinuxWebViewScreen> createState() => _LinuxWebViewScreenState();
}

class _LinuxWebViewScreenState extends State<LinuxWebViewScreen> {
  final DBHelper _dbHelper = DBHelper();
  final CredentialStore _credentialStore = CredentialStore();
  final DownloadService _downloadService = DownloadService();
  final SessionStore _sessionStore = SessionStore();

  WebViewController? _controller;
  StreamSubscription<DownloadProgressEvent>? _progressSubscription;
  StreamSubscription<DownloadStatusEvent>? _statusSubscription;
  String? _error;
  String? _activePackageId;
  double _downloadProgress = 0;
  String _downloadStatus = '';
  String _downloadDetails = '';
  String _apiKey = '';

  @override
  void initState() {
    super.initState();
    _subscribeToDownloads();
    unawaited(_initializeWebView());
  }

  Future<void> _initializeWebView() async {
    try {
      _apiKey = await _credentialStore.readMasterKey();
      final scripts = InjectUserScripts()..add(UserScript('''
          (() => {
            const sendToOutpost = (message) => {
              if (typeof window.NetOutpostNative === 'function') {
                const payload = typeof message === 'string'
                    ? message
                    : JSON.stringify(message);
                return window.NetOutpostNative(payload);
              }
            };
            window.NetOutpostBridge = { postMessage: sendToOutpost };
            window.flutter_inappwebview = window.flutter_inappwebview || {};
            window.flutter_inappwebview.callHandler = (name, payload) => {
              if (name === 'NetOutpostBridge') return sendToOutpost(payload);
            };
          })();
          ${buildWebAuthScript(_apiKey, widget.serverUrl)}
        ''', ScriptInjectTime.LOAD_START));

      final controller = WebviewManager().createWebView(
        loading: const Center(child: CircularProgressIndicator()),
        injectUserScripts: scripts,
      );
      _controller = controller;

      controller.setWebviewListener(WebviewEventsListener(
        onUrlChanged: (url) {
          unawaited(_registerBridge(controller));
          if (!widget.isOfflineMode) {
            unawaited(_sessionStore.saveLiveUrl(widget.serverUrl, url));
          }
        },
        onLoadStart: (_, __) => unawaited(_registerBridge(controller)),
        onConsoleMessage: (level, message, source, line) {
          debugPrint('CEF Console [$level] $source:$line $message');
        },
      ));

      await controller.initialize(widget.initialUrl);
      await _registerBridge(controller);
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _registerBridge(WebViewController controller) async {
    if (!controller.value) return;
    await controller.setJavaScriptChannels({
      JavascriptChannel(
        name: 'NetOutpostNative',
        onMessageReceived: (message) {
          unawaited(_handleBridgeMessage(message.message));
        },
      ),
    });
  }

  Future<void> _pasteIntoWebView() async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text;
    final controller = _controller;
    if (text == null || text.isEmpty || controller?.value != true) return;

    final encodedText = jsonEncode(text);
    await controller!.executeJavaScript('''
      (() => {
        const element = document.activeElement;
        const text = $encodedText;
        if (!element) return;
        if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
          const start = element.selectionStart ?? element.value.length;
          const end = element.selectionEnd ?? start;
          element.setRangeText(text, start, end, 'end');
          element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
        } else if (element.isContentEditable) {
          document.execCommand('insertText', false, text);
          element.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
        }
      })();
    ''');
  }

  Future<void> _handleBridgeMessage(String rawData) async {
    try {
      final data = jsonDecode(rawData) as Map<String, dynamic>;
      if (data['action'] != 'DOWNLOAD_PACKAGE') return;

      dynamic manifestData = data['manifest'];

      // If manifest wasn't sent directly, but manifest_url was provided, fetch it
      if (manifestData == null && data['manifest_url'] != null) {
        final manifestUrlStr = data['manifest_url'].toString();
        final fullManifestUrl = widget.serverUrl.endsWith('/') && manifestUrlStr.startsWith('/')
            ? widget.serverUrl + manifestUrlStr.substring(1)
            : widget.serverUrl + manifestUrlStr;

        final dio = Dio();
        final response = await dio.get(
          fullManifestUrl,
          options: Options(
            headers: {
              if (_apiKey.isNotEmpty) ...{
                'X-API-Key': _apiKey,
                'Authorization': 'Bearer $_apiKey',
              },
            },
          ),
        );
        manifestData = response.data;
      }

      Map<String, dynamic> manifest;
      if (manifestData is String) {
        manifest = jsonDecode(manifestData);
      } else if (manifestData is Map) {
        manifest = Map<String, dynamic>.from(manifestData);
      } else {
        debugPrint('Linux Bridge Error: manifest is invalid or missing');
        return;
      }

      final packageId = manifest['package_id']?.toString() ?? '';
      if (packageId.isEmpty) {
        debugPrint('Linux Bridge Error: package_id is missing from manifest');
        return;
      }

      final rootUrl = manifest['root_url']?.toString() ?? '';
      final title =
          (manifest['package_title'] ?? manifest['title'] ?? manifest['name'] ?? manifest['package_name'] ?? packageId)
              .toString();

      await _dbHelper.insertPackage(PackageModel(
        id: packageId,
        title: title,
        rootUrl: rootUrl,
        status: 'pending',
        progress: 0,
        date: DateTime.now().toIso8601String(),
      ));

      final resourcesList = (manifest['resources'] as List<dynamic>?) ?? [];
      for (final item in resourcesList) {
        final resource = Map<String, dynamic>.from(item as Map);
        final resUrl = resource['url']?.toString() ?? '';
        final resType = resource['type']?.toString() ?? 'binary';

        if (resUrl.isNotEmpty) {
          await _dbHelper.insertResource(ResourceModel(
            packageId: packageId,
            relativeUrl: resUrl,
            localPath: '',
            type: resType,
          ));
        }
      }

      _downloadService.addToQueue(packageId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Package "$title" added to the download queue.')),
        );
      }
    } catch (e) {
      debugPrint('Linux WebView bridge error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not process the download manifest: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  void _subscribeToDownloads() {
    _progressSubscription = _downloadService.progressStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _activePackageId = event.packageId;
        _downloadProgress = event.progress;
        _downloadStatus = 'downloading';
        _downloadDetails = [event.speed, event.remaining].where((value) => value.isNotEmpty).join('  |  ');
      });
    });
    _statusSubscription = _downloadService.statusStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _activePackageId = event.packageId;
        _downloadStatus = event.status;
        if (event.status == 'completed') _downloadProgress = 1;
      });
    });
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _statusSubscription?.cancel();
    unawaited(_controller?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      appBar: AppBar(
        title: Text(widget.isOfflineMode ? 'Offline Sandbox' : 'NetSanctum Live'),
        actions: [
          IconButton(
            tooltip: 'Back',
            onPressed: controller?.value == true ? controller!.goBack : null,
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
          ),
          IconButton(
            tooltip: 'Reload',
            onPressed: controller?.value == true ? controller!.reload : null,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Paste into focused web field',
            onPressed: controller?.value == true ? _pasteIntoWebView : null,
            icon: const Icon(Icons.content_paste),
          ),
          IconButton(
            tooltip: 'Developer tools',
            onPressed: controller?.value == true ? controller!.openDevTools : null,
            icon: const Icon(Icons.developer_mode),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (_error != null)
            Center(child: SelectableText('WebView failed to start:\n$_error'))
          else if (controller == null)
            const Center(child: CircularProgressIndicator())
          else
            ValueListenableBuilder<bool>(
              valueListenable: controller,
              builder: (context, ready, _) => ready ? controller.webviewWidget : controller.loadingWidget,
            ),
          if (_activePackageId != null)
            Positioned(
              left: 20,
              right: 20,
              bottom: 20,
              child: Card(
                color: const Color(0xF21E293B),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$_activePackageId  |  ${_downloadStatus.toUpperCase()}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(value: _downloadProgress),
                      if (_downloadDetails.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(_downloadDetails),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
