import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class NspReader {
  final String filePath;
  Map<String, dynamic> _index = {};
  bool _initialized = false;

  NspReader(this.filePath);

  Future<void> init() async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException("NSP file not found", filePath);
    }
    
    final length = await file.length();
    if (length < 12) {
      throw FormatException("Invalid NSP file: file too short");
    }

    final raf = await file.open(mode: FileMode.read);
    try {
      // Read the last 12 bytes (Footer)
      await raf.setPosition(length - 12);
      final footerBytes = await raf.read(12);
      final bd = ByteData.sublistView(footerBytes);
      
      final indexOffset = bd.getUint64(0, Endian.big);
      final magic = utf8.decode(footerBytes.sublist(8, 12));

      if (magic != "NSPK") {
        throw FormatException("Invalid NSP magic bytes. Expected 'NSPK', got: '$magic'");
      }

      if (indexOffset >= length - 12) {
        throw FormatException("Invalid index offset in NSP footer");
      }

      // Read the JSON index
      await raf.setPosition(indexOffset);
      final indexBytes = await raf.read(length - 12 - indexOffset);
      final indexJson = utf8.decode(indexBytes);
      _index = jsonDecode(indexJson);
      _initialized = true;
    } finally {
      await raf.close();
    }
  }

  /// Get bytes of the file by its virtual path (URL)
  Future<List<int>?> getResourceBytes(String path) async {
    if (!_initialized) await init();
    
    // Try exact match
    var entry = _index[path];
    
    // Normalization fallback (strip leading slash, query params, etc.)
    if (entry == null) {
      final cleanPath = path.contains('?') ? path.split('?')[0] : path;
      entry = _index[cleanPath] ?? _index['/$cleanPath'] ?? _index[path.replaceFirst('/', '')];
    }

    if (entry == null) return null;

    final int offset = entry['offset'];
    final int length = entry['length'];

    final file = File(filePath);
    final raf = await file.open(mode: FileMode.read);
    try {
      await raf.setPosition(offset);
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  /// Get Content-Type of the file
  String getMimeType(String path) {
    var entry = _index[path];
    if (entry == null) {
      final cleanPath = path.contains('?') ? path.split('?')[0] : path;
      entry = _index[cleanPath] ?? _index['/$cleanPath'] ?? _index[path.replaceFirst('/', '')];
    }
    return entry?['mime'] ?? 'application/octet-stream';
  }

  /// Check if path exists in the index
  bool hasResource(String path) {
    final cleanPath = path.contains('?') ? path.split('?')[0] : path;
    return _index.containsKey(path) || 
           _index.containsKey(cleanPath) || 
           _index.containsKey('/$cleanPath') || 
           _index.containsKey(path.replaceFirst('/', ''));
  }
}
