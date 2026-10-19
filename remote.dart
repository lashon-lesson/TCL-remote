// שכבה משותפת לכל סוגי הטלוויזיות: Android TV / Google TV (TCL), סמסונג, LG ו-VIDAA (טושיבה)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'store.dart';

/// approve – מחכים שיאשרו את החיבור על מסך הטלוויזיה (סמסונג / LG)
enum TvStatus { offline, connecting, pairing, approve, ready, error }

abstract class TvRemote extends ChangeNotifier {
  TvDevice get tv;
  TvStatus get status;
  String? get error;
  bool? get powered;
  bool? get muted;

  bool get isReady => status == TvStatus.ready;

  /// אפשר לשלוח פקודות (מחובר, או שאפשר להתחבר מחדש אוטומטית)
  bool get canSend;

  /// הטלוויזיה מדווחת מתי נפתח בה שדה הקלדה (רק ב-Android TV)
  bool get reportsIme => false;
  bool get imeActive => false;

  String get brandLabel => tv.brandLabel;

  Future<void> connect();
  void disconnect();

  /// צימוד / אישור מחדש
  void repair();

  /// הצימוד נעשה בהקלדת קוד שמופיע על הטלוויזיה (Android TV, VIDAA)
  bool get usesCode => false;
  int get codeLength => 6;
  bool get codeHex => true;

  /// הטלוויזיה בודקת את הקוד בעצמה – מחכים לתשובה לפני שסוגרים את החלון
  bool get codeChecksLater => false;

  /// שולח את הקוד שהוקלד. false אם הקוד לא תקין
  bool submitCode(String input) => false;

  /// מקש לפי קודי המקשים של Android (K.*) – כל סוג טלוויזיה מתרגם לשפה שלו
  void sendKey(int code, {int direction = 3});

  /// כותב טקסט בשדה שפתוח בטלוויזיה (הטקסט המלא, מחליף את מה שנכתב קודם)
  void sendText(String text);

  /// מתחילים הקלדה חדשה (שדה ריק)
  void textReset() {}

  /// פותח אפליקציה לפי המזהה שלה בטלוויזיה הזו. 'link' / 'store'
  String launchApp(String appId);

  /// מחפש באפליקציה. 'link' / 'typed' / 'video' / 'opened' / 'novideo' / 'no_field' / 'offline'
  Future<String> searchIn(AppButton app, String query, {bool preferLink = true});

  Future<bool> waitReady({int ms = 7000});

  /// 'on' / 'off' / 'waking' / 'unreachable'
  Future<String> power();

  /// רשימת האפליקציות המותקנות (סמסונג / LG)
  Future<List<({String id, String name})>> installedApps() async => const [];

  Future<bool> waitFor(bool Function() test, int ms) async {
    for (var t = 0; t < ms ~/ 200; t++) {
      if (test()) return true;
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return test();
  }
}

/// מוצא ביוטיוב את הסרטון הראשון שמתאים לחיפוש (מהטלפון)
Future<String?> findYoutubeVideo(String query) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await client.getUrl(Uri.parse(
        'https://www.youtube.com/results?search_query=${Uri.encodeQueryComponent(query)}&hl=he&gl=IL'));
    req.headers.set('User-Agent',
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36');
    req.headers.set('Accept-Language', 'he-IL,he;q=0.9,en;q=0.8');
    final res = await req.close().timeout(const Duration(seconds: 10));
    final body = await res
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(const Duration(seconds: 12));
    final m = RegExp(r'"videoId":"([A-Za-z0-9_-]{11})"').firstMatch(body);
    return m?.group(1);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// לקוח HTTP שמקבל את התעודה העצמית של הטלוויזיה
HttpClient tvHttpClient() => HttpClient()
  ..connectionTimeout = const Duration(seconds: 5)
  ..badCertificateCallback = (cert, host, port) => true;
