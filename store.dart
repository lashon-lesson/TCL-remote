import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class TvDevice {
  final String id;
  String name;
  String host;
  bool paired;
  String? mac; // להדלקה דרך הרשת
  TvDevice({required this.id, required this.name, required this.host, this.paired = false, this.mac});

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'host': host, 'paired': paired, 'mac': mac};
  factory TvDevice.fromJson(Map<String, dynamic> j) => TvDevice(
      id: j['id'], name: j['name'], host: j['host'], paired: j['paired'] == true, mac: j['mac']);
}

class AppButton {
  final String id;
  String label;
  final int color;
  String package;
  AppButton(this.id, this.label, this.color, this.package);

  Map<String, dynamic> toJson() => {'id': id, 'label': label, 'color': color, 'package': package};
  factory AppButton.fromJson(Map<String, dynamic> j) =>
      AppButton(j['id'], j['label'], j['color'], j['package'] ?? '');

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
  final SharedPreferences prefs;
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
