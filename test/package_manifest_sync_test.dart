import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:netoutpost/models/package_model.dart';
import 'package:netoutpost/models/resource_model.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('PackageModel serialization & deserialization', () {
    final pkg = PackageModel(
      id: 'video_100',
      title: 'Video 100',
      rootUrl: '/video-archiver/dashboard?package_id=video_100',
      status: 'completed',
      progress: 1.0,
      date: '2026-09-13T12:00:00Z',
    );

    final map = pkg.toMap();
    expect(map['id'], 'video_100');
    expect(map['title'], 'Video 100');
    expect(map['root_url'], '/video-archiver/dashboard?package_id=video_100');
    expect(map['status'], 'completed');
    expect(map['progress'], 1.0);

    final restored = PackageModel.fromMap(map);
    expect(restored.id, pkg.id);
    expect(restored.title, pkg.title);
    expect(restored.rootUrl, pkg.rootUrl);
    expect(restored.status, pkg.status);
    expect(restored.progress, pkg.progress);
  });

  test('ResourceModel serialization & deserialization', () {
    final res = ResourceModel(
      id: 1,
      packageId: 'video_100',
      relativeUrl: '/api/video-archiver/videos/100/stream',
      localPath: '/data/offline_cache/video_100.bin',
      type: 'binary',
    );

    final map = res.toMap();
    expect(map['package_id'], 'video_100');
    expect(map['relative_url'], '/api/video-archiver/videos/100/stream');
    expect(map['local_path'], '/data/offline_cache/video_100.bin');
    expect(map['type'], 'binary');

    final restored = ResourceModel.fromMap(map);
    expect(restored.packageId, res.packageId);
    expect(restored.relativeUrl, res.relativeUrl);
    expect(restored.localPath, res.localPath);
    expect(restored.type, res.type);
  });

  test('SQLite database operations with UNIQUE resource constraint and cascade delete', () async {
    final db = await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 3,
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE packages (
              id TEXT PRIMARY KEY,
              title TEXT,
              root_url TEXT,
              status TEXT,
              progress REAL DEFAULT 0.0,
              date TEXT
            )
          ''');

          await db.execute('''
            CREATE TABLE resources (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              package_id TEXT,
              relative_url TEXT,
              local_path TEXT,
              type TEXT,
              FOREIGN KEY (package_id) REFERENCES packages (id) ON DELETE CASCADE,
              UNIQUE (package_id, relative_url)
            )
          ''');
        },
      ),
    );

    // Insert package
    await db.insert('packages', {
      'id': 'novel_1',
      'title': 'Overlord',
      'root_url': '/alllib/reader/1?package_id=novel_1',
      'status': 'pending',
      'progress': 0.0,
      'date': DateTime.now().toIso8601String(),
    });

    // Insert resources
    await db.insert('resources', {
      'package_id': 'novel_1',
      'relative_url': '/alllib/ui/chapter/1?package_id=novel_1',
      'local_path': '',
      'type': 'html',
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    // Re-insert same resource (deduplication check)
    await db.insert('resources', {
      'package_id': 'novel_1',
      'relative_url': '/alllib/ui/chapter/1?package_id=novel_1',
      'local_path': '/cache/chapter1.html',
      'type': 'html',
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    final resList = await db.query('resources', where: 'package_id = ?', whereArgs: ['novel_1']);
    expect(resList.length, 1);
    expect(resList.first['local_path'], '/cache/chapter1.html');

    // Cascade delete test
    await db.delete('packages', where: 'id = ?', whereArgs: ['novel_1']);
    final remainingRes = await db.query('resources', where: 'package_id = ?', whereArgs: ['novel_1']);
    expect(remainingRes, isEmpty);

    await db.close();
  });

  test('Bridge manifest payload structure parsing verification', () {
    final rawBridgePayload = jsonEncode({
      'action': 'DOWNLOAD_PACKAGE',
      'contract_version': 1,
      'manifest_url': '/api/video-archiver/videos/55/sync-manifest',
      'manifest': {
        'schema_version': 1,
        'package_id': 'video_55',
        'package_title': 'Video 55: Cool Video',
        'module': {
          'id': 'video_archiver',
          'title': 'Video Archiver',
          'root_url': '/video-archiver/dashboard'
        },
        'root_url': '/video-archiver/dashboard?package_id=video_55',
        'resources': [
          {'url': '/api/video-archiver/videos/55/stream', 'type': 'binary'},
          {'url': '/api/packages/video_55/nsp', 'type': 'container'}
        ]
      }
    });

    final decoded = jsonDecode(rawBridgePayload) as Map<String, dynamic>;
    expect(decoded['action'], 'DOWNLOAD_PACKAGE');
    expect(decoded['contract_version'], 1);

    final manifest = decoded['manifest'] as Map<String, dynamic>;
    expect(manifest['package_id'], 'video_55');
    expect(manifest['package_title'], 'Video 55: Cool Video');
    expect(manifest['resources'].length, 2);
    expect(manifest['resources'][1]['type'], 'container');
  });
}
