// טלוויזיות VIDAA (טושיבה, הייסנס ועוד) – MQTT מוצפן בפורט 36669, צימוד בקוד בן 4 ספרות
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'atv/connection.dart' show wakeOnLan;
import 'atv/keys.dart';
import 'remote.dart';
import 'store.dart';
import 'vidaa_cert.dart';

const vidaaPort = 36669;

// ---------- פרטי הטלוויזיה (פורט 38400) ----------

typedef VidaaInfo = ({String name, String? brand, int? protocol, String? mac});

Future<VidaaInfo?> vidaaInfo(String ip) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client
        .getUrl(Uri.parse('http://$ip:38400/MediaServer/rendererdevicedesc.xml'));
    final res = await req.close().timeout(const Duration(seconds: 4));
    final xml = await res
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 4));
    String? tag(String t) =>
        RegExp('<$t>([^<]*)</$t>').firstMatch(xml)?.group(1)?.trim();
    String? kv(String k) =>
        RegExp('$k\\s*[=:]\\s*([^\\s<&]+)', caseSensitive: false).firstMatch(xml)?.group(1);
    final macs = macList([kv('macEthernet'), kv('macWifi')].whereType<String>().join(','));
    final mac = macs.isEmpty ? null : macs.join(',');
    final proto = int.tryParse(kv('transport_protocol') ?? '');
    final name = tag('friendlyName') ?? tag('modelName') ?? '';
    return (name: name, brand: kv('brand')?.toLowerCase(), protocol: proto, mac: mac);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

// ---------- פרטי ההתחברות (כמו באפליקציית VIDAA) ----------

const _pattern = '38D65DC30F45109A369A86FCE866A85B';
const _sufModern = r'h!i@s#$v%i^d&a*a';
const _sufLegacy = r'h*i&s%e!r^v0i1c9';
const _timeXor = 0x569814772b03a968;

String _md5u(String s) => md5.convert(utf8.encode(s)).toString().toUpperCase();

/// method: 'modern' (פרוטוקול 3290 ומעלה), 'middle' (3000–3285), 'legacy' (ישן יותר)
({String cid, String user, String pass}) vidaaCreds(
    String uuid, String brand, String method, int ts) {
  final race = _md5u('$_pattern\$$uuid').substring(0, 6);
  final cid = '$uuid\$$brand\$${race}_vidaacommon_001';
  final user = method == 'legacy' ? '$brand\$$ts' : '$brand\$${ts ^ _timeXor}';
  final suffix = method == 'modern' ? _sufModern : _sufLegacy;
  var sum = 0;
  for (final c in '$ts'.codeUnits) {
    sum += c - 48;
  }
  final v = _md5u('$brand${sum % 10}$suffix').substring(0, 6);
  return (cid: cid, user: user, pass: _md5u('$ts\$$v'));
}

String _method(int? protocol) => protocol == null
    ? 'modern'
    : protocol >= 3290
        ? 'modern'
        : protocol >= 3000
            ? 'middle'
            : 'legacy';

String _randomUuid() {
  final r = Random.secure();
  final b = List.generate(6, (_) => r.nextInt(256));
  b[0] = (b[0] & 0xfc) | 0x02; // כתובת "מקומית", לא של מכשיר אמיתי
  return b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(':');
}

// ---------- לקוח MQTT קטן (3.1.1, QoS 0) ----------

class _Refused implements Exception {
  final int code;
  _Refused(this.code);
}

SecurityContext? _sc;
SecurityContext _context() {
  if (_sc != null) return _sc!;
  final c = SecurityContext(withTrustedRoots: false);
  try {
    c.useCertificateChainBytes(utf8.encode(vidaaCert));
    c.usePrivateKeyBytes(utf8.encode(vidaaKey));
  } catch (_) {}
  return _sc = c;
}

class _Mqtt {
  final SecureSocket _s;
  _Mqtt._(this._s);

  final _in = <int>[];
  Completer<int>? _connack;
  Timer? _ping;
  int _pid = 0;
  bool closed = false;
  void Function(String topic, String payload)? onPublish;
  VoidCallback? onDone;

  static List<int> _str(String v) {
    final b = utf8.encode(v);
    return [b.length >> 8, b.length & 0xff, ...b];
  }

  static List<int> _len(int n) {
    final o = <int>[];
    do {
      var d = n % 128;
      n ~/= 128;
      if (n > 0) d |= 0x80;
      o.add(d);
    } while (n > 0);
    return o;
  }

  void _send(int header, List<int> body) {
    if (closed) return;
    try {
      _s.add(Uint8List.fromList([header, ..._len(body.length), ...body]));
    } catch (_) {
      _done();
    }
  }

  static Future<_Mqtt> open(String host,
      {required String clientId, required String user, required String pass}) async {
    final s = await SecureSocket.connect(host, vidaaPort,
        context: _context(),
        onBadCertificate: (_) => true,
        timeout: const Duration(seconds: 6));
    final m = _Mqtt._(s);
    m._connack = Completer<int>();
    s.listen(m._onData, onDone: m._done, onError: (_) => m._done(), cancelOnError: true);
    m._send(0x10, [
      ..._str('MQTT'), 4, 0xC2, 0, 60, // שם, גרסה, שם משתמש + סיסמה + התחלה נקייה, 60 שניות
      ..._str(clientId), ..._str(user), ..._str(pass),
    ]);
    final rc = await m._connack!.future
        .timeout(const Duration(seconds: 7), onTimeout: () => -1);
    if (rc != 0) {
      m.close();
      if (rc == -1) throw TimeoutException('connack');
      throw _Refused(rc);
    }
    m._ping = Timer.periodic(const Duration(seconds: 30), (_) => m._send(0xC0, const []));
    return m;
  }

  void subscribe(List<String> topics) {
    _pid = _pid % 60000 + 1;
    _send(0x82, [
      _pid >> 8, _pid & 0xff,
      for (final t in topics) ...[..._str(t), 0],
    ]);
  }

  void publish(String topic, String payload) =>
      _send(0x30, [..._str(topic), ...utf8.encode(payload)]);

  void _onData(Uint8List d) {
    _in.addAll(d);
    while (_in.length >= 2) {
      var mul = 1, len = 0, i = 1, b = 0;
      do {
        if (i >= _in.length) return;
        b = _in[i++];
        len += (b & 127) * mul;
        mul *= 128;
      } while ((b & 128) != 0 && i < 6);
      if (_in.length < i + len) return;
      final h = _in[0];
      final body = _in.sublist(i, i + len);
      _in.removeRange(0, i + len);
      _handle(h, body);
    }
  }

  void _handle(int h, List<int> body) {
    switch (h >> 4) {
      case 2: // CONNACK
        final c = _connack;
        if (c != null && !c.isCompleted) c.complete(body.length > 1 ? body[1] : 0);
        break;
      case 3: // PUBLISH
        if (body.length < 2) return;
        final qos = (h >> 1) & 3;
        final tl = body[0] << 8 | body[1];
        if (body.length < 2 + tl) return;
        final topic = utf8.decode(body.sublist(2, 2 + tl), allowMalformed: true);
        var p = 2 + tl;
        if (qos > 0 && body.length >= p + 2) {
          final id = body[p] << 8 | body[p + 1];
          p += 2;
          if (qos == 1) _send(0x40, [id >> 8, id & 0xff]);
        }
        final payload = utf8.decode(body.sublist(p), allowMalformed: true);
        try {
          onPublish?.call(topic, payload);
        } catch (_) {}
        break;
    }
  }

  void _done() {
    if (closed) return;
    closed = true;
    _ping?.cancel();
    final c = _connack;
    if (c != null && !c.isCompleted) c.complete(-2);
    try {
      _s.destroy();
    } catch (_) {}
    onDone?.call();
  }

  void close() {
    if (closed) return;
    _send(0xE0, const []);
    _done();
  }
}

// ---------- הטלוויזיה ----------

class VidaaConnection extends TvRemote {
  @override
  final TvDevice tv;
  final VoidCallback onSave;
  VidaaConnection(this.tv, this.onSave);

  @override
  TvStatus status = TvStatus.offline;
  @override
  String? error;
  @override
  bool? powered;
  @override
  bool? muted;

  @override
  bool get usesCode => true;
  @override
  int get codeLength => 4;
  @override
  bool get codeHex => false;
  @override
  bool get codeChecksLater => true;

  _Mqtt? _m;
  String _cid = '';
  Timer? _retry, _pinTimer, _codeTimer, _tokenTimer;
  int _fails = 0;
  bool _disposed = false;
  bool _connecting = false;
  bool _playing = false;
  String _typed = '';
  int _srcIdx = 0;
  List<String> _sources = [];
  Completer<List>? _appsWait;
  Completer<void>? _srcWait;
  final _appCache = <String, Map<String, dynamic>>{};
  final _pending = <void Function()>[];

  void _set(TvStatus s, {String? err}) {
    if (_disposed) return;
    status = s;
    error = err;
    notifyListeners();
  }

  @override
  bool get canSend => status != TvStatus.pairing;

  // מה שנשמר על הטלוויזיה בטלפון הזה (בשדה token)
  Map<String, dynamic> _st() {
    try {
      final t = tv.token;
      if (t != null && t.startsWith('{')) return Map<String, dynamic>.from(jsonDecode(t));
    } catch (_) {}
    return {};
  }

  void _save(Map<String, dynamic> s) {
    tv.token = s.isEmpty ? null : jsonEncode(s);
    onSave();
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  String _t(String svc, String action, {String kind = 'actions'}) =>
      '/remoteapp/tv/$svc/$_cid/$kind/$action';

  void _pub(String topic, [Object payload = '']) =>
      _m?.publish(topic, payload is String ? payload : jsonEncode(payload));

  // ---------- התחברות ----------

  @override
  Future<void> connect() async {
    if (_connecting || _disposed) return;
    _connecting = true;
    _retry?.cancel();
    _closeMqtt();
    _set(TvStatus.connecting);
    try {
      await _connectInner();
    } on _Refused {
      _set(TvStatus.error, err: 'הטלוויזיה סירבה לחיבור. נסה "צמד / אשר מחדש"');
    } catch (_) {
      _scheduleRetry('הטלוויזיה לא עונה – בדוק שהיא דלוקה ושהכתובת נכונה');
    } finally {
      _connecting = false;
    }
  }

  Future<void> _connectInner() async {
    var st = _st();
    final now = _now();

    // 1. כבר מצומד – מתחברים עם האישור שהטלוויזיה נתנה
    if (st['cid'] is String && st['user'] is String) {
      String? pass;
      var refresh = false;
      if (st['m'] == 'static') {
        pass = 'multimqttservice';
      } else if (st['at'] is String && (st['ate'] ?? 0) > now + 60) {
        pass = st['at'];
      } else if (st['rt'] is String && (st['rte'] ?? 0) > now + 60) {
        pass = st['rt'];
        refresh = true;
      }
      if (pass != null) {
        try {
          final m = await _Mqtt.open(tv.host, clientId: st['cid'], user: st['user'], pass: pass);
          _start(m, st['cid'], paired: true, refresh: refresh);
          return;
        } on _Refused {
          // האישור פג או נמחק בטלוויזיה – צימוד חדש
        }
      }
      st = {};
      _save(st);
    }

    // 2. צימוד חדש
    final info = await vidaaInfo(tv.host);
    final merged = mergeMacs(tv.mac, [info?.mac]);
    if (merged != null) {
      tv.mac = merged;
      onSave();
    }
    final brands = <String>{
      if (info?.brand != null && RegExp(r'^[a-z]{2,10}$').hasMatch(info!.brand!)) info!.brand!,
      'his',
      'tos',
    };
    final methods = info?.protocol != null
        ? [_method(info!.protocol)]
        : ['modern', 'middle', 'legacy'];
    final uuid = _randomUuid();
    for (final b in brands) {
      for (final method in methods) {
        final c = vidaaCreds(uuid, b, method, _now());
        try {
          final m = await _Mqtt.open(tv.host, clientId: c.cid, user: c.user, pass: c.pass);
          _save({'uuid': uuid, 'cid': c.cid, 'user': c.user, 'b': b, 'm': method});
          _start(m, c.cid, paired: false);
          return;
        } on _Refused {
          continue;
        }
      }
    }

    // 3. טלוויזיות ישנות – שם משתמש וסיסמה קבועים
    final cid = '${uuid.replaceAll(':', '').toUpperCase()}\$vidaa_common';
    final m = await _Mqtt.open(tv.host,
        clientId: cid, user: 'hisenseservice', pass: 'multimqttservice');
    _save({'uuid': uuid, 'cid': cid, 'user': 'hisenseservice', 'm': 'static'});
    _start(m, cid, paired: true);
  }

  void _start(_Mqtt m, String cid, {required bool paired, bool refresh = false}) {
    if (_disposed) {
      m.close();
      return;
    }
    _m = m;
    _cid = cid;
    m.onPublish = _onMsg;
    m.onDone = () => _onClosed(m);
    final mob = '/remoteapp/mobile/$cid';
    m.subscribe([
      '/remoteapp/mobile/broadcast/ui_service/state',
      '/remoteapp/mobile/broadcast/ui_service/volume',
      '/remoteapp/mobile/broadcast/platform_service/actions/volumechange',
      '$mob/ui_service/data/authentication',
      '$mob/ui_service/data/authenticationcode',
      '$mob/ui_service/data/vidaa_app_connect',
      '$mob/ui_service/data/applist',
      '$mob/ui_service/data/sourcelist',
      '$mob/ui_service/data/gettvstate',
      '$mob/ui_service/data/state',
      '$mob/platform_service/data/tokenissuance',
    ]);
    if (refresh) {
      _pub(_t('platform_service', 'gettoken', kind: 'data'), {'refreshtoken': _st()['rt'] ?? ''});
    }
    if (paired) {
      _ready();
      _pub(_t('ui_service', 'gettvstate'));
      vidaaInfo(tv.host).then((i) {
        final merged = mergeMacs(tv.mac, [i?.mac]);
        if (merged != null && !_disposed) {
          tv.mac = merged;
          onSave();
        }
      });
    } else {
      // מבקשים מהטלוויזיה להציג קוד
      _pub(_t('ui_service', 'vidaa_app_connect'),
          {'app_version': 2, 'connect_result': 0, 'device_type': 'Mobile App'});
      _pinTimer?.cancel();
      _pinTimer = Timer(const Duration(seconds: 3), () {
        if (_m == m && status == TvStatus.connecting) _set(TvStatus.pairing);
      });
    }
  }

  void _ready() {
    _pinTimer?.cancel();
    _codeTimer?.cancel();
    _tokenTimer?.cancel();
    _fails = 0;
    powered ??= true;
    _set(TvStatus.ready);
    final items = List.of(_pending);
    _pending.clear();
    for (final f in items) {
      f();
    }
  }

  dynamic _json(String p) {
    try {
      var v = jsonDecode(p);
      if (v is String && (v.startsWith('{') || v.startsWith('['))) v = jsonDecode(v);
      return v;
    } catch (_) {
      return null;
    }
  }

  void _onMsg(String topic, String payload) {
    final j = _json(payload);
    final map = j is Map ? Map<String, dynamic>.from(j) : <String, dynamic>{};

    if (topic.endsWith('/data/authenticationcode')) {
      _codeTimer?.cancel();
      if ('${map['result']}' == '1') {
        _pub(_t('platform_service', 'gettoken', kind: 'data'), {'refreshtoken': ''});
        _pub(_t('ui_service', 'authenticationcodeclose'));
        _tokenTimer?.cancel();
        _tokenTimer = Timer(const Duration(seconds: 4), () {
          if (!isReady && _m != null) _ready();
        });
      } else {
        _set(TvStatus.pairing, err: 'הקוד שגוי. בדוק את המספר שעל המסך ונסה שוב');
      }
      return;
    }
    if (topic.endsWith('/data/authentication')) {
      if (status == TvStatus.connecting && !isReady) {
        _pinTimer?.cancel();
        _set(TvStatus.pairing);
      }
      return;
    }
    if (topic.endsWith('/data/tokenissuance')) {
      final at = map['accesstoken']?.toString();
      if (at != null && at.isNotEmpty) {
        final now = _now();
        int days(Object? v, int d) => int.tryParse('$v') ?? d;
        final st = _st()
          ..['at'] = at
          ..['ate'] = now + days(map['accesstoken_duration_day'], 7) * 86400;
        final rt = map['refreshtoken']?.toString();
        if (rt != null && rt.isNotEmpty) {
          st['rt'] = rt;
          st['rte'] = now + days(map['refreshtoken_duration_day'], 30) * 86400;
        }
        _save(st);
        if (!isReady) _ready();
      }
      return;
    }
    if (topic.endsWith('/data/applist')) {
      final w = _appsWait;
      if (w != null && !w.isCompleted) w.complete(j is List ? j : (map['applist'] is List ? map['applist'] : const []));
      return;
    }
    if (topic.endsWith('/data/sourcelist')) {
      final list = j is List ? j : const [];
      _sources = [
        for (final s in list)
          if (s is Map && s['sourceid'] != null) '${s['sourceid']}'
      ];
      final w = _srcWait;
      if (w != null && !w.isCompleted) w.complete();
      return;
    }
    if (topic.contains('volume')) {
      if ('${map['volume_type']}' == '2') {
        muted = '${map['volume_value']}' == '1';
        notifyListeners();
      }
      return;
    }
    if (topic.endsWith('/state') || topic.endsWith('/gettvstate')) {
      final s = map['statetype']?.toString();
      if (s == null) return;
      if (s.startsWith('fake_sleep')) {
        powered = false;
      } else if (s == 'authentication' && _st()['m'] == 'static' && status != TvStatus.pairing) {
        _set(TvStatus.pairing);
        return;
      } else {
        powered = true;
      }
      notifyListeners();
    }
  }

  // ---------- צימוד ----------

  @override
  bool submitCode(String input) {
    final code = input.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(code) || _m == null) return false;
    _pub(_t('ui_service', 'authenticationcode'), {'authNum': int.parse(code)});
    _set(TvStatus.connecting);
    _codeTimer?.cancel();
    _codeTimer = Timer(const Duration(seconds: 8), () {
      if (status == TvStatus.connecting) {
        _set(TvStatus.pairing, err: 'הטלוויזיה לא ענתה. נסה שוב, או לחץ "קוד חדש"');
      }
    });
    return true;
  }

  @override
  void repair() {
    _save({});
    _fails = 0;
    if (!_connecting) connect();
  }

  // ---------- פקודות ----------

  void _whenReady(void Function() f) {
    if (isReady && _m != null) {
      f();
      return;
    }
    if (_pending.length < 6) _pending.add(f);
    if (status == TvStatus.offline || status == TvStatus.error) {
      _fails = 0;
      connect();
    }
  }

  void _key(String k) => _whenReady(() => _pub(_t('remote_service', 'sendkey'), k));

  static const _keys = {
    K.home: 'KEY_HOME', K.back: 'KEY_RETURNS', K.up: 'KEY_UP', K.down: 'KEY_DOWN',
    K.left: 'KEY_LEFT', K.right: 'KEY_RIGHT', K.ok: 'KEY_OK', K.enter: 'KEY_OK',
    K.volUp: 'KEY_VOLUMEUP', K.volDown: 'KEY_VOLUMEDOWN', K.mute: 'KEY_MUTE',
    K.chUp: 'KEY_CHANNELUP', K.chDown: 'KEY_CHANNELDOWN', K.menu: 'KEY_MENU',
    K.settings: 'KEY_MENU', K.power: 'KEY_POWER', K.period: 'KEY_CHANNELDOT',
  };

  @override
  void sendKey(int code, {int direction = 3}) {
    if (direction == 1) return; // שולחים רק "לחיצה" אחת
    if (code >= 7 && code <= 16) {
      _key('KEY_${code - 7}');
      return;
    }
    if (code >= 243 && code <= 246) {
      _source('${code - 240}'); // HDMI 1–4 = 3–6
      return;
    }
    switch (code) {
      case K.playPause:
        _playing = !_playing;
        _key(_playing ? 'KEY_PLAY' : 'KEY_PAUSE');
        return;
      case K.tv:
        _source('0');
        return;
      case K.input:
        _nextSource();
        return;
      case K.del:
        if (_typed.isNotEmpty) sendText(_typed.substring(0, _typed.length - 1));
        return;
    }
    final k = _keys[code];
    if (k != null) _key(k);
  }

  void _source(String id) =>
      _whenReady(() => _pub(_t('ui_service', 'changesource'), {'sourceid': id}));

  void _nextSource() => _whenReady(() async {
        if (_sources.isEmpty) {
          _srcWait = Completer<void>();
          _pub(_t('ui_service', 'sourcelist'));
          await _srcWait!.future.timeout(const Duration(seconds: 3), onTimeout: () {});
        }
        if (_sources.isEmpty) {
          _source(_srcIdx++ % 2 == 0 ? '3' : '0');
          return;
        }
        _srcIdx = (_srcIdx + 1) % _sources.length;
        _source(_sources[_srcIdx]);
      });

  // ---------- הקלדה ----------

  void _txt(String text, String action) => _whenReady(() {
        final p = {'text': text, 'action': action};
        _pub(_t('platform_service', 'txtinputdata'), p);
        _pub(_t('platform_service', 'bwsinputdata'), p);
      });

  // כל הטקסט נשלח בהודעה אחת (מסך ההקלדה מחכה שמפסיקים להקליד)
  String _sent = '';

  @override
  void textReset() {
    _typed = '';
    _sent = '';
  }

  @override
  void clearText(int count) {
    if (_sent.isNotEmpty) _txt('', 'clear');
    textReset();
  }

  @override
  void sendText(String text) {
    _typed = text;
    if (text == _sent) return;
    if (_sent.isNotEmpty) _txt('', 'clear');
    if (text.isNotEmpty) _txt(text, 'insert');
    _sent = text;
  }

  // ---------- אפליקציות ----------

  @override
  String launchApp(String appId) {
    Map<String, dynamic> p;
    if (appId.startsWith('{')) {
      final d = _json(appId);
      p = d is Map ? Map<String, dynamic>.from(d) : {'name': appId, 'urlType': 37, 'storeType': 0, 'url': appId};
    } else {
      p = _appCache[appId] ??
          {
            'name': switch (appId) {
              'youtube' => 'YouTube',
              'netflix' => 'Netflix',
              _ => appId,
            },
            'urlType': 37,
            'storeType': 0,
            'url': appId,
          };
    }
    _whenReady(() => _pub(_t('ui_service', 'launchapp'), p));
    return 'link';
  }

  @override
  Future<List<({String id, String name})>> installedApps() async {
    if (!await waitReady()) return const [];
    _appsWait = Completer<List>();
    _pub(_t('ui_service', 'applist'));
    final items =
        await _appsWait!.future.timeout(const Duration(seconds: 6), onTimeout: () => const []);
    final list = <({String id, String name})>[];
    for (final a in items) {
      if (a is! Map) continue;
      final m = Map<String, dynamic>.from(a);
      final name = (m['name'] ?? m['url'] ?? '').toString();
      final url = m['url']?.toString();
      if (name.isEmpty) continue;
      final simple = url != null &&
          url.isNotEmpty &&
          '${m['urlType'] ?? 37}' == '37' &&
          '${m['storeType'] ?? 0}' == '0';
      final p = {
        'name': name,
        'urlType': m['urlType'] ?? 37,
        'storeType': m['storeType'] ?? 0,
        'url': url ?? '',
        if (m['appId'] != null) 'appId': m['appId'],
      };
      final id = simple ? url! : jsonEncode(p);
      _appCache[id] = p;
      list.add((id: id, name: name));
    }
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  @override
  Future<String> searchIn(AppButton app, String query, {bool preferLink = true}) async {
    final id = app.idFor('vidaa');
    if (!await waitReady()) return 'offline';
    if (app.isYoutubeOn('vidaa')) {
      final v = await findYoutubeVideo(query);
      if (v != null && await _dialYoutube(v)) return 'video';
      launchApp(id.isEmpty ? 'youtube' : id);
      return v == null ? 'novideo' : 'opened';
    }
    if (id.isNotEmpty) launchApp(id);
    return 'opened';
  }

  /// מנגן סרטון ביוטיוב שבטלוויזיה – כמו "שידור" מהטלפון (DIAL)
  Future<bool> _dialYoutube(String videoId) =>
      dialLaunch(tv.host, 'YouTube', body: 'v=$videoId', ports: const [56789, 56790, 36866, 8008]);

  // ---------- הדלקה ----------

  @override
  Future<String> power() async {
    if (isReady || await waitReady(ms: 3000)) {
      final wasOn = powered != false;
      _key('KEY_POWER');
      powered = !wasOn;
      notifyListeners();
      return wasOn ? 'off' : 'on';
    }
    final mac = tv.mac;
    if (mac == null) return 'unreachable';
    final ok = await wakeOnLan(mac, tv.host);
    for (final s in [4, 8, 12, 18]) {
      Timer(Duration(seconds: s), () {
        if (!_disposed && !isReady && canSend) connect();
      });
    }
    return ok ? 'waking' : 'unreachable';
  }

  // ---------- כללי ----------

  @override
  Future<bool> waitReady({int ms = 7000}) async {
    if (isReady) return true;
    if (!canSend) return false;
    if (status == TvStatus.offline || status == TvStatus.error) {
      _fails = 0;
      connect();
    }
    return waitFor(() => isReady, ms);
  }

  void _onClosed(_Mqtt m) {
    if (_m != m) return;
    _m = null;
    _pinTimer?.cancel();
    _codeTimer?.cancel();
    _tokenTimer?.cancel();
    if (_disposed || status == TvStatus.error) return;
    if (status == TvStatus.ready) {
      _set(TvStatus.offline);
      return;
    }
    if (status == TvStatus.pairing) {
      _set(TvStatus.pairing, err: 'הבקשה פגה. לחץ "קוד חדש"');
      return;
    }
    _scheduleRetry('החיבור נסגר');
  }

  void _scheduleRetry(String? err) {
    if (_disposed) return;
    _fails++;
    _set(_fails > 2 ? TvStatus.error : TvStatus.connecting, err: err);
    _retry?.cancel();
    _retry = Timer(Duration(seconds: min(20, max(2, _fails * 3))), connect);
  }

  void _closeMqtt() {
    final m = _m;
    _m = null;
    _pinTimer?.cancel();
    _codeTimer?.cancel();
    _tokenTimer?.cancel();
    m?.close();
  }

  @override
  void disconnect() {
    _retry?.cancel();
    _closeMqtt();
    _set(TvStatus.offline);
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _closeMqtt();
    super.dispose();
  }
}
