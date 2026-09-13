import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CredentialStore {
  static const _legacyKeyName = 'api_key';
  static const _androidChannel = MethodChannel('com.example.netoutpost/credentials');

  Future<String> readMasterKey() async {
    String? storedKey;
    if (Platform.isAndroid) {
      storedKey = await _androidChannel.invokeMethod<String>('read');
    } else if (Platform.isLinux) {
      storedKey = await _readLinuxCredential();
    } else {
      throw UnsupportedError('Secure credential storage is not implemented on this platform.');
    }
    if (storedKey != null) return storedKey;

    final preferences = await SharedPreferences.getInstance();
    final legacyKey = preferences.getString(_legacyKeyName)?.trim() ?? '';
    if (legacyKey.isEmpty) {
      await preferences.remove(_legacyKeyName);
      return '';
    }

    await writeMasterKey(legacyKey);
    return legacyKey;
  }

  Future<void> writeMasterKey(String value) async {
    final key = value.trim();
    if (Platform.isAndroid) {
      await _androidChannel.invokeMethod<void>(key.isEmpty ? 'delete' : 'write', key.isEmpty ? null : key);
    } else if (Platform.isLinux) {
      if (key.isEmpty) {
        await _deleteLinuxCredential();
      } else {
        await _writeLinuxCredential(key);
      }
    } else {
      throw UnsupportedError('Secure credential storage is not implemented on this platform.');
    }

    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_legacyKeyName);
  }

  Future<File> _linuxCredentialFile() async {
    final directory = Directory(p.join((await getApplicationSupportDirectory()).path, 'credentials'));
    await directory.create(recursive: true);
    await _chmod('700', directory.path);
    return File(p.join(directory.path, 'master-key.v1'));
  }

  Future<List<int>> _linuxMachineKey() async {
    String machineId = '';
    for (final path in const ['/etc/machine-id', '/var/lib/dbus/machine-id']) {
      final file = File(path);
      if (await file.exists()) {
        machineId = (await file.readAsString()).trim();
        if (machineId.isNotEmpty) break;
      }
    }
    if (machineId.isEmpty) machineId = Platform.localHostname;

    final userBinding = utf8.encode([
      Platform.environment['USER'] ?? '',
      Platform.environment['HOME'] ?? '',
      'NetOutpost credential vault v1',
    ].join('\u0000'));
    final vaultKey = await _linuxVaultKey();
    return Hmac(sha256, vaultKey).convert([...utf8.encode(machineId), 0, ...userBinding]).bytes;
  }

  Future<List<int>> _linuxVaultKey() async {
    final credentialFile = await _linuxCredentialFile();
    final keyFile = File(p.join(credentialFile.parent.path, 'vault.key'));
    if (await keyFile.exists()) {
      final key = base64Decode((await keyFile.readAsString()).trim());
      if (key.length != 32) throw const FormatException('Invalid credential vault key.');
      return key;
    }

    final key = List<int>.generate(32, (_) => Random.secure().nextInt(256));
    final temporaryFile = File('${keyFile.path}.tmp');
    await temporaryFile.writeAsString(base64Encode(key), flush: true);
    await _chmod('600', temporaryFile.path);
    await temporaryFile.rename(keyFile.path);
    return key;
  }

  Future<String?> _readLinuxCredential() async {
    final file = await _linuxCredentialFile();
    if (!await file.exists()) return null;

    final payload = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (payload['version'] != 1) throw const FormatException('Unsupported credential format.');

    final nonce = base64Decode(payload['nonce'] as String);
    final cipherText = base64Decode(payload['cipherText'] as String);
    final storedMac = base64Decode(payload['mac'] as String);
    final keys = await _deriveLinuxKeys();
    final calculatedMac = Hmac(sha256, keys.mac).convert([...nonce, ...cipherText]).bytes;
    if (!_constantTimeEquals(storedMac, calculatedMac)) {
      throw const FormatException('Credential integrity check failed.');
    }

    final clearText = _xorWithKeyStream(cipherText, keys.encryption, nonce);
    return utf8.decode(clearText);
  }

  Future<void> _writeLinuxCredential(String value) async {
    final file = await _linuxCredentialFile();
    final nonce = Uint8List.fromList(List<int>.generate(24, (_) => Random.secure().nextInt(256)));
    final keys = await _deriveLinuxKeys();
    final cipherText = _xorWithKeyStream(utf8.encode(value), keys.encryption, nonce);
    final mac = Hmac(sha256, keys.mac).convert([...nonce, ...cipherText]).bytes;
    final payload = jsonEncode({
      'version': 1,
      'nonce': base64Encode(nonce),
      'cipherText': base64Encode(cipherText),
      'mac': base64Encode(mac),
    });

    final temporaryFile = File('${file.path}.tmp');
    await temporaryFile.writeAsString(payload, flush: true);
    await _chmod('600', temporaryFile.path);
    await temporaryFile.rename(file.path);
  }

  Future<void> _deleteLinuxCredential() async {
    final file = await _linuxCredentialFile();
    if (await file.exists()) await file.delete();
  }

  Future<({List<int> encryption, List<int> mac})> _deriveLinuxKeys() async {
    final machineKey = await _linuxMachineKey();
    return (
      encryption: Hmac(sha256, machineKey).convert(utf8.encode('encryption')).bytes,
      mac: Hmac(sha256, machineKey).convert(utf8.encode('authentication')).bytes,
    );
  }

  Uint8List _xorWithKeyStream(List<int> input, List<int> key, List<int> nonce) {
    final output = Uint8List(input.length);
    var offset = 0;
    var counter = 0;
    while (offset < input.length) {
      final counterBytes = ByteData(8)..setUint64(0, counter++, Endian.big);
      final block = Hmac(sha256, key).convert([...nonce, ...counterBytes.buffer.asUint8List()]).bytes;
      for (var index = 0; index < block.length && offset < input.length; index++, offset++) {
        output[offset] = input[offset] ^ block[index];
      }
    }
    return output;
  }

  bool _constantTimeEquals(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    var difference = 0;
    for (var index = 0; index < first.length; index++) {
      difference |= first[index] ^ second[index];
    }
    return difference == 0;
  }

  Future<void> _chmod(String mode, String path) async {
    final result = await Process.run('chmod', [mode, path]);
    if (result.exitCode != 0) {
      throw FileSystemException('Could not protect the credential vault.', path);
    }
  }
}
