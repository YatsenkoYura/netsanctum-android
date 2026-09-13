import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/credential_store.dart';
import '../services/session_store.dart';
import '../services/storage_helper.dart';

const Color slateColor = Color(0xFF94A3B8);

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final CredentialStore _credentialStore = CredentialStore();
  final SessionStore _sessionStore = SessionStore();

  bool _isStorageGranted = false;
  final bool _isNetworkGranted = true; // Implicit on Android, but good to show
  bool _obscureApiKey = true;

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
    String apiKey = '';
    try {
      apiKey = await _credentialStore.readMasterKey();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Secure storage is unavailable: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _urlController.text = prefs.getString('server_url') ?? '';
      _apiKeyController.text = apiKey;
    });
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final previousServerUrl = prefs.getString('server_url') ?? '';
      // Trim URL to prevent spaces
      String serverUrl = _urlController.text.trim();
      // Ensure trailing slash is removed for clean concatenations later
      if (serverUrl.endsWith('/')) {
        serverUrl = serverUrl.substring(0, serverUrl.length - 1);
      }

      await _credentialStore.writeMasterKey(_apiKeyController.text);
      await prefs.setString('server_url', serverUrl);
      if (!_sessionStore.hasSameOrigin(previousServerUrl, serverUrl)) {
        await _sessionStore.clearLiveUrl();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not save the master key securely: $e'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Settings saved successfully!'),
        backgroundColor: Colors.teal,
      ),
    );
    Navigator.of(context).pop(true); // Return success to trigger dashboard refresh
  }

  Future<void> _pasteInto(TextEditingController controller) async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text;
    if (text == null || text.isEmpty) return;

    final selection = controller.selection;
    final start = selection.isValid ? selection.start : controller.text.length;
    final end = selection.isValid ? selection.end : controller.text.length;
    final updated = controller.text.replaceRange(start, end, text);
    controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
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
      debugPrint('Sandbox check failed: $e');
    }

    final isGranted = Platform.isAndroid ? (await Permission.storage.status).isGranted || canWrite : canWrite;

    if (!mounted) return;
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
      if (mounted) {
        setState(() {
          _isStorageGranted = true;
        });
      }
      return;
    } catch (_) {}

    if (!Platform.isAndroid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('The application data directory is not writable.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    Map<Permission, PermissionStatus> statuses = await [
      Permission.storage,
    ].request();

    if (!mounted) return;
    setState(() {
      _isStorageGranted = statuses[Permission.storage]?.isGranted ?? false;
    });

    if (!_isStorageGranted && mounted) {
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
                  suffixIcon: IconButton(
                    tooltip: 'Paste',
                    onPressed: () => _pasteInto(_urlController),
                    icon: const Icon(Icons.content_paste),
                  ),
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
                obscureText: _obscureApiKey,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Master API Key',
                  labelStyle: const TextStyle(color: slateColor),
                  hintText: 'Enter API authorization key',
                  hintStyle: const TextStyle(color: slateColor),
                  prefixIcon: const Icon(Icons.key, color: Colors.blueAccent),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Paste',
                        onPressed: () => _pasteInto(_apiKeyController),
                        icon: const Icon(Icons.content_paste),
                      ),
                      IconButton(
                        tooltip: _obscureApiKey ? 'Show key' : 'Hide key',
                        onPressed: () => setState(() => _obscureApiKey = !_obscureApiKey),
                        icon: Icon(_obscureApiKey ? Icons.visibility : Icons.visibility_off),
                      ),
                    ],
                  ),
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
            color: isGranted ? Colors.teal.withValues(alpha: 0.2) : Colors.redAccent.withValues(alpha: 0.2),
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
