import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class NspReader {
  final String filePath;
  Map<String, dynamic> _index = {};
  bool _initialized = false;
  RandomAccessFile? _raf;

  NspReader(this.filePath);

  Future<void> init() async {
    if (_initialized && _raf != null) return;

    final file = File(filePath);
    if (!await file.exists()) {
      throw FileSystemException("NSP file not found", filePath);
    }

    final length = await file.length();
    if (length < 12) {
      throw const FormatException("Invalid NSP file: file too short");
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
        throw const FormatException("Invalid index offset in NSP footer");
      }

      // Read the JSON index
      await raf.setPosition(indexOffset);
      final indexBytes = await raf.read(length - 12 - indexOffset);
      final indexJson = utf8.decode(indexBytes);
      _index = jsonDecode(indexJson) as Map<String, dynamic>;
      _raf = raf;
      _initialized = true;
    } catch (_) {
      await raf.close();
      rethrow;
    }
  }

  Future<RandomAccessFile> _getRaf() async {
    if (!_initialized || _raf == null) {
      await init();
    }
    return _raf!;
  }

  dynamic _findEntry(String path) {
    if (_index.containsKey(path)) {
      return _index[path];
    }

    final hasLeadingSlash = path.startsWith('/');
    final withSlash = hasLeadingSlash ? path : '/$path';
    final withoutSlash = hasLeadingSlash ? path.substring(1) : path;

    if (_index.containsKey(withSlash)) return _index[withSlash];
    if (_index.containsKey(withoutSlash)) return _index[withoutSlash];

    // If the request contains query parameters (e.g. cache-busters like /static/app.css?v=123),
    // check if the stripped path matches an index key that has NO query parameters.
    if (path.contains('?')) {
      final reqPathClean = path.split('?')[0];
      final cleanWithSlash = reqPathClean.startsWith('/') ? reqPathClean : '/$reqPathClean';
      final cleanWithoutSlash = cleanWithSlash.substring(1);

      if (_index.containsKey(cleanWithSlash)) {
        final entry = _index[cleanWithSlash];
        if (!cleanWithSlash.contains('?')) return entry;
      }
      if (_index.containsKey(cleanWithoutSlash)) {
        final entry = _index[cleanWithoutSlash];
        if (!cleanWithoutSlash.contains('?')) return entry;
      }
    }

    return null;
  }

  /// Get total byte length of the resource
  int? getResourceLength(String path) {
    final entry = _findEntry(path);
    if (entry == null) return null;
    return entry['length'] as int?;
  }

  /// Get bytes of the file by its virtual path (URL)
  Future<List<int>?> getResourceBytes(String path) async {
    final entry = _findEntry(path);
    if (entry == null) return null;

    final int offset = entry['offset'];
    final int length = entry['length'];

    final raf = await _getRaf();
    await raf.setPosition(offset);
    return await raf.read(length);
  }

  /// Get byte range of the file for HTTP 206 Partial Content
  Future<List<int>?> getByteRange(String path, int start, int length) async {
    final entry = _findEntry(path);
    if (entry == null) return null;

    final int entryOffset = entry['offset'];
    final int totalLength = entry['length'];

    if (start < 0 || start >= totalLength || length <= 0) {
      return null;
    }

    final readLength = (start + length > totalLength) ? (totalLength - start) : length;
    final raf = await _getRaf();
    await raf.setPosition(entryOffset + start);
    return await raf.read(readLength);
  }

  /// Get Content-Type of the file
  String getMimeType(String path) {
    final entry = _findEntry(path);
    return entry?['mime'] ?? 'application/octet-stream';
  }

  /// Check if path exists in the index
  bool hasResource(String path) {
    return _findEntry(path) != null;
  }

  /// Close underlying file handle
  Future<void> close() async {
    if (_raf != null) {
      try {
        await _raf!.close();
      } catch (_) {}
      _raf = null;
    }
    _initialized = false;
  }
}

