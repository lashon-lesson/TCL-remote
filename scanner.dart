// חיפוש טלוויזיות ברשת: בודק אילו כתובות פותחות את פורט השלט (6466)
import 'dart:async';
import 'dart:io';
import 'dart:math';

Future<List<String>> scanForTvs({void Function(double)? onProgress}) async {
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
  final found = <String>[];
  var done = 0;
  const batch = 48;
  for (var i = 0; i < hosts.length; i += batch) {
    final chunk = hosts.sublist(i, min(i + batch, hosts.length));
    await Future.wait(chunk.map((ip) async {
      try {
        final s = await Socket.connect(ip, 6466,
            timeout: const Duration(milliseconds: 700));
        s.destroy();
        found.add(ip);
      } catch (_) {}
    }));
    done += chunk.length;
    onProgress?.call(done / hosts.length);
  }
  found.sort((a, b) =>
      int.parse(a.split('.').last).compareTo(int.parse(b.split('.').last)));
  return found;
}
