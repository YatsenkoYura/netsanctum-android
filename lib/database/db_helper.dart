import 'dart:async';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/package_model.dart';
import '../models/resource_model.dart';

class DBHelper {
  static final DBHelper _instance = DBHelper._internal();
  factory DBHelper() => _instance;
  DBHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB();
    return _database!;
  }

  Future<Database> _initDB() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'netoutpost.db');

    return await openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
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
        FOREIGN KEY (package_id) REFERENCES packages (id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      try {
        await db.execute('ALTER TABLE packages ADD COLUMN title TEXT');
      } catch (e) {
        print('Database migration error: $e');
      }
    }
  }

  // Packages CRUD
  Future<void> insertPackage(PackageModel package) async {
    final db = await database;
    await db.insert(
      'packages',
      package.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<PackageModel>> getAllPackages() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('packages', orderBy: 'date DESC');
    return List.generate(maps.length, (i) => PackageModel.fromMap(maps[i]));
  }

  Future<PackageModel?> getPackage(String id) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'packages',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return PackageModel.fromMap(maps.first);
  }

  Future<void> updatePackageStatus(String id, String status, {double? progress}) async {
    final db = await database;
    final values = <String, dynamic>{'status': status};
    if (progress != null) {
      values['progress'] = progress;
    }
    await db.update(
      'packages',
      values,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deletePackage(String id) async {
    final db = await database;
    
    // 1. Fetch all resources of this package before deleting
    final List<Map<String, dynamic>> resourceMaps = await db.query(
      'resources',
      where: 'package_id = ?',
      whereArgs: [id],
    );
    final resources = List.generate(resourceMaps.length, (i) => ResourceModel.fromMap(resourceMaps[i]));
    
    // 2. Delete package and resources from DB
    await db.delete('packages', where: 'id = ?', whereArgs: [id]);
    await db.delete('resources', where: 'package_id = ?', whereArgs: [id]);
    
    // 3. For each resource, check if it's still referenced by any other package.
    // If not, delete the file on disk!
    for (var res in resources) {
      if (res.localPath.isNotEmpty) {
        final List<Map<String, dynamic>> otherRefs = await db.query(
          'resources',
          where: 'local_path = ?',
          whereArgs: [res.localPath],
          limit: 1,
        );
        if (otherRefs.isEmpty) {
          try {
            final file = File(res.localPath);
            if (await file.exists()) {
              await file.delete();
            }
          } catch (e) {
            print('Error deleting unreferenced resource file: $e');
          }
        }
      }
    }
  }

  // Resources CRUD
  Future<void> insertResource(ResourceModel resource) async {
    final db = await database;
    await db.insert(
      'resources',
      resource.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<ResourceModel>> getResourcesForPackage(String packageId) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'resources',
      where: 'package_id = ?',
      whereArgs: [packageId],
    );
    return List.generate(maps.length, (i) => ResourceModel.fromMap(maps[i]));
  }

  Future<ResourceModel?> getResourceByUrl(String relativeUrl) async {
    final db = await database;
    // Strip trailing slashes or query parameters if needed, but standard URL lookup first
    final List<Map<String, dynamic>> maps = await db.query(
      'resources',
      where: 'relative_url = ?',
      whereArgs: [relativeUrl],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return ResourceModel.fromMap(maps.first);
  }
}
