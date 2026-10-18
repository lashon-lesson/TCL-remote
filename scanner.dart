// חיפוש טלוויזיות ברשת: Android TV (פורט 6466), סמסונג (8001) ו-LG (3000/3001)
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'samsung.dart';

typedef FoundTv = ({String ip, String brand, String name});

Future<bool> _open(String ip, int port, {int ms = 700}) async {
  try {
    final s = await Socket.connect(ip, port, timeout: Duration(milliseconds: ms));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// מזהה איזה סוג טלוויזיה נמצא בכתובת, או null אם לא נמצאה
Future<FoundTv?> detectTv(String ip, {int ms = 700}) async {
  final r = await Future.wait([
    _open(ip, 6466, ms: ms),
    _open(ip, 8001, ms: ms),
    _open(ip, 3000, ms: ms),
    _open(ip, 3001, ms: ms),
  ]);
  if (r[1]) {
    final info = await samsungInfo(ip);
    if (info != null) return (ip: ip, brand: 'samsung', name: info.name);
  }
  if (r[0]) return (ip: ip, brand: 'atv', name: '');
  if (r[2] || r[3]) return (ip: ip, brand: 'lg', name: 'LG TV');
  return null;
}

Future<List<FoundTv>> scanForTvs({void Function(double)? onProgress}) async {
  final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4, includeLoopback: false);

  bool isPrivate(String ip) =>
      ip.startsWith('192.168.') ||
      ip.startsWith('10.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
  bool isWifi(String name) =>
      name.startsWith('wlan') || name.startsWith('en') || name.startsWith('eth');

  final prefixes = <String>{};
  for (final wifiOnly in [true, false]) {
    for (final i in ifaces) {
      if (wifiOnly && !isWifi(i.name)) continue;
      for (final a in i.addresses) {
        if (!isPrivate(a.address)) continue;
        final p = a.address.split('.');
        prefixes.add('${p[0]}.${p[1]}.${p[2]}');
      }
    }
    if (prefixes.isNotEmpty) break;
  }

  final hosts = [
    for (final p in prefixes)
      for (var n = 1; n < 255; n++) '$p.$n'
  ];
  final found = <FoundTv>[];
  var done = 0;
  const batch = 32;
  for (var i = 0; i < hosts.length; i += batch) {
    final chunk = hosts.sublist(i, min(i + batch, hosts.length));
    await Future.wait(chunk.map((ip) async {
      final t = await detectTv(ip);
      if (t != null) found.add(t);
    }));
    done += chunk.length;
    onProgress?.call(done / hosts.length);
  }
  found.sort((a, b) =>
      int.parse(a.ip.split('.').last).compareTo(int.parse(b.ip.split('.').last)));
  return found;
}
