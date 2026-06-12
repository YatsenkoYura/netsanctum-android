# NetOutpost: Module-Agnostic Offline Companion App

NetOutpost is a lightweight companion mobile application designed to complement **NetSanctum** (a FastAPI-based self-hosted media registry and downloader).

It acts as a generic "smart offline browser" with **zero hardcoded UI or business logic** for specific content types (e.g., books, videos, music). Instead, it implements a dynamic runtime shell that intercepts HTTP traffic and serves cached assets locally when offline.

---

## Architecture & Features

### Core Principle: Smart Hybrid Caching Proxy
1. **Online Mode**: The app loads NetSanctum's web interface in a fullscreen WebView, appending authorization headers (`X-API-Key`).
2. **Synchronisation (JS Bridge)**: The web app posts a standardized JSON **Sync Manifest** to the WebView's JS Bridge containing resource paths to cache. The native Dart layer downloads these files sequentially and registers them in a local SQLite database.
3. **Offline Mode**: When offline, the WebView is redirected to a local HTTP server running on `http://localhost:9000`. It acts as an interceptor. All API fetches made by the webapp resolve to this local endpoint.
4. **Partial Content (HTTP 206)**: The local HTTP server supports range-requests for binary media (`type: "binary"` like `.mp4`), enabling smooth video playback, seeking, and scrubbing inside the WebView.

---

## DB Schema (SQLite)

### `packages`
* `id` (TEXT PRIMARY KEY) - The package identifier (e.g., `ranobe_overlord_v1`).
* `root_url` (TEXT) - The view entry point (e.g., `/ranobelib/reader/overlord`).
* `status` (TEXT) - Current status (`pending`, `downloading`, `completed`, `failed`).
* `progress` (REAL) - Fractional progress (`0.0` to `1.0`).
* `date` (TEXT) - Creation date/time timestamp.

### `resources`
* `id` (INTEGER PRIMARY KEY AUTOINCREMENT)
* `package_id` (TEXT) - Foreign key referencing `packages(id)`.
* `relative_url` (TEXT) - Intercepted URL relative path (e.g., `/api/novels`).
* `local_path` (TEXT) - Absolute storage path of downloaded asset.
* `type` (TEXT) - Resource format type (`json`, `image`, `binary`).

---

## Communication Contract (JS Bridge)

NetSanctum communicates with NetOutpost via the bridge channel:
* standard web bridge: `window.NetOutpostBridge.postMessage(JSON.stringify(payload))`
* flutter inappwebview bridge: `window.flutter_inappwebview.callHandler('NetOutpostBridge', payload)`

### Download Package Payload
```json
{
  "action": "DOWNLOAD_PACKAGE",
  "manifest": {
    "package_id": "video_123",
    "root_url": "/video-archiver/dashboard",
    "resources": [
      { "url": "/api/video-archiver/videos", "type": "json" },
      { "url": "/api/video-archiver/videos/123", "type": "json" },
      { "url": "/api/video-archiver/videos/123/stream", "type": "binary" },
      { "url": "/api/video-archiver/videos/123/thumbnail", "type": "image" }
    ]
  }
}
```

---

## Project Structure

```text
lib/
├── main.dart                      # App entry point & theme
├── database/
│   └── db_helper.dart             # SQLite DB manager
├── models/
│   ├── package_model.dart         # Package entity model
│   └── resource_model.dart        # Resource entity model
├── services/
│   ├── download_service.dart      # Sequential background download agent
│   └── local_server_service.dart  # Shelf-based localhost:9000 server with HTTP 206
└── screens/
    ├── dashboard_screen.dart      # UI Home - connection status, local server controls, package lists
    ├── settings_screen.dart       # Form setup - Server URL, API Key, android permission checklist
    └── webview_screen.dart        # WebView container with JS Bridge listeners & auth injection
```

---

## Requirements & Setup

### 1. Flutter SDK Install
Ensure the Flutter SDK is installed on your machine. Run `flutter doctor` to verify setup.

### 2. Configure Local Properties
Create a file named `local.properties` inside the `android/` directory and specify your Flutter SDK path:
```properties
flutter.sdk=/path/to/your/flutter/sdk
```

### 3. Install Dependencies
Run from the root of the project:
```bash
flutter pub get
```

### 4. Running the App
Ensure a physical Android device or emulator is connected:
```bash
flutter run
```

---

## Permissions Configured (Android)

* **Internet & Network State**: Defined in `AndroidManifest.xml` to allow the WebView to load remote server URLs and check wifi/cellular status.
* **Storage Access**: Requested dynamically in the Settings Screen via the `permission_handler` package to write offline packages inside the app documentation directory.
* **Cleartext Traffic**: Enabled via `android:usesCleartextTraffic="true"` in the manifest, letting the WebView fetch from the local `http://localhost:9000` HTTP proxy and self-hosted non-SSL development servers.
