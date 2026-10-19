import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// שמירת ההגדרות בקובץ בטלפון (במקום התוסף shared_preferences, שלא עבד בגרסה הזו)
class Prefs {
  final File _file;
  final Map<String, dynamic> _data;
  Prefs._(this._file, this._data);

  static Prefs? _inst;

  static Future<Prefs> getInstance() async {
    final cached = _inst;
    if (cached != null) return cached;
    final dir = await _findDir();
    final f = File('${dir.path}/settings.json');
    var d = <String, dynamic>{};
    for (final path in [f.path, '${f.path}.bak']) {
      try {
        final x = File(path);
        if (await x.exists()) {
          d = Map<String, dynamic>.from(jsonDecode(await x.readAsString()) as Map);
          break;
        }
      } catch (_) {}
    }
    return _inst = Prefs._(f, d);
  }

  /// תיקייה פרטית של האפליקציה שאפשר לכתוב בה
  static Future<Directory> _findDir() async {
    final candidates = <String>[];
    if (Platform.isAndroid) {
      var pkg = 'il.lior.tcl_remote';
      try {
        final cmd = await File('/proc/self/cmdline').readAsString();
        final name = cmd.split('\u0000').first.split(':').first.trim();
        if (name.isNotEmpty) pkg = name;
      } catch (_) {}
      candidates.addAll(['/data/user/0/$pkg/files/tcl', '/data/data/$pkg/files/tcl']);
    } else {
      final home = Platform.environment['HOME'];
      if (home != null) candidates.add('$home/Library/Application Support/tcl');
    }
    candidates.add('${Directory.systemTemp.path}/tcl');
    for (final c in candidates) {
      try {
        final d = Directory(c);
        await d.create(recursive: true);
        final t = File('$c/.w');
        await t.writeAsString('1', flush: true);
        return d;
      } catch (_) {}
    }
    return Directory.systemTemp;
  }

  Future<bool> _chain = Future.value(true);

  Future<bool> _save() {
    final text = jsonEncode(_data);
    return _chain = _chain.then((_) async {
      try {
        final tmp = File('${_file.path}.tmp');
        await tmp.writeAsString(text, flush: true);
        if (await _file.exists()) {
          try {
            await _file.copy('${_file.path}.bak');
          } catch (_) {}
        }
        await tmp.rename(_file.path);
        return true;
      } catch (_) {
        return false;
      }
    });
  }

  String? getString(String k) {
    final v = _data[k];
    return v is String ? v : null;
  }

  bool? getBool(String k) {
    final v = _data[k];
    return v is bool ? v : null;
  }

  int? getInt(String k) {
    final v = _data[k];
    return v is int ? v : null;
  }

  Future<bool> setString(String k, String v) {
    _data[k] = v;
    return _save();
  }

  Future<bool> setBool(String k, bool v) {
    _data[k] = v;
    return _save();
  }

  Future<bool> setInt(String k, int v) {
    _data[k] = v;
    return _save();
  }

  Future<bool> remove(String k) {
    _data.remove(k);
    return _save();
  }
}

/// סוגי טלוויזיות: 'atv' – Android TV / Google TV (TCL ועוד), 'samsung', 'lg', 'vidaa' – טושיבה / הייסנס
const brands = ['atv', 'samsung', 'lg', 'vidaa'];

String brandName(String b) => switch (b) {
      'samsung' => 'Samsung',
      'lg' => 'LG',
      'vidaa' => 'Toshiba / VIDAA',
      _ => 'TCL / Android TV',
    };

class TvDevice {
  final String id;
  String name;
  String host;
  bool paired;
  String? mac; // להדלקה דרך הרשת
  String brand;
  String? token; // אישור החיבור (סמסונג / LG)
  TvDevice(
      {required this.id,
      required this.name,
      required this.host,
      this.paired = false,
      this.mac,
      this.brand = 'atv',
      this.token});

  String get brandLabel => switch (brand) {
        'samsung' => 'SAMSUNG',
        'lg' => 'LG',
        'vidaa' => 'TOSHIBA',
        _ => 'TCL',
      };

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'paired': paired,
        'mac': mac,
        'brand': brand,
        'token': token,
      };
  factory TvDevice.fromJson(Map<String, dynamic> j) => TvDevice(
      id: j['id'],
      name: j['name'],
      host: j['host'],
      paired: j['paired'] == true,
      mac: j['mac'],
      brand: brands.contains(j['brand']) ? j['brand'] : 'atv',
      token: j['token']);
}

/// מזהי אפליקציות ידועים בסמסונג וב-LG
const _brandAppIds = {
  'samsung': {
    'youtube': '111299001912',
    'netflix': '3201907018807',
    'spotify': '3201606009684',
  },
  'lg': {
    'youtube': 'youtube.leanback.v4',
    'netflix': 'netflix',
    'spotify': 'spotify-beehive',
  },
  'vidaa': {
    'youtube': 'youtube',
    'netflix': 'netflix',
  },
};

class AppButton {
  final String id;
  String label;
  final int color;
  String package; // Android TV
  final Map<String, String> ids; // מזהים בסמסונג / LG שהמשתמש בחר
  AppButton(this.id, this.label, this.color, this.package, [Map<String, String>? ids])
      : ids = ids ?? {};

  Map<String, dynamic> toJson() =>
      {'id': id, 'label': label, 'color': color, 'package': package, 'ids': ids};
  factory AppButton.fromJson(Map<String, dynamic> j) => AppButton(
      j['id'],
      j['label'],
      j['color'],
      j['package'] ?? '',
      j['ids'] is Map ? Map<String, String>.from((j['ids'] as Map).map((k, v) => MapEntry('$k', '$v'))) : null);

  /// מזהה האפליקציה בסוג הטלוויזיה הנתון
  String idFor(String brand) {
    if (brand == 'atv') return package;
    final own = ids[brand];
    if (own != null && own.isNotEmpty) return own;
    return _brandAppIds[brand]?[id] ?? '';
  }

  bool isYoutubeOn(String brand) => id == 'youtube' || idFor(brand) == _brandAppIds[brand]?['youtube'] ||
      package == 'com.google.android.youtube.tv';

  /// קישור לפתיחת האפליקציה בטלוויזיה
  String get link => package.contains('://') ? package : 'market://launch?id=$package';
}

List<AppButton> defaultApps() => [
      AppButton('freetv', 'FreeTV', 0xFFFF8A1F, 'tv.freetv.androidtv'),
      AppButton('spotify', 'Spotify', 0xFF1ED760, 'com.spotify.tv.android'),
      AppButton('youtube', 'YouTube', 0xFFFF3B3B, 'com.google.android.youtube.tv'),
      AppButton('netflix', 'Netflix', 0xFFE50914, 'com.netflix.ninja'),
    ];

class Store {
  final Prefs prefs;
  Store(this.prefs);

  List<TvDevice> loadTvs() {
    final s = prefs.getString('tvs');
    if (s == null) return [];
    return (jsonDecode(s) as List).map((e) => TvDevice.fromJson(e)).toList();
  }

  Future<void> saveTvs(List<TvDevice> tvs) =>
      prefs.setString('tvs', jsonEncode(tvs.map((t) => t.toJson()).toList()));

  List<AppButton> loadApps() {
    final s = prefs.getString('apps');
    if (s == null) return defaultApps();
    final list = (jsonDecode(s) as List).map((e) => AppButton.fromJson(e)).toList();
    if (prefs.getBool('apps_v2') == true) return _v3(list);
    // עדכון חד-פעמי של הגדרות ישנות
    for (var i = 0; i < list.length; i++) {
      final a = list[i];
      // מחליפים את Spotify הישן ב-Netflix
      if (a.id == 'spotify' && a.package == 'com.spotify.tv.android') {
        list[i] = AppButton('netflix', 'Netflix', 0xFFE50914, 'com.netflix.ninja');
      }
      // מזהים נכונים ל-FreeTV ולסלקום (מחליפים ניסיונות קודמים)
      if (a.id == 'freetv' && (a.package.isEmpty || a.package.contains('freetv'))) {
        a.package = 'tv.freetv.androidtv';
      }
      if (a.id == 'cellcom' && (a.package.isEmpty || a.package.contains('cellcom'))) {
        a.package = 'com.cellcom.cellcom_tv';
      }
    }
    saveApps(list);
    prefs.setBool('apps_v2', true);
    return _v3(list);
  }

  /// עדכון חד-פעמי: Cellcom tv מוחלף ב-Spotify
  List<AppButton> _v3(List<AppButton> list) {
    if (prefs.getBool('apps_v3') == true) return list;
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == 'cellcom') {
        list[i] = AppButton('spotify', 'Spotify', 0xFF1ED760, 'com.spotify.tv.android');
      }
    }
    saveApps(list);
    prefs.setBool('apps_v3', true);
    return list;
  }

  Future<void> saveApps(List<AppButton> apps) =>
      prefs.setString('apps', jsonEncode(apps.map((a) => a.toJson()).toList()));

  String? get selected => prefs.getString('selected');
  set selected(String? id) =>
      id == null ? prefs.remove('selected') : prefs.setString('selected', id);
}


/// כתובות MAC תקינות מתוך טקסט (אפשר כמה, מופרדות בפסיק)
List<String> macList(String? s) => [
      for (final m in (s ?? '').toUpperCase().replaceAll('-', ':').split(RegExp(r'[,;\s]+')))
        if (RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(m)) m
    ];

/// מוסיף כתובות שנמצאו לכתובות הקיימות. null אם לא השתנה כלום
String? mergeMacs(String? old, Iterable<String?> found) {
  final list = macList(old);
  var changed = false;
  for (final f in found) {
    for (final m in macList(f)) {
      if (m == '00:00:00:00:00:00' || list.contains(m)) continue;
      list.add(m);
      changed = true;
    }
  }
  return changed ? list.join(',') : null;
}
