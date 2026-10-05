import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class TvDevice {
  final String id;
  String name;
  String host;
  bool paired;
  TvDevice({required this.id, required this.name, required this.host, this.paired = false});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'host': host, 'paired': paired};
  factory TvDevice.fromJson(Map<String, dynamic> j) => TvDevice(
      id: j['id'], name: j['name'], host: j['host'], paired: j['paired'] == true);
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
      AppButton('freetv', 'FreeTV', 0xFFFF8A1F, ''),
      AppButton('cellcom', 'Cellcom tv', 0xFFB07CFF, ''),
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
    return (jsonDecode(s) as List).map((e) => AppButton.fromJson(e)).toList();
  }

  Future<void> saveApps(List<AppButton> apps) =>
      prefs.setString('apps', jsonEncode(apps.map((a) => a.toJson()).toList()));

  String? get selected => prefs.getString('selected');
  set selected(String? id) =>
      id == null ? prefs.remove('selected') : prefs.setString('selected', id);
}
