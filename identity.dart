// זהות השלט: מפתח RSA ותעודה בחתימה עצמית, נוצרים פעם אחת ונשמרים בטלפון
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'der.dart';

class Identity {
  final String certPem;
  final String keyPem;
  final BigInt n;
  final BigInt e;
  final String deviceId; // מזהה ייחודי לטלפון הזה
  final bool regenerated; // נוצרה זהות חדשה – צריך לצמד מחדש
  Identity._(this.certPem, this.keyPem, this.n, this.e, this.deviceId, this.regenerated);

  static const _kCert = 'identity_cert';
  static const _kKey = 'identity_key';
  static const _kId = 'identity_device_id';
  static const _kVer = 'identity_version';

  static Future<Identity> loadOrCreate(SharedPreferences prefs) async {
    var cert = prefs.getString(_kCert);
    var key = prefs.getString(_kKey);
    var id = prefs.getString(_kId);
    var regenerated = false;
    // גרסה 2: לכל טלפון שם ייחודי, כדי שכמה טלפונים יוכלו לעבוד מול אותה טלוויזיה
    if (cert == null || key == null || id == null || prefs.getInt(_kVer) != 2) {
      final rnd = Random.secure();
      final newId = List.generate(6, (_) => rnd.nextInt(16).toRadixString(16)).join().toUpperCase();
      final r = await Isolate.run(() => _generate('atvremote-$newId'));
      regenerated = cert != null;
      cert = r.cert;
      key = r.key;
      id = newId;
      await prefs.setString(_kCert, cert);
      await prefs.setString(_kKey, key);
      await prefs.setString(_kId, id);
      await prefs.setInt(_kVer, 2);
    }
    final pub = rsaPublicFromCert(Der.fromPem(cert));
    return Identity._(cert, key, pub.n, pub.e, id, regenerated);
  }
}

({String cert, String key}) _generate(String commonName) {
  final seed = Random.secure();
  final rnd = FortunaRandom()
    ..seed(KeyParameter(
        Uint8List.fromList(List.generate(32, (_) => seed.nextInt(256)))));

  final gen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rnd));
  final pair = gen.generateKeyPair();
  final pub = pair.publicKey as RSAPublicKey;
  final priv = pair.privateKey as RSAPrivateKey;

  final n = pub.modulus!;
  final e = pub.exponent!;
  final d = priv.exponent!;
  final p = priv.p!;
  final q = priv.q!;

  // מפתח פרטי PKCS#1
  final keyDer = Der.seq([
    Der.integer(BigInt.zero),
    Der.integer(n),
    Der.integer(e),
    Der.integer(d),
    Der.integer(p),
    Der.integer(q),
    Der.integer(d % (p - BigInt.one)),
    Der.integer(d % (q - BigInt.one)),
    Der.integer(q.modInverse(p)),
  ]);

  // תעודת X.509 v3 בחתימה עצמית
  final sha256Rsa =
      Der.seq([Der.oid([1, 2, 840, 113549, 1, 1, 11]), Der.nul()]);
  final name = Der.seq([
    Der.set([
      Der.seq([Der.oid([2, 5, 4, 3]), Der.utf8Str(commonName)])
    ])
  ]);
  final now = DateTime.now().toUtc();
  final spki = Der.seq([
    Der.seq([Der.oid([1, 2, 840, 113549, 1, 1, 1]), Der.nul()]),
    Der.bitString(Der.seq([Der.integer(n), Der.integer(e)])),
  ]);
  final serial = BigInt.from(seed.nextInt(1 << 31)) + BigInt.one;
  final tbs = Der.seq([
    Der.explicit(0, Der.integer(BigInt.two)),
    Der.integer(serial),
    sha256Rsa,
    name,
    Der.seq([
      Der.utcTime(now.subtract(const Duration(days: 1))),
      Der.utcTime(DateTime.utc(2049, 12, 31)),
    ]),
    name,
    spki,
  ]);

  final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
    ..init(true, PrivateKeyParameter<RSAPrivateKey>(priv));
  final sig = signer.generateSignature(tbs).bytes;

  final certDer = Der.seq([tbs, sha256Rsa, Der.bitString(sig)]);
  return (
    cert: Der.pem('CERTIFICATE', certDer),
    key: Der.pem('RSA PRIVATE KEY', keyDer),
  );
}
