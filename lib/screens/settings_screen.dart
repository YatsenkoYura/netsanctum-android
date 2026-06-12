import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/storage_helper.dart';

const Color slateColor = Color(0xFF94A3B8);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({Key? key}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _apiKeyController = TextEditingController();

  bool _isStorageGranted = false;
  bool _isNetworkGranted = true; // Implicit on Android, but good to show

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _checkPermissions();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _urlController.text = prefs.getString('server_url') ?? '';
      _apiKeyController.text = prefs.getString('api_key') ?? '';
    });
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;

    final prefs = await SharedPreferences.getInstance();
    // Trim URL to prevent spaces
    String serverUrl = _urlController.text.trim();
    // Ensure trailing slash is removed for clean concatenations later
    if (serverUrl.endsWith('/')) {
      serverUrl = serverUrl.substring(0, serverUrl.length - 1);
    }
    
    await prefs.setString('server_url', serverUrl);
    await prefs.setString('api_key', _apiKeyController.text.trim());

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Settings saved successfully!'),
        backgroundColor: Colors.teal,
      ),
    );
    Navigator.of(context).pop(true); // Return success to trigger dashboard refresh
  }

  Future<void> _checkPermissions() async {
    bool canWrite = false;
    try {
      final appDocDir = await getCacheDirectory();
      final testFile = File('${appDocDir.path}/.permission_test');
      await testFile.writeAsString('test');
      await testFile.delete();
      canWrite = true;
    } catch (e) {
      print('Sandbox check failed: $e');
    }

    final storageStatus = await Permission.storage.status;
    final isGranted = storageStatus.isGranted || canWrite;

    setState(() {
      _isStorageGranted = isGranted;
    });
  }

  Future<void> _requestPermissions() async {
    try {
      final appDocDir = await getCacheDirectory();
      final testFile = File('${appDocDir.path}/.permission_test');
      await testFile.writeAsString('test');
      await testFile.delete();
      setState(() {
        _isStorageGranted = true;
      });
      return;
    } catch (_) {}

    Map<Permission, PermissionStatus> statuses = await [
      Permission.storage,
    ].request();

    setState(() {
      _isStorageGranted = statuses[Permission.storage]?.isGranted ?? false;
    });

    if (!_isStorageGranted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Storage permission is required to save packages offline.'),
          backgroundColor: Colors.orange,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F172A), // Slate 900
      appBar: AppBar(
        title: const Text('Server Configuration'),
        backgroundColor: const Color(0xFF1E293B), // Slate 800
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Server URL Setup
              const Text(
                'CONNECTION SETTINGS',
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 15),
              TextFormField(
                controller: _urlController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'NetSanctum Server URL',
                  labelStyle: const TextStyle(color: slateColor),
                  hintText: 'e.g. http://192.168.1.100:8000',
                  hintStyle: const TextStyle(color: slateColor),
                  prefixIcon: const Icon(Icons.dns, color: Colors.blueAccent),
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  enabledBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF334155)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Colors.blueAccent, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Colors.redAccent),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter the server URL';
                  }
                  final uri = Uri.tryParse(value);
                  if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
                    return 'Please enter a valid URL (e.g. http://...)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 20),

              // API Key
              TextFormField(
                controller: _apiKeyController,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Master API Key',
                  labelStyle: const TextStyle(color: slateColor),
                  hintText: 'Enter API authorization key',
                  hintStyle: const TextStyle(color: slateColor),
                  prefixIcon: const Icon(Icons.key, color: Colors.blueAccent),
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  enabledBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Color(0xFF334155)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderSide: const BorderSide(color: Colors.blueAccent, width: 2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 40),

              // Permissions Status
              const Text(
                'DEVICE PERMISSIONS',
                style: TextStyle(
                  color: Colors.blueAccent,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 15),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF334155)),
                ),
                padding: const EdgeInsets.all(15),
                child: Column(
                  children: [
                    _buildPermissionRow(
                      icon: Icons.folder,
                      title: 'Local Sandbox Storage',
                      subtitle: 'Offline storage space (active, no OS prompt required)',
                      isGranted: _isStorageGranted,
                    ),
                    const Divider(color: Color(0xFF334155), height: 20),
                    _buildPermissionRow(
                      icon: Icons.wifi,
                      title: 'Network Communication',
                      subtitle: 'Required to access Server URL',
                      isGranted: _isNetworkGranted,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (!_isStorageGranted)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _requestPermissions,
                    icon: const Icon(Icons.security),
                    label: const Text('Grant Storage Permission'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.indigo,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 40),

              // Save Button
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _saveSettings,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 4,
                  ),
                  child: const Text(
                    'Save Configuration',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPermissionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool isGranted,
  }) {
    return Row(
      children: [
        Icon(icon, color: slateColor, size: 28),
        const SizedBox(width: 15),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
              Text(
                subtitle,
                style: const TextStyle(color: slateColor, fontSize: 12),
              ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            color: isGranted ? Colors.teal.withOpacity(0.2) : Colors.redAccent.withOpacity(0.2),
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Text(
            isGranted ? 'Granted' : 'Missing',
            style: TextStyle(
              color: isGranted ? Colors.teal : Colors.redAccent,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
