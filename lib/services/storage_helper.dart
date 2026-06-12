import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Resolves the root directory where offline packages are saved.
/// On Android, this resolves to the package's external storage files directory 
/// (`/storage/emulated/0/Android/data/com.example.netoutpost/files`)
/// so that users can manually view or copy cached assets without root access.
/// On other platforms, it falls back to the app documents sandbox directory.
Future<Directory> getCacheDirectory() async {
  if (Platform.isAndroid) {
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        return extDir;
      }
    } catch (e) {
      print('Failed to get external storage directory, falling back to documents: $e');
    }
  }
  return await getApplicationDocumentsDirectory();
}
