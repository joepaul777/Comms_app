import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../platform/platform.dart';

/// A message's words could not be locked for someone, because their phone has no
/// encryption key yet (they are on an old version of Comms).
class NoKeyException implements Exception {
  final List<String> uids;
  const NoKeyException(this.uids);
  @override
  String toString() => 'They need to update Comms first';
}

/// What came out of an unlocked message: its contents and the key it was locked with
/// (the same key unlocks its photo, video or voice note).
class Opened {
  final Map<String, dynamic> payload;
  final List<int> contentKey;
  const Opened(this.payload, this.contentKey);
}

/// End-to-end encryption.
///
/// Every phone has its own X25519 key pair. The private half never leaves the phone
/// (it lives in Android's encrypted storage); the public half is published on the
/// person's profile.
///
/// Each message gets a fresh random key. The message is locked with it (AES-256-GCM),
/// and that key is then locked separately for every person in the chat, using a key
/// only the sender and that person can work out (X25519 + HKDF). The server, the file
/// host and anyone reading the database only ever see scrambled bytes.
///
/// Stored as `enc`: {v: 1, f: sender's public key, n: nonce, c: locked contents,
/// k: {uid: that person's copy of the message key}}.
class E2E {
  E2E._();
  static final E2E instance = E2E._();

  /// What older versions of Comms show in place of an encrypted message.
  static const compatText = '🔒 Update Comms to read this message';

  static const _x25519 = DartX25519();
  static final _gcm = DartAesGcm.with256bits();
  static final _hkdf = DartHkdf(hmac: DartHmac(const DartSha256()), outputLength: 32);
  static const _storage = FlutterSecureStorage(
    // Never wipe the key on a read error: that would make every message unreadable.
    aOptions: AndroidOptions(resetOnError: false),
  );
  static final Random _random = Random.secure();

  String? _uid;
  SimpleKeyPair? _pair;
  String? _publicKey;
  Future<void>? _loading;

  /// True when this phone had no key for the account and just made one.
  bool createdNow = false;

  String? get uid => _uid;
  String? get publicKey => _publicKey;

  static String _storageKey(String uid) => 'e2e_x25519_$uid';

  /// Loads this phone's key for [uid], making one the first time.
  Future<void> load(String uid) {
    if (_uid == uid && _loading != null) return _loading!;
    _uid = uid;
    _pair = null;
    _publicKey = null;
    _wrapKeys.clear();
    _opened.clear();
    return _loading = () async {
      var seed = await _readSeed(uid);
      createdNow = seed == null;
      if (seed == null) {
        seed = randomBytes(32);
        await _storage.write(key: _storageKey(uid), value: base64Encode(seed));
        // Read it back, so a key that failed to save is never used for sending.
        final saved = await _readSeed(uid);
        if (saved == null) throw StateError('Could not save the encryption key');
      }
      await _use(seed);
    }();
  }

  Future<List<int>?> _readSeed(String uid) async {
    final stored = await _storage.read(key: _storageKey(uid));
    if (stored == null || stored.isEmpty) return null;
    final bytes = base64Decode(stored);
    return bytes.length == 32 ? bytes : null;
  }

  Future<void> _use(List<int> seed) async {
    _pair = await _x25519.newKeyPairFromSeed(seed);
    _publicKey = base64Encode((await _pair!.extractPublicKey()).bytes);
  }

  /// The public key that goes with [seed].
  static Future<String> publicKeyOf(List<int> seed) async =>
      base64Encode((await (await _x25519.newKeyPairFromSeed(seed)).extractPublicKey()).bytes);

  /// Keeps a key handed over by the person's other device (see DeviceLink), in place
  /// of this device's own.
  Future<void> adoptSeed(String uid, List<int> seed) async {
    if (seed.length != 32) throw const FormatException('bad key');
    await _storage.write(key: _storageKey(uid), value: base64Encode(seed));
    final saved = await _readSeed(uid);
    if (saved == null) throw StateError('Could not save the encryption key');
    _uid = uid;
    _wrapKeys.clear();
    _opened.clear();
    createdNow = false;
    await (_loading = _use(seed));
  }

  /// Forgets this device's key for [uid] (signing out of a browser).
  Future<void> forget(String uid) async {
    await _storage.delete(key: _storageKey(uid));
    if (_uid == uid) {
      _uid = null;
      _pair = null;
      _publicKey = null;
      _loading = null;
      _wrapKeys.clear();
      _opened.clear();
    }
  }

  // ---- Handing the key to another of the person's devices ---------------------

  /// A key only the holder of [keyPair] and the owner of [theirKey] can work out,
  /// used once to hand over the account's key.
  static Future<SecretKey> _linkKey(KeyPair keyPair, String myKey, String theirKey) async {
    final theirs = base64Decode(theirKey);
    if (theirs.length != 32) throw const FormatException('bad public key');
    final shared = await _x25519.sharedSecretKey(keyPair: keyPair, remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519));
    final pair = [base64Decode(myKey), theirs]..sort(_compareBytes);
    return _hkdf.deriveKey(secretKey: shared, nonce: [...pair[0], ...pair[1]], info: utf8.encode('comms-link-v1'));
  }

  /// Locks this device's key for the new device whose one-off public key is [theirKey].
  Future<String> lockKeyFor(String theirKey, {required String aad}) async {
    if (!await ready()) throw StateError('No key on this device');
    final seed = await _pair!.extractPrivateKeyBytes();
    final nonce = randomBytes(12);
    final box = await _gcm.encrypt(seed, secretKey: await _linkKey(_pair!, _publicKey!, theirKey), nonce: nonce, aad: utf8.encode(aad));
    return base64Encode([...nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// A one-off key pair for asking another device for the account's key.
  static Future<(SimpleKeyPair, String)> oneOffKeyPair() async {
    final pair = await _x25519.newKeyPairFromSeed(randomBytes(32));
    return (pair, base64Encode((await pair.extractPublicKey()).bytes));
  }

  /// Unlocks a key locked by [lockKeyFor]. [accountKey] is the public key on the
  /// profile; the result must match it.
  static Future<List<int>> unlockHandedKey(SimpleKeyPair oneOff, String oneOffKey, String accountKey, String box, {required String aad}) async {
    final bytes = base64Decode(box);
    final seed = await _gcm.decrypt(
      SecretBox(bytes.sublist(12, bytes.length - 16), nonce: bytes.sublist(0, 12), mac: Mac(bytes.sublist(bytes.length - 16))),
      secretKey: await _linkKey(oneOff, oneOffKey, accountKey),
      aad: utf8.encode(aad),
    );
    if (await publicKeyOf(seed) != accountKey) throw const FormatException('key does not match the profile');
    return seed;
  }

  /// Six digits both screens show, so the person can check they are linking the
  /// device in front of them.
  static Future<String> linkCode(String oneOffKey) async {
    final hash = (await const DartSha256().hash([...utf8.encode('comms-link-code-v1'), ...base64Decode(oneOffKey)])).bytes;
    final n = ((hash[0] << 24) | (hash[1] << 16) | (hash[2] << 8) | hash[3]) % 1000000;
    final digits = n.toString().padLeft(6, '0');
    return '${digits.substring(0, 3)} ${digits.substring(3)}';
  }

  /// Uses a fixed key (tests only).
  Future<void> useSeedForTest(String uid, List<int> seed) async {
    _uid = uid;
    _wrapKeys.clear();
    _opened.clear();
    _loading = _use(seed);
    await _loading;
  }

  /// Waits for the key to be loaded. False when there is none (signed out).
  Future<bool> ready() async {
    if (_loading == null) return false;
    try {
      await _loading;
      return _pair != null;
    } catch (_) {
      return false;
    }
  }

  /// What a message's encryption is tied to, so it can't be moved to another message or chat.
  static String messageAad(String roomId, String messageId) => 'msg:$roomId:$messageId';
  static String lastAad(String roomId) => 'last:$roomId';

  static List<int> randomBytes(int n) => List<int>.generate(n, (_) => _random.nextInt(256));

  static List<int> newContentKey() => randomBytes(32);

  // ---- Keys shared with one other person -----------------------------------

  final Map<String, SecretKey> _wrapKeys = {};

  /// The key only this phone and the owner of [theirKey] can work out.
  Future<SecretKey> _wrapKey(String theirKey) async {
    final cached = _wrapKeys[theirKey];
    if (cached != null) return cached;
    final theirs = base64Decode(theirKey);
    if (theirs.length != 32) throw const FormatException('bad public key');
    final shared = await _x25519.sharedSecretKey(
      keyPair: _pair!,
      remotePublicKey: SimplePublicKey(theirs, type: KeyPairType.x25519),
    );
    // Both phones put the two public keys in the same order, so both get the same key.
    final mine = base64Decode(_publicKey!);
    final pair = [mine, theirs]..sort(_compareBytes);
    final key = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: [...pair[0], ...pair[1]],
      info: utf8.encode('comms-e2e-wrap-v1'),
    );
    return _wrapKeys[theirKey] = key;
  }

  static int _compareBytes(List<int> a, List<int> b) {
    for (var i = 0; i < min(a.length, b.length); i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }

  // ---- Locking and unlocking ------------------------------------------------

  /// Locks [payload] so only the people in [recipients] (uid -> public key) can read it.
  /// [aad] ties it to one place (a message id), so it can't be copied somewhere else.
  Future<Map<String, dynamic>> seal(
    Map<String, dynamic> payload,
    Map<String, String> recipients, {
    required String aad,
    List<int>? contentKey,
  }) async {
    if (!await ready()) throw StateError('Encryption is not set up on this phone');
    final key = contentKey ?? newContentKey();
    final nonce = randomBytes(12);
    final box = await _gcm.encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: utf8.encode(aad),
    );
    final keys = <String, String>{};
    for (final entry in recipients.entries) {
      final wrapNonce = randomBytes(12);
      final wrapped = await _gcm.encrypt(
        key,
        secretKey: await _wrapKey(entry.value),
        nonce: wrapNonce,
        aad: utf8.encode('${entry.key}|$aad'),
      );
      keys[entry.key] = base64Encode([...wrapNonce, ...wrapped.cipherText, ...wrapped.mac.bytes]);
    }
    final enc = <String, dynamic>{
      'v': 1,
      'f': _publicKey,
      'n': base64Encode(nonce),
      'c': base64Encode([...box.cipherText, ...box.mac.bytes]),
      'k': keys,
    };
    _opened[_cacheKey(enc, aad)] = Opened(payload, key);
    return enc;
  }

  final Map<String, Opened?> _opened = {};

  static String _cacheKey(Map enc, String aad) {
    final c = enc['c']?.toString() ?? '';
    return '$aad|${c.length}|${c.hashCode}';
  }

  /// Already unlocked (or already known to be unreadable), without waiting.
  Opened? cached(Map enc, String aad) => _opened[_cacheKey(enc, aad)];
  bool isCached(Map enc, String aad) => _opened.containsKey(_cacheKey(enc, aad));

  /// Unlocks something locked by [seal]. Null when this phone can't read it
  /// (it was locked for another phone, or it was tampered with).
  Future<Opened?> open(Map enc, {required String aad}) async {
    final cacheKey = _cacheKey(enc, aad);
    if (_opened.containsKey(cacheKey)) return _opened[cacheKey];
    if (!await ready()) return null;
    Opened? result;
    try {
      final mine = (enc['k'] as Map?)?[_uid]?.toString();
      final from = enc['f']?.toString();
      if (mine != null && from != null) {
        final wrapped = base64Decode(mine);
        final key = await _gcm.decrypt(
          SecretBox(wrapped.sublist(12, wrapped.length - 16), nonce: wrapped.sublist(0, 12), mac: Mac(wrapped.sublist(wrapped.length - 16))),
          secretKey: await _wrapKey(from),
          aad: utf8.encode('$_uid|$aad'),
        );
        final body = base64Decode(enc['c'].toString());
        final clear = await _gcm.decrypt(
          SecretBox(body.sublist(0, body.length - 16), nonce: base64Decode(enc['n'].toString()), mac: Mac(body.sublist(body.length - 16))),
          secretKey: SecretKey(key),
          aad: utf8.encode(aad),
        );
        result = Opened(Map<String, dynamic>.from(jsonDecode(utf8.decode(clear)) as Map), key);
      }
    } catch (_) {
      result = null;
    }
    _opened[cacheKey] = result;
    return result;
  }

  // ---- Files ------------------------------------------------------------------

  static const _chunk = 512 * 1024;

  static Future<SecretKey> _fileKey(List<int> contentKey) =>
      _hkdf.deriveKey(secretKey: SecretKey(contentKey), info: utf8.encode('comms-e2e-file-v1'));

  static List<int> _chunkNonce(int index) => [0, 0, 0, 0, 0, 0, 0, 0, (index >> 24) & 255, (index >> 16) & 255, (index >> 8) & 255, index & 255];

  /// Locks a file in pieces, so even a large video never has to fit in memory at once.
  /// The last piece is marked, so a cut-short file is noticed.
  static Future<File> encryptFile(File source, File target, List<int> contentKey) async {
    final key = await _fileKey(contentKey);
    final gcm = AesGcm.with256bits();
    final input = await source.open();
    final output = target.openWrite();
    try {
      final length = await input.length();
      final pieces = max(1, (length + _chunk - 1) ~/ _chunk);
      for (var i = 0; i < pieces; i++) {
        final clear = await input.read(_chunk);
        final last = i == pieces - 1;
        final box = await gcm.encrypt(clear, secretKey: key, nonce: _chunkNonce(i), aad: [last ? 1 : 0]);
        output.add(box.cipherText);
        output.add(box.mac.bytes);
      }
      await output.flush();
    } finally {
      await input.close();
      await output.close();
    }
    return target;
  }

  /// Unlocks a file locked by [encryptFile]. Throws if it was changed or cut short.
  static Future<File> decryptFile(File source, File target, List<int> contentKey) async {
    final key = await _fileKey(contentKey);
    final gcm = AesGcm.with256bits();
    const piece = _chunk + 16;
    final input = await source.open();
    final output = target.openWrite();
    try {
      final length = await input.length();
      if (length < 16) throw const FormatException('file too short');
      final pieces = (length + piece - 1) ~/ piece;
      for (var i = 0; i < pieces; i++) {
        final bytes = await input.read(piece);
        if (bytes.length < 16) throw const FormatException('broken file');
        final last = i == pieces - 1;
        final clear = await gcm.decrypt(
          SecretBox(Uint8List.sublistView(bytes, 0, bytes.length - 16), nonce: _chunkNonce(i), mac: Mac(Uint8List.sublistView(bytes, bytes.length - 16))),
          secretKey: key,
          aad: [last ? 1 : 0],
        );
        output.add(clear);
      }
      await output.flush();
    } catch (_) {
      await output.close();
      await input.close();
      if (await target.exists()) await target.delete();
      rethrow;
    }
    await input.close();
    await output.close();
    return target;
  }

  // ---- Security codes ---------------------------------------------------------

  /// A 60-digit code that two people can compare to be sure nobody is in the middle.
  /// It is the same on both phones, and changes if either person's key changes.
  static Future<String> securityCode(String keyA, String keyB) async {
    final pair = [base64Decode(keyA), base64Decode(keyB)]..sort(_compareBytes);
    final hash = (await const DartSha512().hash([...utf8.encode('comms-safety-v1'), ...pair[0], ...pair[1]])).bytes;
    final groups = <String>[];
    for (var i = 0; i < 12; i++) {
      final b = hash.sublist(i * 4, i * 4 + 4);
      final n = ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) % 100000;
      groups.add(n.toString().padLeft(5, '0'));
    }
    return groups.join(' ');
  }
}
