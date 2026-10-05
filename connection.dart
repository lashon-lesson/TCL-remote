// חיבור לטלוויזיה אחת: צימוד (פורט 6467) ושליטה (פורט 6466)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../store.dart';
import 'der.dart';
import 'identity.dart';
import 'proto.dart';

enum TvStatus { offline, connecting, pairing, ready, error }

class TvConnection extends ChangeNotifier {
  final TvDevice tv;
  final Identity identity;
  final VoidCallback onPairedChanged;
  TvConnection(this.tv, this.identity, this.onPairedChanged);

  TvStatus status = TvStatus.offline;
  String? error;
  bool? powered;
  bool? muted;
  int? volume;
  int? volumeMax;
  String? currentApp; // האפליקציה שפתוחה כרגע בטלוויזיה
  bool _appReported = false;
  bool imeActive = false; // הטלוויזיה דיווחה על שדה הקלדה
  int _imeCounter = 0;
  int _fieldCounter = 0;

  SecureSocket? _remote;
  SecureSocket? _pair;
  Timer? _retry;
  int _fails = 0;
  bool _disposed = false;
  bool _pairOk = false;
  String? _pairFail;

  bool get isReady => status == TvStatus.ready;

  void _set(TvStatus s, {String? err}) {
    if (_disposed) return;
    status = s;
    error = err;
    notifyListeners();
  }

  SecurityContext _ctx() => SecurityContext(withTrustedRoots: false)
    ..useCertificateChainBytes(utf8.encode(identity.certPem))
    ..usePrivateKeyBytes(utf8.encode(identity.keyPem));

  // ---------- שליטה ----------

  Future<void> connect() async {
    _retry?.cancel();
    _closeSockets();
    if (_disposed) return;
    if (!tv.paired) return startPairing();
    _set(TvStatus.connecting);
    try {
      final s = await SecureSocket.connect(tv.host, 6466,
          context: _ctx(),
          onBadCertificate: (_) => true,
          timeout: const Duration(seconds: 5));
      if (_disposed) {
        s.destroy();
        return;
      }
      _remote = s;
      final reader = FrameReader(_onRemote);
      s.listen(reader.add,
          onDone: () => _onRemoteClosed(s, null),
          onError: (e) => _onRemoteClosed(s, e),
          cancelOnError: true);
    } on HandshakeException {
      _unpaired();
    } on TlsException {
      _unpaired();
    } catch (e) {
      _scheduleRetry('הטלוויזיה לא עונה – בדוק שהיא דלוקה ושהכתובת נכונה');
    }
  }

  void _onRemote(Uint8List m) {
    final f = PbFields.decode(m);
    if (f.has(1)) {
      // RemoteConfigure – מציגים את עצמנו
      _send(Pb().msg(
          1,
          Pb().int32(1, 622).msg(
              2,
              Pb()
                  .str(1, 'Phone')
                  .str(2, 'TCL Remote')
                  .int32(3, 1)
                  .str(4, '1')
                  .str(5, 'il.lior.tclremote')
                  .str(6, '1.0.0'))));
      _fails = 0;
      _set(TvStatus.ready);
    } else if (f.has(2)) {
      _send(Pb().msg(2, Pb().int32(1, 622)));
    } else if (f.has(8)) {
      final ping = f.msg(8);
      _send(Pb().msg(9, Pb().int32(1, ping?.int32(1) ?? 0)));
    } else if (f.has(20)) {
      final inject = f.msg(20);
      final app = inject?.msg(1);
      final field = inject?.msg(2);
      if (app != null) _imeCounter = app.int32(1, _imeCounter);
      if (field != null) {
        _fieldCounter = field.int32(1, _fieldCounter);
        imeActive = true;
      }
      final pkg = app?.str(12);
      if (pkg != null && pkg.isNotEmpty) {
        currentApp = pkg;
        _appReported = true;
      }
      notifyListeners();
    } else if (f.has(21)) {
      final b = f.msg(21)!;
      _imeCounter = b.int32(1, _imeCounter);
      _fieldCounter = b.int32(2, _fieldCounter);
      imeActive = true;
      notifyListeners();
    } else if (f.has(22)) {
      final field = f.msg(22)?.msg(2);
      if (field != null) _fieldCounter = field.int32(1, _fieldCounter);
      imeActive = true;
      notifyListeners();
    } else if (f.has(40)) {
      powered = f.msg(40)?.int32(1) == 1;
      notifyListeners();
    } else if (f.has(50)) {
      final v = f.msg(50)!;
      volumeMax = v.int32(6);
      volume = v.int32(7);
      muted = v.int32(8) == 1;
      notifyListeners();
    }
  }

  void _onRemoteClosed(SecureSocket s, Object? e) {
    if (_remote != s) return;
    _remote = null;
    if (_disposed) return;
    final wasReady = status == TvStatus.ready;
    final msg = '$e'.toLowerCase();
    if (!wasReady &&
        (e is TlsException || msg.contains('reset') || msg.contains('certificate'))) {
      _unpaired();
      return;
    }
    _scheduleRetry(wasReady ? null : 'החיבור נסגר');
  }

  void _unpaired() {
    tv.paired = false;
    onPairedChanged();
    startPairing();
  }

  void _scheduleRetry(String? err) {
    if (_disposed) return;
    _fails++;
    _set(_fails > 2 ? TvStatus.error : TvStatus.connecting, err: err);
    final secs = min(20, max(2, _fails * 3));
    _retry?.cancel();
    _retry = Timer(Duration(seconds: secs), connect);
  }

  void _send(Pb msg) {
    try {
      _remote?.add(msg.framed());
    } catch (_) {}
  }

  void sendKey(int code, {int direction = 3}) =>
      _send(Pb().msg(10, Pb().int32(1, code).int32(2, direction)));

  /// כותב טקסט ישירות לשדה שפתוח בטלוויזיה (מחליף את התוכן שבו). תומך בעברית
  void sendImeText(String text) {
    if (text.isEmpty) return;
    final pos = text.length - 1;
    _send(Pb().msg(
        21,
        Pb().int32(1, _imeCounter).int32(2, _fieldCounter).msg(
            3,
            Pb().int32(1, 1).msg(
                2, Pb().int32(1, pos).int32(2, pos).str(3, text)))));
  }

  /// הדלקה/כיבוי
  /// 'off' – נשלח כיבוי, 'on' – נשלחה הדלקה, 'waking' – נשלח Wake-on-LAN, 'unreachable' – אין קשר
  Future<String> power() async {
    if (isReady) {
      if (powered == false) {
        sendKey(224); // WAKEUP – מדליק בלי סיכון לכבות
        return 'on';
      }
      sendKey(26);
      return 'off';
    }

    // לא מחובר: מנסים להעיר ולהתחבר מחדש
    var wol = false;
    final mac = tv.mac;
    if (mac != null) wol = await wakeOnLan(mac, tv.host);
    _fails = 0;
    connect();
    for (var t = 0; t < 40; t++) {
      await Future.delayed(const Duration(milliseconds: 250));
      if (_disposed) return 'unreachable';
      if (isReady) {
        await Future.delayed(const Duration(milliseconds: 400));
        sendKey(224);
        return 'on';
      }
    }
    if (wol) {
      for (final s in [5, 10, 20, 30]) {
        Timer(Duration(seconds: s), () {
          if (!_disposed && !isReady && status != TvStatus.pairing) connect();
        });
      }
      return 'waking';
    }
    return 'unreachable';
  }

  void sendAppLink(String link) => _send(Pb().msg(90, Pb().str(1, link)));

  static const _knownLinks = {
    'com.google.android.youtube.tv': ['https://www.youtube.com'],
    'com.netflix.ninja': ['https://www.netflix.com/title'],
    'com.amazon.amazonvideo.livingroom': ['https://app.primevideo.com'],
    'com.disney.disneyplus': ['https://www.disneyplus.com'],
  };

  /// פותח אפליקציה. 'link' – נפתחה ישירות, 'store' – נפתח דף האפליקציה בחנות
  String launchApp(String pkg) {
    if (pkg.contains('://') || pkg.startsWith('intent:')) {
      sendAppLink(pkg);
      return 'link';
    }
    final known = _knownLinks[pkg];
    if (known != null) {
      sendAppLink(known.first);
      return 'link';
    }
    // לאפליקציות בלי קישור ישיר: דף האפליקציה ב-Google Play, ואז לחיצה על "פתיחה"
    sendAppLink('https://play.google.com/store/apps/details?id=$pkg');
    Timer(const Duration(milliseconds: 4000), () {
      if (isReady) sendKey(23); // OK על הכפתור "פתיחה"
    });
    return 'store';
  }

  // ---------- צימוד ----------

  Pb _pairMsg() => Pb().int32(1, 2).int32(2, 200);
  Pb _encoding() => Pb().int32(1, 3).int32(2, 6); // הקסה, 6 תווים

  Future<void> startPairing() async {
    _retry?.cancel();
    _closeSockets();
    _pairOk = false;
    _pairFail = null;
    _set(TvStatus.connecting);
    try {
      final s = await SecureSocket.connect(tv.host, 6467,
          context: _ctx(),
          onBadCertificate: (_) => true,
          timeout: const Duration(seconds: 5));
      if (_disposed) {
        s.destroy();
        return;
      }
      _pair = s;
      final reader = FrameReader(_onPair);
      s.listen(reader.add,
          onDone: () => _onPairClosed(s),
          onError: (_) => _onPairClosed(s),
          cancelOnError: true);
      s.add(_pairMsg()
          .msg(10, Pb().str(1, 'atvremote').str(2, 'TCL Remote'))
          .framed());
    } catch (e) {
      _set(TvStatus.error,
          err: 'לא ניתן להתחבר לטלוויזיה – בדוק שהיא דלוקה ושהכתובת נכונה');
    }
  }

  void _onPair(Uint8List m) {
    final f = PbFields.decode(m);
    final st = f.int32(2);
    if (st != 200) {
      _pairFail = st == 402 ? 'קוד שגוי' : 'הטלוויזיה דחתה את הצימוד ($st)';
      final s = _pair;
      s?.destroy();
      _onPairClosed(s);
      return;
    }
    if (f.has(11)) {
      _pair?.add(_pairMsg()
          .msg(20, Pb().msg(1, _encoding()).int32(3, 1))
          .framed());
    } else if (f.has(20)) {
      _pair?.add(_pairMsg()
          .msg(30, Pb().msg(1, _encoding()).int32(2, 1))
          .framed());
    } else if (f.has(31)) {
      _set(TvStatus.pairing); // הקוד מופיע עכשיו על המסך
    } else if (f.has(41)) {
      _pairOk = true;
      final s = _pair;
      s?.destroy();
      _onPairClosed(s);
    }
  }

  void _onPairClosed(SecureSocket? s) {
    if (s == null || _pair != s) return;
    _pair = null;
    if (_disposed) return;
    if (_pairOk) {
      _pairOk = false;
      tv.paired = true;
      onPairedChanged();
      Timer(const Duration(seconds: 1), connect);
    } else if (status != TvStatus.ready) {
      _set(TvStatus.error, err: _pairFail ?? 'הצימוד הופסק – נסה שוב');
    }
  }

  /// מחזיר false אם הקוד שגוי (אפשר לנסות שוב)
  bool submitCode(String input) {
    final code = input.trim().toUpperCase();
    if (!RegExp(r'^[0-9A-F]{6}$').hasMatch(code)) return false;
    final cert = _pair?.peerCertificate;
    if (cert == null) return false;
    final server = rsaPublicFromCert(cert.der);
    final hash = sha256.convert([
      ...Der.unsignedBytes(identity.n),
      ...Der.unsignedBytes(identity.e),
      ...Der.unsignedBytes(server.n),
      ...Der.unsignedBytes(server.e),
      int.parse(code.substring(2, 4), radix: 16),
      int.parse(code.substring(4, 6), radix: 16),
    ]).bytes;
    if (hash[0] != int.parse(code.substring(0, 2), radix: 16)) return false;
    _pair?.add(_pairMsg().msg(40, Pb().bytes(1, hash)).framed());
    _set(TvStatus.connecting);
    return true;
  }

  // ---------- כללי ----------

  void _closeSockets() {
    final r = _remote, p = _pair;
    _remote = null;
    _pair = null;
    r?.destroy();
    p?.destroy();
  }

  void disconnect() {
    _retry?.cancel();
    _closeSockets();
    _set(TvStatus.offline);
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _closeSockets();
    super.dispose();
  }
}

/// שליחת "חבילת קסם" להדלקת הטלוויזיה (Wake-on-LAN)
Future<bool> wakeOnLan(String mac, String host) async {
  final parts = mac.split(RegExp('[:-]'));
  if (parts.length != 6) return false;
  final m = parts.map((h) => int.parse(h, radix: 16)).toList();
  final packet = <int>[...List.filled(6, 0xff), for (var i = 0; i < 16; i++) ...m];
  final p = host.split('.');
  final targets = <String>[
    '255.255.255.255',
    if (p.length == 4) '${p[0]}.${p[1]}.${p[2]}.255',
    host,
  ];
  var sent = false;
  RawDatagramSocket? sock;
  try {
    sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    sock.broadcastEnabled = true;
    for (var round = 0; round < 3; round++) {
      for (final t in targets) {
        for (final port in [9, 7]) {
          try {
            if (sock.send(packet, InternetAddress(t), port) > 0) sent = true;
          } catch (_) {}
        }
      }
      await Future.delayed(const Duration(milliseconds: 150));
    }
  } catch (_) {
  } finally {
    sock?.close();
  }
  return sent;
}
