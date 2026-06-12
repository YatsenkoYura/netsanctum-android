import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:intl/intl.dart';
import '../database/db_helper.dart';
import '../models/package_model.dart';
import '../services/download_service.dart';
import '../services/local_server_service.dart';
import '../services/storage_helper.dart';
import 'webview_screen.dart';
import 'settings_screen.dart';

const Color slateColor = Color(0xFF94A3B8);

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final DBHelper _dbHelper = DBHelper();
  final DownloadService _downloadService = DownloadService();
  final LocalServerService _localServer = LocalServerService();
  
  List<PackageModel> _packages = [];
  bool _isLoading = true;
  String _serverUrl = '';
  String _apiKey = '';
  
  bool _isOnline = false;
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;

  // Track real-time progress for active package downloads
  final Map<String, double> _downloadProgressMap = {};

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _loadPackages();
    _startLocalServer();
    _initConnectivity();
    _setupDownloadCallbacks();
  }

  @override
  void dispose() {
    _connectivitySubscription.cancel();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _serverUrl = prefs.getString('server_url') ?? '';
      _apiKey = prefs.getString('api_key') ?? '';
    });
  }

  Future<void> _loadPackages() async {
    setState(() => _isLoading = true);
    final packages = await _dbHelper.getAllPackages();
    setState(() {
      _packages = packages;
      _isLoading = false;
    });
  }

  Future<void> _startLocalServer() async {
    if (!_localServer.isRunning) {
      await _localServer.start();
    }
  }

  Future<void> _initConnectivity() async {
    final connectivity = Connectivity();
    // Get initial state
    final results = await connectivity.checkConnectivity();
    _updateConnectionStatus(results);

    // Subscribe to changes
    _connectivitySubscription = connectivity.onConnectivityChanged.listen(_updateConnectionStatus);
  }

  void _updateConnectionStatus(List<ConnectivityResult> results) {
    // If list contains anything other than none, we are online
    final isConnected = results.any((result) => result != ConnectivityResult.none);
    setState(() {
      _isOnline = isConnected;
    });
  }

  void _setupDownloadCallbacks() {
    _downloadService.onProgressUpdate = (packageId, progress) {
      setState(() {
        _downloadProgressMap[packageId] = progress;
      });
    };

    _downloadService.onStatusUpdate = (packageId, status) {
      _loadPackages(); // Reload packages list to refresh statuses
      if (status == 'completed' || status == 'failed') {
        setState(() {
          _downloadProgressMap.remove(packageId);
        });
      }
    };
  }

  void _openWebView({String? offlineRootUrl}) {
    if (offlineRootUrl != null) {
      // Offline Mode: Load WebView pointing to the local proxy HTTP server
      final localUrl = 'http://localhost:9000$offlineRootUrl';
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => WebViewScreen(
            initialUrl: localUrl,
            isOfflineMode: true,
          ),
        ),
      ).then((_) => _loadPackages());
    } else {
      // Online Mode: Load WebView pointing to the remote server
      if (_serverUrl.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please configure the Server URL first.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => WebViewScreen(
            initialUrl: _serverUrl,
            isOfflineMode: false,
          ),
        ),
      ).then((_) => _loadPackages());
    }
  }

  Future<void> _deletePackage(String packageId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('Delete Package', style: TextStyle(color: Colors.white)),
        content: Text('Are you sure you want to delete package "$packageId" and all its offline resources?',
            style: const TextStyle(color: slateColor)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: slateColor)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _dbHelper.deletePackage(packageId);
      // Delete local directory
      // The local_server has absolute path in resource.local_path, we can get directory from it or from documents directory
      // We will do clean-up inside _dbHelper but let's also delete folders:
      try {
        final appDocDir = await getCacheDirectory();
        final packageDir = Directory('${appDocDir.path}/packages/$packageId');
        if (await packageDir.exists()) {
          await packageDir.delete(recursive: true);
        }
      } catch (e) {
        print('Error deleting package directory: $e');
      }
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Deleted package $packageId')),
      );
      _loadPackages();
    }
  }

  @override
  Widget build(BuildContext context) {
    // Separate completed and non-completed packages
    final completed = _packages.where((p) => p.status == 'completed').toList();
    final nonCompleted = _packages.where((p) => p.status != 'completed').toList();

    // Grouping completed packages by module
    final Map<String, List<PackageModel>> groups = {};
    for (var pkg in completed) {
      final cleanUrl = pkg.rootUrl.startsWith('/') ? pkg.rootUrl : '/${pkg.rootUrl}';
      final parts = cleanUrl.split('/');
      String moduleKey = 'system';
      if (parts.length > 1 && parts[1].isNotEmpty) {
        moduleKey = parts[1];
      }
      if (!groups.containsKey(moduleKey)) {
        groups[moduleKey] = [];
      }
      groups[moduleKey]!.add(pkg);
    }

    final List<ModuleGroup> moduleGroups = [];
    groups.forEach((moduleKey, pkgs) {
      String displayName = moduleKey;
      if (moduleKey == 'ranobelib') {
        displayName = 'RanobeLib';
      } else if (moduleKey == 'video-archiver') {
        displayName = 'Video Archiver';
      } else if (moduleKey == 'music') {
        displayName = 'Music';
      } else {
        if (moduleKey.isNotEmpty) {
          displayName = moduleKey[0].toUpperCase() + moduleKey.substring(1);
        }
      }
      
      moduleGroups.add(ModuleGroup(
        name: displayName,
        dashboardUrl: '/$moduleKey/dashboard',
        completedPackages: pkgs,
      ));
    });

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Slate 900
      appBar: AppBar(
        title: const Text('NetOutpost Companion'),
        backgroundColor: const Color(0xFF1E293B), // Slate 800
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: () async {
              final result = await Navigator.of(context).push(
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
              if (result == true) {
                _loadConfig();
              }
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Panel Card
            _buildStatusPanel(),
            const SizedBox(height: 20),

            // Online Entry Button
            ElevatedButton.icon(
              onPressed: _isOnline ? () => _openWebView() : null,
              icon: const Icon(Icons.language, size: 24),
              label: const Text('CONNECT LIVE WEB VIEW', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: slateColor.withValues(alpha: 0.1),
                disabledForegroundColor: slateColor,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 4,
              ),
            ),
            const SizedBox(height: 30),

            // Packages Header
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'OFFLINE CACHED PACKAGES',
                  style: TextStyle(
                    color: Colors.blueAccent,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    fontSize: 12,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh, color: slateColor, size: 20),
                  onPressed: _loadPackages,
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Packages List
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _packages.isEmpty
                      ? _buildEmptyState()
                      : ListView(
                          children: [
                            if (nonCompleted.isNotEmpty) ...[
                              const Padding(
                                padding: EdgeInsets.only(bottom: 10.0, top: 4.0),
                                child: Text(
                                  'ACTIVE SYNCING',
                                  style: TextStyle(
                                    color: Colors.amber,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              ...nonCompleted.map((pkg) => _buildPackageCard(pkg)),
                              const SizedBox(height: 16),
                            ],
                            if (moduleGroups.isNotEmpty) ...[
                              const Padding(
                                padding: EdgeInsets.only(bottom: 10.0, top: 4.0),
                                child: Text(
                                  'OFFLINE MODULES',
                                  style: TextStyle(
                                    color: Colors.blueAccent,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.2,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              ...moduleGroups.map((group) => _buildModuleGroupCard(group)),
                            ],
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPanel() {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF334155)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'CONNECTION STATUS',
                style: TextStyle(color: slateColor, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              Container(
                decoration: BoxDecoration(
                  color: _isOnline ? Colors.teal.withValues(alpha: 0.2) : Colors.amber.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircleAvatar(
                      radius: 4,
                      backgroundColor: _isOnline ? Colors.teal : Colors.amber,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _isOnline ? 'ONLINE' : 'OFFLINE',
                      style: TextStyle(
                        color: _isOnline ? Colors.teal : Colors.amber,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              const Icon(Icons.link, color: slateColor, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _serverUrl.isNotEmpty ? _serverUrl : 'Not Configured',
                  style: TextStyle(
                    color: _serverUrl.isNotEmpty ? Colors.white : Colors.redAccent,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Divider(color: Color(0xFF334155), height: 25),
          Row(
            children: [
              const Icon(Icons.lan, color: slateColor, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Local Server Interceptor (Port 9000)',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: const Text(
                  'RUNNING',
                  style: TextStyle(color: Colors.teal, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off, size: 60, color: slateColor.withValues(alpha: 0.4)),
          const SizedBox(height: 15),
          const Text(
            'No Cached Packages Found',
            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 30),
            child: Text(
              'Connect to NetSanctum online and start syncing content to download files for offline reading/playback.',
              textAlign: TextAlign.center,
              style: TextStyle(color: slateColor, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModuleGroupCard(ModuleGroup group) {
    return Card(
      color: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xFF334155), width: 1),
      ),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.folder_special, color: Colors.blueAccent, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        group.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: const Text(
                    'OFFLINE READY',
                    style: TextStyle(color: Colors.teal, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text(
              'DOWNLOADED CONTENT:',
              style: TextStyle(color: slateColor, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
            ),
            const SizedBox(height: 6),
            ...group.completedPackages.map((pkg) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4.0),
              child: Row(
                children: [
                  const Icon(Icons.check_circle_outline, color: Colors.teal, size: 14),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      pkg.title,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 16),
                    onPressed: () => _deletePackage(pkg.id),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            )).toList(),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => _openWebView(offlineRootUrl: group.dashboardUrl),
                icon: const Icon(Icons.offline_bolt_outlined, size: 20),
                label: const Text(
                  'OPEN OFFLINE MODULE',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPackageCard(PackageModel package) {
    final progress = _downloadProgressMap[package.id] ?? package.progress;
    final isSyncing = package.status == 'downloading';
    final isCompleted = package.status == 'completed';
    final isFailed = package.status == 'failed';

    Color statusColor = Colors.grey;
    if (isSyncing) statusColor = Colors.amber;
    else if (isCompleted) statusColor = Colors.teal;
    else if (isFailed) statusColor = Colors.redAccent;

    // Formatting date
    String formattedDate = '';
    try {
      final dt = DateTime.parse(package.date);
      formattedDate = DateFormat('dd MMM yyyy, HH:mm').format(dt);
    } catch (_) {
      formattedDate = package.date;
    }

    return Card(
      color: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: const Color(0xFF334155), width: isSyncing ? 1.5 : 1),
      ),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(15.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        package.title,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'ID: ${package.id} • Root: ${package.rootUrl}',
                        style: const TextStyle(color: slateColor, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  child: Text(
                    package.status.toUpperCase(),
                    style: TextStyle(color: statusColor, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),

            // Progress Bar for syncing or failed/completed states
            if (isSyncing || isFailed || isCompleted) ...[
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress,
                        backgroundColor: const Color(0xFF0F172A),
                        valueColor: AlwaysStoppedAnimation<Color>(statusColor),
                        minHeight: 6,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${(progress * 100).toStringAsFixed(0)}%',
                    style: TextStyle(color: statusColor, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 15),
            ],

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formattedDate,
                  style: const TextStyle(color: slateColor, fontSize: 11),
                ),
                Row(
                  children: [
                    if (isSyncing)
                      IconButton(
                        icon: const Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 22),
                        tooltip: 'Cancel Download',
                        onPressed: () => _downloadService.cancelDownload(package.id),
                      ),
                    if (isCompleted)
                      ElevatedButton.icon(
                        onPressed: () => _openWebView(offlineRootUrl: package.rootUrl),
                        icon: const Icon(Icons.offline_bolt, size: 16),
                        label: const Text('Browse Offline'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.teal,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: slateColor, size: 22),
                      tooltip: 'Delete Package',
                      onPressed: () => _deletePackage(package.id),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class ModuleGroup {
  final String name;
  final String dashboardUrl;
  final List<PackageModel> completedPackages;

  ModuleGroup({
    required this.name,
    required this.dashboardUrl,
    required this.completedPackages,
  });
}
