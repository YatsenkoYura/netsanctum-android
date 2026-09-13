import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:netoutpost/services/nsp_reader.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('nsp_test_');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  File buildTestNspFile(String fileName, Map<String, ({List<int> bytes, String mime})> entries) {
    final file = File('${tempDir.path}/$fileName');
    final bytesBuilder = BytesBuilder();
    final index = <String, dynamic>{};
    int currentOffset = 0;

    for (var entry in entries.entries) {
      final content = entry.value.bytes;
      bytesBuilder.add(content);
      index[entry.key] = {
        'offset': currentOffset,
        'length': content.length,
        'mime': entry.value.mime,
        'sha256': 'mock_sha256',
      };
      currentOffset += content.length;
    }

    final indexJson = utf8.encode(jsonEncode(index));
    bytesBuilder.add(indexJson);

    // 8-byte big-endian offset of index, followed by 4-byte magic 'NSPK'
    final footer = ByteData(12);
    footer.setUint64(0, currentOffset, Endian.big);
    footer.setUint8(8, 0x4E); // 'N'
    footer.setUint8(9, 0x53); // 'S'
    footer.setUint8(10, 0x50); // 'P'
    footer.setUint8(11, 0x4B); // 'K'
    bytesBuilder.add(footer.buffer.asUint8List());

    file.writeAsBytesSync(bytesBuilder.toBytes());
    return file;
  }

  test('NspReader correctly initializes and reads index & entries', () async {
    final htmlContent = utf8.encode('<html><body>Dashboard</body></html>');
    final cssContent = utf8.encode('body { color: red; }');
    final song1Content = utf8.encode('{"id": 1, "title": "Song 1"}');

    final nspFile = buildTestNspFile('test_package.nsp', {
      '/music/dashboard?package_id=song_1': (bytes: htmlContent, mime: 'text/html; charset=utf-8'),
      '/static/tailwind.css': (bytes: cssContent, mime: 'text/css; charset=utf-8'),
      '/music/api/songs?package_id=song_1': (bytes: song1Content, mime: 'application/json'),
    });

    final reader = NspReader(nspFile.path);
    await reader.init();

    expect(reader.hasResource('/music/dashboard?package_id=song_1'), isTrue);
    expect(reader.hasResource('/static/tailwind.css'), isTrue);
    expect(reader.hasResource('/static/tailwind.css?v=123'), isTrue);
    expect(reader.hasResource('/music/api/songs?package_id=song_1'), isTrue);

    // Negative tests
    expect(reader.hasResource('/music/api/songs?package_id=song_2'), isFalse);
    expect(reader.hasResource('/nonexistent'), isFalse);

    // Byte reads
    final readHtml = await reader.getResourceBytes('/music/dashboard?package_id=song_1');
    expect(readHtml, isNotNull);
    expect(utf8.decode(readHtml!), '<html><body>Dashboard</body></html>');

    // Mime types
    expect(reader.getMimeType('/static/tailwind.css'), 'text/css; charset=utf-8');
    expect(reader.getMimeType('/music/dashboard?package_id=song_1'), 'text/html; charset=utf-8');

    await reader.close();
  });

  test('NspReader supports HTTP 206 partial range reads', () async {
    final rawData = List<int>.generate(100, (i) => i);
    final nspFile = buildTestNspFile('range_test.nsp', {
      '/video/stream.mp4': (bytes: rawData, mime: 'video/mp4'),
    });

    final reader = NspReader(nspFile.path);
    await reader.init();

    expect(reader.getResourceLength('/video/stream.mp4'), 100);

    // Read range 0-9 (10 bytes)
    final chunk1 = await reader.getByteRange('/video/stream.mp4', 0, 10);
    expect(chunk1, isNotNull);
    expect(chunk1!.length, 10);
    expect(chunk1, List<int>.generate(10, (i) => i));

    // Read range 50-69 (20 bytes)
    final chunk2 = await reader.getByteRange('/video/stream.mp4', 50, 20);
    expect(chunk2, isNotNull);
    expect(chunk2!.length, 20);
    expect(chunk2, List<int>.generate(20, (i) => 50 + i));

    await reader.close();
  });
}
