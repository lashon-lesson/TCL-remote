// טלוויזיות סמסונג (Tizen, 2016 ואילך) – WebSocket בפורט 8002 (מוצפן) או 8001 (דגמים ישנים)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'atv/connection.dart' show wakeOnLan;
import 'atv/keys.dart';
import 'remote.dart';
import 'store.dart';

/// פרטי טלוויזיית סמסונג (שם, MAC), או null אם זו לא סמסונג
Future<({String name, String? mac, bool on})?> samsungInfo(String host) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final req = await client
        .getUrl(Uri.parse('http://$host:8001/api/v2/'))
        .timeout(const Duration(seconds: 3));
    final res = await req.close().timeout(const Duration(seconds: 3));
    final body = await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 3));
    final j = jsonDecode(body) as Map<String, dynamic>;
    final d = (j['device'] ?? {}) as Map<String, dynamic>;
    final name = (d['name'] ?? j['name'] ?? 'Samsung TV').toString();
    final mac = d['wifiMac']?.toString();
    final on = (d['PowerState'] ?? 'on').toString().toLowerCase() == 'on';
    return (name: name, mac: (mac == null || mac.isEmpty) ? null : mac.toUpperCase(), on: on);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

class SamsungConnection extends TvRemote {
  @override
  final TvDevice tv;
  final VoidCallback onSave;
  SamsungConnection(this.tv, this.onSave);

  @override
  TvStatus status = TvStatus.offline;
  @override
  String? error;
  @override
  bool? powered;
  @override
  bool? muted;

  WebSocket? _ws;
  Timer? _retry;
  Timer? _authTimer;
  int _fails = 0;
  bool _disposed = false;
  bool _playing = false;
  Completer<List<({String id, String name})>>? _appsWaiter;
  final _pending = <String>[];

  static final _name = base64.encode(utf8.encode('Phone Remote'));

  void _set(TvStatus s, {String? err}) {
    if (_disposed) return;
    status = s;
    error = err;
    notifyListeners();
  }

  @override
  bool get canSend => status != TvStatus.approve;

  Future<WebSocket> _open() async {
    final token = tv.token == null ? '' : '&token=${tv.token}';
    try {
      return await WebSocket.connect(
        'wss://${tv.host}:8002/api/v2/channels/samsung.remote.control?name=$_name$token',
        customClient: tvHttpClient(),
      ).timeout(const Duration(seconds: 8));
    } catch (_) {
      // דגמים ישנים (2016–2017) – בלי הצפנה
      return await WebSocket.connect(
        'ws://${tv.host}:8001/api/v2/channels/samsung.remote.control?name=$_name',
      ).timeout(const Duration(seconds: 8));
    }
  }

  @override
  Future<void> connect() async {
    _retry?.cancel();
    _authTimer?.cancel();
    _close();
    if (_disposed) return;
    _set(TvStatus.connecting);
    try {
      final ws = await _open();
      if (_disposed) {
        ws.close();
        return;
      }
      _ws = ws;
      ws.pingInterval = const Duration(seconds: 20);
      ws.listen(_onMsg,
          onDone: () => _onClosed(ws), onError: (_) => _onClosed(ws), cancelOnError: true);
      // אם הטלוויזיה לא אישרה מיד – כנראה מוצגת עליה בקשת אישור
      _authTimer = Timer(const Duration(milliseconds: 1500), () {
        if (status == TvStatus.connecting && _ws == ws) _set(TvStatus.approve);
      });
    } catch (_) {
      _scheduleRetry('הטלוויזיה לא עונה – בדוק שהיא דלוקה ושהכתובת נכונה');
    }
  }

  void _onMsg(dynamic raw) {
    Map<String, dynamic> m;
    try {
      m = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final event = m['event'];
    final data = m['data'];
    switch (event) {
      case 'ms.channel.connect':
        _authTimer?.cancel();
        final token = data is Map ? data['token']?.toString() : null;
        if (token != null && token.isNotEmpty && token != tv.token) {
          tv.token = token;
          onSave();
        }
        _fails = 0;
        powered = true;
        _set(TvStatus.ready);
        final items = List.of(_pending);
        _pending.clear();
        for (final p in items) {
          try {
            _ws?.add(p);
          } catch (_) {}
        }
        _refreshMac();
        break;
      case 'ms.channel.unauthorized':
        _authTimer?.cancel();
        tv.token = null;
        onSave();
        _close();
        _set(TvStatus.error,
            err: 'הטלוויזיה חסמה את החיבור. בטלוויזיה: הגדרות ← כללי ← מנהל התקנים חיצוניים ← רשימת התקנים, ואפשר את "Phone Remote"');
        break;
      case 'ms.channel.timeOut':
        _authTimer?.cancel();
        _close();
        _set(TvStatus.error, err: 'לא אושר בזמן בטלוויזיה – נסה שוב');
        break;
      case 'ed.installedApp.get':
        final list = <({String id, String name})>[];
        final items = data is Map ? data['data'] : null;
        if (items is List) {
          for (final a in items) {
            if (a is Map && a['appId'] != null) {
              list.add((id: a['appId'].toString(), name: (a['name'] ?? a['appId']).toString()));
            }
          }
        }
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        _appsWaiter?.complete(list);
        _appsWaiter = null;
        break;
    }
  }

  Future<void> _refreshMac() async {
    final info = await samsungInfo(tv.host);
    final merged = mergeMacs(tv.mac, [info?.mac]);
    if (merged != null) {
      tv.mac = merged;
      onSave();
    }
  }

  void _onClosed(WebSocket ws) {
    if (_ws != ws) return;
    _ws = null;
    _authTimer?.cancel();
    if (_disposed || status == TvStatus.error) return;
    if (status == TvStatus.ready) {
      // מתחברים שוב כשמשתמשים בשלט
      _set(TvStatus.offline);
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

  void _send(Map<String, dynamic> msg) {
    final data = jsonEncode(msg);
    if (isReady && _ws != null) {
      try {
        _ws!.add(data);
        return;
      } catch (_) {}
    }
    if (_pending.length < 3) _pending.add(data);
    if (status == TvStatus.offline || status == TvStatus.error) {
      _fails = 0;
      connect();
    }
  }

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

  @override
  void repair() {
    tv.token = null;
    onSave();
    _fails = 0;
    connect();
  }

  // ---------- פקודות ----------

  void _remoteKey(String key) => _send({
        'method': 'ms.remote.control',
        'params': {
          'Cmd': 'Click',
          'DataOfCmd': key,
          'Option': 'false',
          'TypeOfRemote': 'SendRemoteKey',
        }
      });

  static const _keys = {
    K.home: 'KEY_HOME', K.back: 'KEY_RETURN', K.up: 'KEY_UP', K.down: 'KEY_DOWN',
    K.left: 'KEY_LEFT', K.right: 'KEY_RIGHT', K.ok: 'KEY_ENTER', K.enter: 'KEY_ENTER',
    K.volUp: 'KEY_VOLUP', K.volDown: 'KEY_VOLDOWN', K.mute: 'KEY_MUTE',
    K.chUp: 'KEY_CHUP', K.chDown: 'KEY_CHDOWN', K.menu: 'KEY_TOOLS', K.settings: 'KEY_MENU',
    K.input: 'KEY_SOURCE', K.tv: 'KEY_TV', K.power: 'KEY_POWER', K.search: 'KEY_HOME',
    243: 'KEY_HDMI1', 244: 'KEY_HDMI2', 245: 'KEY_HDMI3', 246: 'KEY_HDMI4',
  };

  @override
  void sendKey(int code, {int direction = 3}) {
    if (code == K.playPause) {
      _playing = !_playing;
      _remoteKey(_playing ? 'KEY_PLAY' : 'KEY_PAUSE');
      return;
    }
    if (code >= 7 && code <= 16) {
      _remoteKey('KEY_${code - 7}');
      return;
    }
    if (code == 224) return; // "הדלקה" כשהטלוויזיה כבר מחוברת – אין צורך
    final k = _keys[code];
    if (k != null) _remoteKey(k);
  }

  @override
  void sendText(String text) {
    if (text.isEmpty) return;
    _send({
      'method': 'ms.remote.control',
      'params': {
        'Cmd': base64.encode(utf8.encode(text)),
        'DataOfCmd': 'base64',
        'TypeOfRemote': 'SendInputString',
      }
    });
  }

  @override
  Future<String> power() async {
    if (isReady) {
      _remoteKey('KEY_POWER');
      return 'off';
    }
    // אולי הטלוויזיה במצב המתנה ועדיין עונה
    if (await waitReady(ms: 3000)) {
      _remoteKey('KEY_POWER');
      return 'off';
    }
    final mac = tv.mac;
    if (mac == null) return 'unreachable';
    final ok = await wakeOnLan(mac, tv.host);
    for (final s in [3, 6, 10, 15]) {
      Timer(Duration(seconds: s), () {
        if (!_disposed && !isReady && canSend) connect();
      });
    }
    return ok ? 'waking' : 'unreachable';
  }

  void _launch(String appId, {String? metaTag}) {
    _send({
      'method': 'ms.channel.emit',
      'params': {
        'event': 'ed.apps.launch',
        'to': 'host',
        'data': {
          'appId': appId,
          'action_type': appId.contains('.') ? 'NATIVE_LAUNCH' : 'DEEP_LINK',
          if (metaTag != null) 'metaTag': metaTag,
        },
      }
    });
  }

  @override
  String launchApp(String appId) {
    // קודם דרך REST (הכי אמין), ואם נכשל – דרך החיבור הפתוח
    () async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      var ok = false;
      try {
        final req = await client.postUrl(Uri.parse('http://${tv.host}:8001/api/v2/applications/$appId'));
        final res = await req.close().timeout(const Duration(seconds: 4));
        await res.drain();
        ok = res.statusCode >= 200 && res.statusCode < 300;
      } catch (_) {
      } finally {
        client.close(force: true);
      }
      if (!ok) _launch(appId);
    }();
    return 'link';
  }

  @override
  Future<String> searchIn(AppButton app, String query, {bool preferLink = true}) async {
    final id = app.idFor('samsung');
    if (!await waitReady()) return 'offline';
    if (app.isYoutubeOn('samsung')) {
      final v = await findYoutubeVideo(query);
      if (v == null) {
        launchApp(id);
        return 'novideo';
      }
      _launch(id.isEmpty ? '111299001912' : id, metaTag: 'v=$v');
      return 'video';
    }
    launchApp(id);
    return 'opened';
  }

  @override
  Future<List<({String id, String name})>> installedApps() async {
    if (!await waitReady()) return const [];
    _appsWaiter?.complete(const []);
    final c = Completer<List<({String id, String name})>>();
    _appsWaiter = c;
    _send({
      'method': 'ms.channel.emit',
      'params': {'event': 'ed.installedApp.get', 'to': 'host'}
    });
    return c.future.timeout(const Duration(seconds: 6), onTimeout: () {
      if (_appsWaiter == c) _appsWaiter = null;
      return const [];
    });
  }

  // ---------- כללי ----------

  void _close() {
    final w = _ws;
    _ws = null;
    try {
      w?.close();
    } catch (_) {}
  }

  @override
  void disconnect() {
    _retry?.cancel();
    _authTimer?.cancel();
    _close();
    _set(TvStatus.offline);
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _authTimer?.cancel();
    _close();
    super.dispose();
  }
}
