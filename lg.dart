// טלוויזיות LG (webOS) – WebSocket בפורט 3001 (מוצפן) או 3000
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'atv/connection.dart' show wakeOnLan;
import 'atv/keys.dart';
import 'remote.dart';
import 'store.dart';

const _lgSignature = 'eyJhbGdvcml0aG0iOiJSU0EtU0hBMjU2Iiwia2V5SWQiOiJ0ZXN0LXNpZ25pbmctY2VydCIsInNpZ25hdHVyZVZlcnNpb24iOjF9.hrVRgjCwXVvE2OOSpDZ58hR+59aFNwYDyjQgKk3auukd7pcegmE2CzPCa0bJ0ZsRAcKkCTJrWo5iDzNhMBWRyaMOv5zWSrthlf7G128qvIlpMT0YNY+n/FaOHE73uLrS/g7swl3/qH/BGFG2Hu4RlL48eb3lLKqTt2xKHdCs6Cd4RMfJPYnzgvI4BNrFUKsjkcu+WD4OO2A27Pq1n50cMchmcaXadJhGrOqH5YmHdOCj5NSHzJYrsW0HPlpuAx/ECMeIZYDh6RMqaFM2DXzdKX9NmmyqzJ3o/0lkk/N97gfVRLW5hA29yeAwaCViZNCP8iC9aO0q9fQojoa7NQnAtw==';
const _lgPermissions = ['LAUNCH', 'LAUNCH_WEBAPP', 'APP_TO_APP', 'CLOSE', 'TEST_OPEN', 'TEST_PROTECTED', 'CONTROL_AUDIO', 'CONTROL_DISPLAY', 'CONTROL_INPUT_JOYSTICK', 'CONTROL_INPUT_MEDIA_RECORDING', 'CONTROL_INPUT_MEDIA_PLAYBACK', 'CONTROL_INPUT_TV', 'CONTROL_POWER', 'READ_APP_STATUS', 'READ_CURRENT_CHANNEL', 'READ_INPUT_DEVICE_LIST', 'READ_NETWORK_STATE', 'READ_RUNNING_APPS', 'READ_TV_CHANNEL_LIST', 'WRITE_NOTIFICATION_TOAST', 'READ_POWER_STATE', 'READ_COUNTRY_INFO', 'READ_SETTINGS', 'CONTROL_TV_SCREEN', 'CONTROL_TV_STANBY', 'CONTROL_FAVORITE_GROUP', 'CONTROL_USER_INFO', 'CHECK_BLUETOOTH_DEVICE', 'CONTROL_BLUETOOTH', 'CONTROL_TIMER_INFO', 'STB_INTERNAL_CONNECTION', 'CONTROL_RECORDING', 'READ_RECORDING_STATE', 'WRITE_RECORDING_LIST', 'READ_RECORDING_LIST', 'READ_RECORDING_SCHEDULE', 'WRITE_RECORDING_SCHEDULE', 'READ_STORAGE_DEVICE_LIST', 'READ_TV_PROGRAM_INFO', 'CONTROL_BOX_CHANNEL', 'READ_TV_ACR_AUTH_TOKEN', 'READ_TV_CONTENT_STATE', 'READ_TV_CURRENT_TIME', 'ADD_LAUNCHER_CHANNEL', 'SET_CHANNEL_SKIP', 'RELEASE_CHANNEL_SKIP', 'CONTROL_CHANNEL_BLOCK', 'DELETE_SELECT_CHANNEL', 'CONTROL_CHANNEL_GROUP', 'SCAN_TV_CHANNELS', 'CONTROL_TV_POWER', 'CONTROL_WOL'];
const _lgSignedPermissions = ['TEST_SECURE', 'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD', 'READ_INSTALLED_APPS', 'READ_LGE_SDX', 'READ_NOTIFICATIONS', 'SEARCH', 'WRITE_SETTINGS', 'WRITE_NOTIFICATION_ALERT', 'CONTROL_POWER', 'READ_CURRENT_CHANNEL', 'READ_RUNNING_APPS', 'READ_UPDATE_INFO', 'UPDATE_FROM_REMOTE_APP', 'READ_LGE_TV_INPUT_EVENTS', 'READ_TV_CURRENT_TIME'];

Map<String, dynamic> _registerPayload(String? key) => {
      'forcePairing': false,
      'pairingType': 'PROMPT',
      if (key != null) 'client-key': key,
      'manifest': {
        'appVersion': '1.1',
        'manifestVersion': 1,
        'permissions': _lgPermissions,
        'signatures': [
          {'signature': _lgSignature, 'signatureVersion': 1}
        ],
        'signed': {
          'appId': 'com.lge.test',
          'created': '20140509',
          'localizedAppNames': {
            '': 'LG Remote App',
            'ko-KR': '리모컨 앱',
            'zxx-XX': 'ЛГ Rэмotэ AПП',
          },
          'localizedVendorNames': {'': 'LG Electronics'},
          'permissions': _lgSignedPermissions,
          'serial': '2f930e2d2cfe083771f68e4fe7bb07',
          'vendorId': 'com.lge',
        },
      },
    };

class LgConnection extends TvRemote {
  @override
  final TvDevice tv;
  final VoidCallback onSave;
  LgConnection(this.tv, this.onSave);

  @override
  TvStatus status = TvStatus.offline;
  @override
  String? error;
  @override
  bool? powered;
  @override
  bool? muted;

  WebSocket? _ws;
  WebSocket? _ptr;
  Future<WebSocket?>? _ptrOpening;
  Timer? _retry;
  Timer? _promptTimer;
  int _fails = 0;
  int _seq = 0;
  bool _disposed = false;
  bool _playing = false;
  bool _keyRejected = false;
  String _typed = '';
  final _waiters = <String, Completer<Map<String, dynamic>>>{};
  final _pending = <void Function()>[];

  void _set(TvStatus s, {String? err}) {
    if (_disposed) return;
    status = s;
    error = err;
    notifyListeners();
  }

  @override
  bool get canSend => status != TvStatus.approve;

  Future<WebSocket> _open() async {
    try {
      return await WebSocket.connect('wss://${tv.host}:3001/', customClient: tvHttpClient())
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      return await WebSocket.connect('ws://${tv.host}:3000/').timeout(const Duration(seconds: 8));
    }
  }

  @override
  Future<void> connect() async {
    _retry?.cancel();
    _promptTimer?.cancel();
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
      ws.add(jsonEncode({'type': 'register', 'id': 'reg0', 'payload': _registerPayload(tv.token)}));
      _promptTimer = Timer(const Duration(seconds: 2), () {
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
    final type = m['type'];
    final id = '${m['id']}';
    final payload = m['payload'] is Map ? Map<String, dynamic>.from(m['payload']) : <String, dynamic>{};

    if (id == 'reg0') {
      if (type == 'registered') {
        _promptTimer?.cancel();
        final key = payload['client-key']?.toString();
        if (key != null && key.isNotEmpty && key != tv.token) {
          tv.token = key;
          onSave();
        }
        _fails = 0;
        _keyRejected = false;
        powered = true;
        _set(TvStatus.ready);
        final items = List.of(_pending);
        _pending.clear();
        for (final f in items) {
          f();
        }
        _afterConnect();
      } else if (type == 'response' && payload['pairingType'] == 'PROMPT') {
        _promptTimer?.cancel();
        _set(TvStatus.approve);
      } else if (type == 'error') {
        _promptTimer?.cancel();
        if (tv.token != null && !_keyRejected) {
          // המפתח הישן נדחה – מבקשים אישור חדש
          _keyRejected = true;
          tv.token = null;
          onSave();
          connect();
        } else {
          _close();
          _set(TvStatus.error, err: 'החיבור לא אושר בטלוויזיה – נסה שוב');
        }
      }
      return;
    }

    final w = _waiters.remove(id);
    if (w != null && !w.isCompleted) {
      w.complete({'ok': type == 'response' && payload['returnValue'] != false, ...payload});
    }
  }

  Future<void> _afterConnect() async {
    // מצב הקול
    final v = await _request('ssap://audio/getVolume');
    if (v['ok'] == true) {
      final mutedNow = v['muted'] ?? (v['volumeStatus'] is Map ? v['volumeStatus']['muteStatus'] : null);
      if (mutedNow is bool) {
        muted = mutedNow;
        notifyListeners();
      }
    }
    // כתובת MAC להדלקה
    if (tv.mac == null) {
      final info = await _request('ssap://com.webos.service.connectionmanager/getinfo');
      String? mac;
      for (final k in ['wifiInfo', 'wiredInfo']) {
        final x = info[k];
        if (x is Map && x['macAddress'] is String && (x['macAddress'] as String).length >= 17) {
          mac = (x['macAddress'] as String).toUpperCase();
          break;
        }
      }
      if (mac != null) {
        tv.mac = mac;
        onSave();
      }
    }
    _pointer();
  }

  Future<Map<String, dynamic>> _request(String uri, [Map<String, dynamic>? payload]) {
    final ws = _ws;
    if (ws == null || !isReady) return Future.value({'ok': false});
    final id = 'r${++_seq}';
    final c = Completer<Map<String, dynamic>>();
    _waiters[id] = c;
    try {
      ws.add(jsonEncode({
        'type': 'request',
        'id': id,
        'uri': uri,
        if (payload != null) 'payload': payload,
      }));
    } catch (_) {
      _waiters.remove(id);
      return Future.value({'ok': false});
    }
    return c.future.timeout(const Duration(seconds: 6), onTimeout: () {
      _waiters.remove(id);
      return {'ok': false};
    });
  }

  /// מבצע מיד אם מחובר, אחרת שומר ומתחבר מחדש
  void _whenReady(void Function() f) {
    if (isReady && _ws != null) {
      f();
      return;
    }
    if (_pending.length < 3) _pending.add(f);
    if (status == TvStatus.offline || status == TvStatus.error) {
      _fails = 0;
      connect();
    }
  }

  void _call(String uri, [Map<String, dynamic>? payload]) => _whenReady(() => _request(uri, payload));

  // ---------- מקשי השלט (ערוץ "עכבר" נפרד) ----------

  Future<WebSocket?> _pointer() {
    if (_ptr != null) return Future.value(_ptr);
    return _ptrOpening ??= () async {
      try {
        final r = await _request('ssap://com.webos.service.networkinput/getPointerInputSocket');
        final path = r['socketPath']?.toString();
        if (path == null || path.isEmpty) return null;
        final p = await WebSocket.connect(path, customClient: tvHttpClient())
            .timeout(const Duration(seconds: 6));
        p.listen((_) {}, onDone: () {
          if (_ptr == p) _ptr = null;
        }, onError: (_) {
          if (_ptr == p) _ptr = null;
        }, cancelOnError: true);
        _ptr = p;
        return p;
      } catch (_) {
        return null;
      } finally {
        _ptrOpening = null;
      }
    }();
  }

  void _button(String name) => _whenReady(() async {
        final p = await _pointer();
        try {
          p?.add('type:button\nname:$name\n\n');
        } catch (_) {
          _ptr = null;
        }
      });

  static const _buttons = {
    K.home: 'HOME', K.back: 'BACK', K.up: 'UP', K.down: 'DOWN', K.left: 'LEFT',
    K.right: 'RIGHT', K.ok: 'ENTER', K.volUp: 'VOLUMEUP', K.volDown: 'VOLUMEDOWN',
    K.mute: 'MUTE', K.chUp: 'CHANNELUP', K.chDown: 'CHANNELDOWN', K.menu: 'MENU',
    K.settings: 'MENU', K.star: 'ASTERISK', K.minus: 'DASH',
  };

  @override
  void sendKey(int code, {int direction = 3}) {
    if (code >= 7 && code <= 16) {
      _button('${code - 7}');
      return;
    }
    if (code >= 243 && code <= 246) {
      _call('ssap://tv/switchInput', {'inputId': 'HDMI_${code - 242}'});
      return;
    }
    switch (code) {
      case K.playPause:
        _playing = !_playing;
        _button(_playing ? 'PLAY' : 'PAUSE');
        return;
      case K.power:
        _call('ssap://system/turnOff');
        return;
      case K.input:
        _call('ssap://system.launcher/launch', {'id': 'com.webos.app.inputpicker'});
        return;
      case K.tv:
        _call('ssap://system.launcher/launch', {'id': 'com.webos.app.livetv'});
        return;
      case K.enter:
        _call('ssap://com.webos.service.ime/sendEnterKey');
        return;
      case K.del:
        _call('ssap://com.webos.service.ime/deleteCharacters', {'count': 1});
        if (_typed.isNotEmpty) _typed = _typed.substring(0, _typed.length - 1);
        return;
      case 224:
        return;
    }
    final b = _buttons[code];
    if (b != null) _button(b);
  }

  @override
  void textReset() => _typed = '';

  @override
  void clearText(int count) => sendText('');

  /// LG רק מוסיפה טקסט – מחשבים מה למחוק ומה להוסיף לעומת מה שכבר נכתב
  @override
  void sendText(String text) {
    var same = 0;
    while (same < text.length && same < _typed.length && text[same] == _typed[same]) {
      same++;
    }
    final del = _typed.length - same;
    final add = text.substring(same);
    _typed = text;
    if (del > 0) _call('ssap://com.webos.service.ime/deleteCharacters', {'count': del});
    if (add.isNotEmpty) _call('ssap://com.webos.service.ime/insertText', {'text': add, 'replace': 0});
  }

  // ---------- אפליקציות ----------

  @override
  String launchApp(String appId) {
    _call('ssap://system.launcher/launch', {'id': appId});
    return 'link';
  }

  @override
  Future<String> searchIn(AppButton app, String query, {bool preferLink = true}) async {
    final id = app.idFor('lg');
    if (!await waitReady()) return 'offline';
    if (app.isYoutubeOn('lg')) {
      final v = await findYoutubeVideo(query);
      final yt = id.isEmpty ? 'youtube.leanback.v4' : id;
      if (v == null) {
        launchApp(yt);
        return 'novideo';
      }
      _call('ssap://system.launcher/launch', {
        'id': yt,
        'params': {'contentTarget': 'https://www.youtube.com/tv?v=$v'},
      });
      return 'video';
    }
    launchApp(id);
    return 'opened';
  }

  @override
  Future<List<({String id, String name})>> installedApps() async {
    if (!await waitReady()) return const [];
    final r = await _request('ssap://com.webos.applicationManager/listLaunchPoints');
    var items = r['launchPoints'];
    if (items is! List) {
      final r2 = await _request('ssap://com.webos.applicationManager/listApps');
      items = r2['apps'];
    }
    final list = <({String id, String name})>[];
    if (items is List) {
      for (final a in items) {
        if (a is Map && a['id'] != null) {
          list.add((id: a['id'].toString(), name: (a['title'] ?? a['id']).toString()));
        }
      }
    }
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  // ---------- הדלקה ----------

  @override
  Future<String> power() async {
    if (isReady) {
      _call('ssap://system/turnOff');
      return 'off';
    }
    if (await waitReady(ms: 3000)) {
      _call('ssap://system/turnOff');
      return 'off';
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

  @override
  void repair() {
    tv.token = null;
    onSave();
    _fails = 0;
    connect();
  }

  void _onClosed(WebSocket ws) {
    if (_ws != ws) return;
    _ws = null;
    _closePointer();
    _promptTimer?.cancel();
    if (_disposed || status == TvStatus.error) return;
    if (status == TvStatus.ready) {
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

  void _closePointer() {
    final p = _ptr;
    _ptr = null;
    try {
      p?.close();
    } catch (_) {}
  }

  void _close() {
    final w = _ws;
    _ws = null;
    _closePointer();
    for (final c in _waiters.values) {
      if (!c.isCompleted) c.complete({'ok': false});
    }
    _waiters.clear();
    try {
      w?.close();
    } catch (_) {}
  }

  @override
  void disconnect() {
    _retry?.cancel();
    _promptTimer?.cancel();
    _close();
    _set(TvStatus.offline);
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _promptTimer?.cancel();
    _close();
    super.dispose();
  }
}
