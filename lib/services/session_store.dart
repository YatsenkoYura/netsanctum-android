import 'package:shared_preferences/shared_preferences.dart';

class SessionStore {
  static const _lastLiveUrlKey = 'last_live_url';

  Future<String> restoreLiveUrl(String serverUrl) async {
    final preferences = await SharedPreferences.getInstance();
    final lastUrl = preferences.getString(_lastLiveUrlKey);
    return _hasSameOrigin(serverUrl, lastUrl) ? lastUrl! : serverUrl;
  }

  Future<void> saveLiveUrl(String serverUrl, String url) async {
    if (!_hasSameOrigin(serverUrl, url)) return;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_lastLiveUrlKey, url);
  }

  Future<void> clearLiveUrl() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_lastLiveUrlKey);
  }

  bool hasSameOrigin(String firstUrl, String secondUrl) => _hasSameOrigin(firstUrl, secondUrl);

  bool _hasSameOrigin(String firstUrl, String? secondUrl) {
    if (secondUrl == null) return false;
    final first = Uri.tryParse(firstUrl);
    final second = Uri.tryParse(secondUrl);
    if (first == null || second == null || !first.hasAuthority || !second.hasAuthority) {
      return false;
    }
    return first.scheme == second.scheme && first.host == second.host && first.port == second.port;
  }
}
