import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import 'atv/connection.dart';
import 'atv/identity.dart';
import 'atv/keys.dart';
import 'build_info.dart';
import 'lg.dart';
import 'remote.dart';
import 'samsung.dart';
import 'scanner.dart';
import 'store.dart';
import 'vidaa.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
  runApp(const RemoteApp());
}

class C {
  static const bg = Color(0xFF0D0E11);
  static const body = Color(0xFF1B1C20);
  static const body2 = Color(0xFF16171B);
  static const btn = Color(0xFF24252A);
  static const sheet = Color(0xFF1C1D22);
  static const field = Color(0xFF121317);
  static const line = Color(0xFF33353C);
  static const text = Color(0xFFE9EAEE);
  static const muted = Color(0xFF8B8E97);
  static const red = Color(0xFFFF4D4F);
  static const green = Color(0xFF22D38A);
  static const blue = Color(0xFF5AA2FF);
  static const amber = Color(0xFFFFB020);
}

class RemoteApp extends StatelessWidget {
  const RemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'שלט־על',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: C.bg,
        colorScheme: const ColorScheme.dark(primary: C.green, surface: C.sheet),
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const RemoteHome(),
    );
  }
}

class RemoteHome extends StatefulWidget {
  const RemoteHome({super.key});
  @override
  State<RemoteHome> createState() => _RemoteHomeState();
}

class _RemoteHomeState extends State<RemoteHome> with WidgetsBindingObserver {
  Store? store;
  Identity? identity;
  List<TvDevice> tvs = [];
  List<AppButton> apps = [];
  final conns = <String, TvRemote>{};
  String? sel;
  String? _pairPromptFor;

  TvRemote? get cur => sel == null ? null : conns[sel];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final c in conns.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkUpdate();
      for (final c in conns.values) {
        if (!c.isReady && c.status != TvStatus.pairing && c.status != TvStatus.approve) c.connect();
      }
    }
  }

  String? _initError;
  int _initSecs = 0;
  Timer? _initTimer;

  Future<void> _init() async {
    _initTimer?.cancel();
    _initSecs = 0;
    _initError = null;
    _initTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || identity != null) {
        t.cancel();
        return;
      }
      setState(() => _initSecs++);
    });
    try {
      await _initInner();
    } catch (e) {
      _initTimer?.cancel();
      if (mounted) setState(() => _initError = '$e');
    }
  }

  Future<void> _initInner() async {
    final prefs = await Prefs.getInstance();
    final s = Store(prefs);
    tvs = s.loadTvs();
    apps = s.loadApps();
    sel = s.selected;
    final id = await Identity.loadOrCreate(prefs);
    if (id.regenerated) {
      // זהות חדשה לטלפון – צימוד אחד מחדש לכל טלוויזיה
      for (final tv in tvs) {
        tv.paired = false;
      }
      await s.saveTvs(tvs);
    }
    if (!mounted) return;
    setState(() {
      store = s;
      identity = id;
      if (sel == null || !tvs.any((t) => t.id == sel)) {
        sel = tvs.isEmpty ? null : tvs.first.id;
      }
    });
    for (final tv in tvs) {
      _open(tv);
    }
    if (tvs.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showTvSheet());
    }
    _checkUpdate();
  }

  void _open(TvDevice tv) {
    void save() => store!.saveTvs(tvs);
    final TvRemote c = switch (tv.brand) {
      'samsung' => SamsungConnection(tv, save),
      'lg' => LgConnection(tv, save),
      'vidaa' => VidaaConnection(tv, save),
      _ => TvConnection(tv, identity!, save),
    };
    c.addListener(() => _onConnChange(c));
    conns[tv.id] = c;
    c.connect();
  }

  void _onConnChange(TvRemote c) {
    if (!mounted) return;
    setState(() {});
    if (c.tv.id == sel &&
        (c.status == TvStatus.pairing || c.status == TvStatus.approve) &&
        _pairPromptFor != c.tv.id) {
      _pairPromptFor = c.tv.id;
      if (c.usesCode && c.status == TvStatus.pairing) {
        _showPairSheet(c);
      } else {
        _showApproveSheet(c);
      }
    }
    if (c.status == TvStatus.ready && _pairPromptFor == c.tv.id) {
      _pairPromptFor = null;
      _toast('${c.tv.name} מחובר');
    }
  }

  void _select(String? id) {
    setState(() {
      sel = id;
      _pairPromptFor = null;
    });
    store?.selected = id;
  }

  // ---------- פעולות ----------

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg, textAlign: TextAlign.center),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2B2D33),
        duration: const Duration(seconds: 2),
      ));
  }

  TvRemote? _need() {
    final c = cur;
    if (c == null) {
      _showTvSheet();
      _toast('הוסף טלוויזיה כדי להתחיל');
      return null;
    }
    if (!c.isReady) {
      if (c.status == TvStatus.pairing && c.usesCode) {
        _showPairSheet(c);
        return null;
      }
      if (c.status == TvStatus.approve) {
        _showApproveSheet(c);
        return null;
      }
      if (c.canSend) {
        // מתחבר מחדש ושולח את הפקודה ברגע שהחיבור מוכן
        if (c.status != TvStatus.connecting) _toast('מתחבר לטלוויזיה…');
        return c;
      }
      _toast('הטלוויזיה לא מחוברת. לחץ על השם שלה למעלה');
      return null;
    }
    return c;
  }

  void _key(int code) {
    final c = _need();
    if (c == null) return;
    HapticFeedback.lightImpact();
    c.sendKey(code);
  }

  Future<void> _power() async {
    final c = cur;
    if (c == null) {
      _need();
      return;
    }
    HapticFeedback.mediumImpact();
    final r = await c.power();
    if (!mounted) return;
    switch (r) {
      case 'on':
        _toast('מדליק את ${c.tv.name}…');
        break;
      case 'waking':
        _toast('נשלחה פקודת הדלקה ל${c.tv.name}. אם לא נדלקה, ראה הוראות ההדלקה בהגדרות הטלוויזיה');
        break;
      case 'unreachable':
        _toast(c.tv.mac == null
            ? 'הטלוויזיה בכיבוי מלא ולא עונה. צריך להפעיל בה "המתנה ברשת" – או להזין כתובת MAC (שם הטלוויזיה למעלה ← ⋮)'
            : 'הטלוויזיה לא עונה. בדוק שהופעלה בה "המתנה ברשת"');
        break;
    }
  }

  void _launch(AppButton a) {
    final c = _need();
    if (c == null) return;
    final id = a.idFor(c.tv.brand);
    if (id.isEmpty) {
      _editApp(a);
      return;
    }
    HapticFeedback.lightImpact();
    final r = c.launchApp(id);
    _toast(r == 'store' ? 'פותח את ${a.label} דרך החנות…' : 'פותח את ${a.label}…');
  }

  // ---------- עדכון גרסה ----------

  static const _repo = 'lashon-lesson/TCL-remote';
  ({int build, String url, String name})? _update;
  DateTime? _lastCheck;

  /// בודק ב-GitHub אם יש גרסה מלאה חדשה (עדכונים קטנים מגיעים לבד דרך Shorebird)
  Future<void> _checkUpdate() async {
    if (!Platform.isAndroid) return;
    final now = DateTime.now();
    if (_lastCheck != null && now.difference(_lastCheck!).inMinutes < 30) return;
    _lastCheck = now;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$_repo/releases/latest'));
      req.headers.set('Accept', 'application/vnd.github+json');
      req.headers.set('User-Agent', 'tcl-remote-app');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return;
      final body = await res.transform(utf8.decoder).join();
      final j = jsonDecode(body) as Map<String, dynamic>;
      final tag = '${j['tag_name'] ?? ''}';
      final b = int.tryParse(tag.replaceAll(RegExp(r'[^0-9]'), ''));
      if (b == null || b <= appBuild) return;
      String? url;
      for (final a in (j['assets'] as List? ?? const [])) {
        if ('${a['name']}'.endsWith('.apk')) {
          url = a['browser_download_url'] as String?;
          break;
        }
      }
      final u = url;
      if (u == null || !mounted) return;
      setState(() => _update = (build: b, url: u, name: '${j['name'] ?? tag}'));
    } catch (_) {
    } finally {
      client.close();
    }
  }

  void _showUpdate() {
    final up = _update;
    if (up == null) return;
    _sheet((ctx, setS) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title('יש גרסה חדשה של השלט'),
          _hint('${up.name}\n\n'
              'לחץ "הורד ועדכן". הקובץ יורד בדפדפן, וכשההורדה מסתיימת לוחצים "פתח" ואז "עדכון". '
              'הטלוויזיות והצימוד נשמרים.'),
          _primary('הורד ועדכן', () async {
            Navigator.pop(ctx);
            final ok = await launchUrl(Uri.parse(up.url), mode: LaunchMode.externalApplication)
                .catchError((_) => false);
            if (!ok && mounted) _toast('לא הצלחתי לפתוח את ההורדה');
          }),
          _ghost('אחר כך', () => Navigator.pop(ctx)),
        ]));
  }

  Widget _updateBanner() => GestureDetector(
        onTap: _showUpdate,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 380),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: const Color(0xFF123526),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: C.green.withAlpha(140)),
          ),
          child: const Row(children: [
            Icon(Icons.system_update, color: C.green, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text('יש גרסה חדשה – לחץ לעדכון',
                  style: TextStyle(color: C.green, fontWeight: FontWeight.w700, fontSize: 14)),
            ),
            Icon(Icons.chevron_left, color: C.green),
          ]),
        ),
      );

  // ---------- חלונות ----------

  Future<void> _sheet(Widget Function(BuildContext, StateSetter) builder) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: C.sheet,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(18, 20, 18,
              MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom + 20),
          child: SingleChildScrollView(child: builder(ctx, setS)),
        ),
      ),
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      );

  Widget _hint(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Text(t, style: const TextStyle(color: C.muted, fontSize: 13.5, height: 1.6)),
      );

  Widget _field(TextEditingController ctl,
      {String? hint,
      bool ltr = false,
      TextInputType? type,
      TextAlign align = TextAlign.start,
      TextStyle? style,
      int? maxLength,
      List<TextInputFormatter>? formatters,
      TextCapitalization caps = TextCapitalization.none,
      bool autofocus = false,
      ValueChanged<String>? onChanged,
      ValueChanged<String>? onSubmit}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: ctl,
        autofocus: autofocus,
        textDirection: ltr ? TextDirection.ltr : null,
        textAlign: align,
        keyboardType: type,
        maxLength: maxLength,
        inputFormatters: formatters,
        textCapitalization: caps,
        autocorrect: false,
        enableSuggestions: false,
        onSubmitted: onSubmit,
        onChanged: onChanged,
        style: style ?? const TextStyle(fontSize: 16),
        decoration: InputDecoration(
          hintText: hint,
          counterText: '',
          filled: true,
          fillColor: C.field,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF3A3D45))),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF3A3D45))),
        ),
      ),
    );
  }

  Widget _primary(String label, VoidCallback? onTap) => SizedBox(
        width: double.infinity,
        height: 46,
        child: FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: C.green,
              foregroundColor: const Color(0xFF06281A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          onPressed: onTap,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
        ),
      );

  Widget _ghost(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: SizedBox(
          width: double.infinity,
          height: 42,
          child: TextButton(
            style: TextButton.styleFrom(
                backgroundColor: C.btn,
                foregroundColor: C.text,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            onPressed: onTap,
            child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
      );

  static const _statusText = {
    TvStatus.ready: 'מחובר',
    TvStatus.connecting: 'מתחבר…',
    TvStatus.pairing: 'ממתין לקוד',
    TvStatus.approve: 'ממתין לאישור בטלוויזיה',
    TvStatus.error: 'שגיאה',
    TvStatus.offline: 'לא מחובר',
  };

  void _showTvSheet() {
    if (identity == null) return;
    final name = TextEditingController();
    final host = TextEditingController();
    var scanning = false;
    double progress = 0;
    List<FoundTv>? found;
    var detecting = false;

    _sheet((ctx, setS) {
      void addTv(String n, String h, String brand) {
        final tv = TvDevice(
            id: DateTime.now().millisecondsSinceEpoch.toRadixString(36),
            name: n.trim().isEmpty ? 'טלוויזיה ${tvs.length + 1}' : n.trim(),
            host: h,
            brand: brand);
        tvs.add(tv);
        store!.saveTvs(tvs);
        _select(tv.id);
        _open(tv);
        Navigator.pop(ctx);
        _toast(brand == 'atv' || brand == 'vidaa'
            ? 'מתחבר… בעוד רגע יופיע קוד על הטלוויזיה'
            : 'מתחבר… אשר את החיבור על מסך הטלוויזיה');
      }

      Future<void> addManual(String n, String h) async {
        h = h.trim();
        if (!RegExp(r'^[\w.-]+$').hasMatch(h)) {
          _toast('כתובת IP לא תקינה');
          return;
        }
        setS(() => detecting = true);
        final t = await detectTv(h, ms: 2000);
        if (!ctx.mounted) return;
        setS(() => detecting = false);
        if (t == null) {
          _toast('לא נמצאה טלוויזיה בכתובת הזו. ודא שהיא דלוקה ובאותה רשת');
          return;
        }
        addTv(n.trim().isEmpty && t.name.isNotEmpty ? t.name : n, h, t.brand);
      }

      return ListenableBuilder(
        listenable: Listenable.merge(conns.values.toList()),
        builder: (ctx, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _title('הטלוויזיות שלי'),
            _hint('בחר טלוויזיה לשליטה, או הוסף חדשה. הטלפון והטלוויזיה צריכים להיות באותה רשת WiFi.'),
            if (tvs.isEmpty) _hint('עדיין לא נוספו טלוויזיות.'),
            for (final tv in tvs) _tvRow(ctx, setS, tv),
            const Divider(color: C.line, height: 28),
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    foregroundColor: C.text,
                    side: const BorderSide(color: C.line),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                onPressed: scanning
                    ? null
                    : () async {
                        setS(() {
                          scanning = true;
                          progress = 0;
                          found = null;
                        });
                        final r = await scanForTvs(onProgress: (p) {
                          if (ctx.mounted) setS(() => progress = p);
                        });
                        if (!ctx.mounted) return;
                        setS(() {
                          scanning = false;
                          found = r;
                        });
                      },
                icon: const Icon(Icons.wifi_find, size: 20),
                label: Text(scanning ? 'מחפש…' : 'חפש טלוויזיות ברשת'),
              ),
            ),
            if (scanning)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(value: progress, color: C.green),
              ),
            if (found != null) ...[
              const SizedBox(height: 10),
              if (found!.where((f) => !tvs.any((t) => t.host == f.ip)).isEmpty)
                _hint('לא נמצאו טלוויזיות חדשות. ודא שהטלוויזיה דלוקה, או הזן כתובת ידנית.'),
              for (final f in found!.where((f) => !tvs.any((t) => t.host == f.ip)))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    tileColor: const Color(0xFF24252B),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    leading: const Icon(Icons.tv, color: C.green),
                    title: Text(f.name.isEmpty ? brandName(f.brand) : '${f.name} · ${brandName(f.brand)}'),
                    subtitle: Text(f.ip,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.right,
                        style: const TextStyle(color: C.muted, fontSize: 12)),
                    trailing: const Text('הוסף', style: TextStyle(color: C.green)),
                    onTap: () => addTv(name.text.trim().isEmpty ? f.name : name.text, f.ip, f.brand),
                  ),
                ),
            ],
            const SizedBox(height: 16),
            _hint('או הוספה ידנית (TCL, סמסונג או LG – הסוג מזוהה לבד). את הכתובת מוצאים בהגדרות הרשת של הטלוויזיה.'),
            _field(name, hint: 'שם (למשל: סלון)'),
            _field(host,
                hint: 'כתובת IP (למשל 192.168.1.40)',
                ltr: true,
                type: const TextInputType.numberWithOptions(decimal: true)),
            _primary(detecting ? 'מזהה את הטלוויזיה…' : 'הוסף טלוויזיה',
                detecting ? null : () => addManual(name.text, host.text)),
            _ghost('סגור', () => Navigator.pop(ctx)),
          ],
        ),
      );
    });
  }

  Widget _tvRow(BuildContext ctx, StateSetter setS, TvDevice tv) {
    final c = conns[tv.id];
    final st = c?.status ?? TvStatus.offline;
    final err = st == TvStatus.error && c?.error != null ? ' – ${c!.error}' : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF24252B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tv.id == sel ? C.green : Colors.transparent),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          _select(tv.id);
          Navigator.pop(ctx);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            StatusDot(st),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tv.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text('${brandName(tv.brand)} · ${tv.host}  ${_statusText[st]}$err',
                    style: const TextStyle(color: C.muted, fontSize: 12)),
              ]),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: C.muted),
              color: const Color(0xFF2B2D33),
              onSelected: (v) async {
                if (v == 'name') {
                  _renameTv(tv);
                } else if (v == 're') {
                  c?.connect();
                } else if (v == 'pair') {
                  _pairPromptFor = null;
                  _select(tv.id);
                  c?.repair();
                } else if (v == 'mac') {
                  _editMac(tv);
                } else if (v == 'del') {
                  final ok = await showDialog<bool>(
                    context: ctx,
                    builder: (d) => AlertDialog(
                      backgroundColor: C.sheet,
                      title: Text('למחוק את ${tv.name}?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('ביטול')),
                        TextButton(onPressed: () => Navigator.pop(d, true), child: const Text('מחק', style: TextStyle(color: C.red))),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  conns.remove(tv.id)?.dispose();
                  tvs.remove(tv);
                  store!.saveTvs(tvs);
                  if (sel == tv.id) _select(tvs.isEmpty ? null : tvs.first.id);
                  setS(() {});
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'name', child: Text('שנה שם')),
                PopupMenuItem(value: 're', child: Text('חבר מחדש')),
                PopupMenuItem(value: 'pair', child: Text('צמד / אשר מחדש')),
                PopupMenuItem(value: 'mac', child: Text('כתובת MAC להדלקה')),
                PopupMenuItem(value: 'del', child: Text('מחק')),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  void _showApproveSheet(TvRemote c) {
    var closed = false;
    _sheet((ctx, setS) => ListenableBuilder(
          listenable: c,
          builder: (ctx, _) {
            if (c.isReady && !closed) {
              closed = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ctx.mounted) Navigator.pop(ctx);
              });
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _title('אשר את החיבור בטלוויזיה'),
              _hint(c.tv.brand == 'lg'
                  ? 'על מסך ה-LG הופיעה הודעה שמבקשת לאשר חיבור. בחר "אישור" (Accept) בשלט הרגיל.'
                  : 'על מסך הסמסונג הופיעה הודעה שמבקשת לאשר את "Phone Remote". בחר "אפשר" (Allow) בשלט הרגיל.'),
              const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator(color: C.green)),
              ),
              _hint('אם ההודעה לא הופיעה או נעלמה, לחץ "נסה שוב".'),
              _primary('נסה שוב', () => c.repair()),
              _ghost('סגור', () => Navigator.pop(ctx)),
            ]);
          },
        ));
  }

  void _showPairSheet(TvRemote c) {
    final code = TextEditingController();
    final len = c.codeLength;
    final later = c.codeChecksLater;
    String? err;
    var closed = false;
    _sheet((ctx, setS) => ListenableBuilder(
          listenable: c,
          builder: (ctx, _) {
            if (c.isReady && !closed) {
              closed = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (ctx.mounted) Navigator.pop(ctx);
              });
            }
            void submit() {
              if (c.submitCode(code.text)) {
                if (later) {
                  setS(() => err = null);
                } else {
                  closed = true;
                  Navigator.pop(ctx);
                  _toast('מצמד…');
                }
              } else {
                setS(() => err = later
                    ? 'הקלד את $len הספרות שעל המסך'
                    : c.status == TvStatus.pairing
                        ? 'הקוד לא תואם. בדוק ונסה שוב'
                        : 'הבקשה פגה. לחץ על שם הטלוויזיה ← צמד מחדש');
              }
            }

            final checking = later && c.status == TvStatus.connecting;
            final shown = err ?? (later && c.status == TvStatus.pairing ? c.error : null);
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _title('צימוד ל${c.tv.name}'),
              _hint(c.codeHex
                  ? 'על מסך הטלוויזיה מופיע קוד בן $len תווים. הקלד אותו כאן.'
                  : 'על מסך הטלוויזיה מופיע קוד בן $len ספרות. הקלד אותו כאן.'),
              _field(code,
                  ltr: true,
                  autofocus: true,
                  maxLength: len,
                  align: TextAlign.center,
                  type: c.codeHex ? null : TextInputType.number,
                  caps: TextCapitalization.characters,
                  formatters: [
                    FilteringTextInputFormatter.allow(RegExp(c.codeHex ? '[0-9a-fA-F]' : '[0-9]')),
                    TextInputFormatter.withFunction(
                        (o, n) => n.copyWith(text: n.text.toUpperCase())),
                  ],
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 8),
                  onSubmit: (_) => submit()),
              if (shown != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(shown, style: const TextStyle(color: C.red, fontSize: 13.5)),
                ),
              if (checking)
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: Center(child: CircularProgressIndicator(color: C.green)),
                ),
              _primary('אשר צימוד', submit),
              if (later)
                _ghost('קוד חדש', () {
                  code.clear();
                  setS(() => err = null);
                  c.repair();
                }),
              _ghost('ביטול', () => Navigator.pop(ctx)),
            ]);
          },
        ));
  }

  void _renameTv(TvDevice tv) {
    final name = TextEditingController(text: tv.name);
    void save() {
      final v = name.text.trim();
      if (v.isEmpty) return;
      setState(() => tv.name = v);
      store!.saveTvs(tvs);
    }

    _sheet((ctx, setS) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title('שם הטלוויזיה'),
          _hint('למשל: סלון, חדר שינה, חדר ילדים'),
          _field(name, hint: 'שם', onSubmit: (_) {
            save();
            Navigator.pop(ctx);
          }),
          _primary('שמור', () {
            save();
            Navigator.pop(ctx);
          }),
          _ghost('ביטול', () => Navigator.pop(ctx)),
        ]));
  }

  void _editMac(TvDevice tv) {
    final mac = TextEditingController(text: tv.mac ?? '');
    _sheet((ctx, setS) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title('כתובת MAC של ${tv.name}'),
          _hint('נדרשת רק כדי להדליק טלוויזיה שכבויה לגמרי. בטלוויזיה: הגדרות ← רשת ואינטרנט ← הרשת המחוברת (או: הגדרות ← מערכת ← מידע ← סטטוס) ← "כתובת MAC" של ה-WiFi.'),
          _field(mac, hint: 'AA:BB:CC:DD:EE:FF', ltr: true, caps: TextCapitalization.characters),
          _primary('שמור', () {
            final v = mac.text.trim().toUpperCase().replaceAll('-', ':');
            if (v.isNotEmpty && !RegExp(r'^([0-9A-F]{2}:){5}[0-9A-F]{2}$').hasMatch(v)) {
              _toast('כתובת MAC לא תקינה');
              return;
            }
            tv.mac = v.isEmpty ? null : v;
            store!.saveTvs(tvs);
            Navigator.pop(ctx);
            _toast('נשמר');
          }),
          _ghost('ביטול', () => Navigator.pop(ctx)),
        ]));
  }

  void _showInputs() {
    if (_need() == null) return;
    Widget tile(String label, String sub, IconData icon, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            tileColor: const Color(0xFF24252B),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            leading: Icon(icon, color: C.text),
            title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(sub, style: const TextStyle(color: C.muted, fontSize: 12)),
            onTap: onTap,
          ),
        );

    _sheet((ctx, setS) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title('מקור קלט'),
          _hint('מעבר ישיר לכניסה, או פתיחת תפריט המקורות של הטלוויזיה.'),
          Row(children: [
            for (var n = 1; n <= 4; n++) ...[
              if (n > 1) const SizedBox(width: 8),
              Expanded(
                child: Press(
                  fireOnDown: true,
                  onPress: () {
                    _key(K.hdmi(n));
                    Navigator.pop(ctx);
                    _toast('עובר ל-HDMI $n');
                  },
                  height: 64,
                  decoration: BoxDecoration(color: C.btn, borderRadius: BorderRadius.circular(14)),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('HDMI',
                        style: TextStyle(color: C.muted, fontSize: 11, fontWeight: FontWeight.w700)),
                    Text('$n', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  ]),
                ),
              ),
            ],
          ]),
          const SizedBox(height: 14),
          tile('תפריט מקורות', 'רשימת כל הכניסות של הטלוויזיה – בוחרים עם החיצים ו-OK',
              Icons.list, () {
            _key(K.input);
            Navigator.pop(ctx);
          }),
          tile('חזרה לטלוויזיה החכמה', 'מסך הבית של Google TV', Icons.home_outlined, () {
            _key(K.home);
            Navigator.pop(ctx);
          }),
          _ghost('סגור', () => Navigator.pop(ctx)),
        ]));
  }

  void _showNumpad() {
    _sheet((ctx, setS) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title('מספרים'),
          const SizedBox(height: 8),
          Directionality(
            textDirection: TextDirection.ltr,
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.8,
              children: [
                for (var d = 1; d <= 9; d++) _numKey('$d', K.digit(d)),
                _numKey('⌫', K.del),
                _numKey('0', K.digit(0)),
                _numKey('↵', K.enter),
              ],
            ),
          ),
          _ghost('סגור', () => Navigator.pop(ctx)),
        ]));
  }

  Widget _numKey(String label, int code) => Press(
        fireOnDown: true,
        onPress: () => _key(code),
        decoration: BoxDecoration(color: C.btn, borderRadius: BorderRadius.circular(14)),
        child: Text(label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
      );

  void _showKeyboard() {
    final text = TextEditingController();
    Timer? debounce;
    var sent = '';
    cur?.textReset();

    _sheet((ctx, setS) {
      // טלוויזיות מקבלות רק את ההודעה הראשונה ברצף מהיר – לכן לא שולחים כל אות,
      // אלא את כל הטקסט בהודעה אחת, כשמפסיקים להקליד לרגע (או בלחיצה על חפש)
      bool flush() {
        debounce?.cancel();
        debounce = null;
        final v = text.text;
        final c = cur;
        if (c == null || !c.isReady || v.isEmpty || v == sent) return false;
        sent = v;
        c.sendText(v);
        return true;
      }

      void live(String v) {
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 1000), flush);
      }

      void search() {
        if (flush()) {
          Timer(const Duration(milliseconds: 600), () => _key(K.enter));
        } else {
          _key(K.enter);
        }
      }

      Future<void> asKeys() async {
        final c = _need();
        if (c == null || text.text.isEmpty) return;
        final skipped = <String>{};
        for (final ch in text.text.split('')) {
          final k = K.forChar(ch);
          if (k == null) {
            skipped.add(ch);
            continue;
          }
          c.sendKey(k);
          await Future.delayed(const Duration(milliseconds: 60));
        }
        _toast(skipped.isEmpty ? 'נשלח' : 'נשלח. תווים שלא נתמכים בשיטה הזו: ${skipped.join()}');
      }

      final c = cur;
      return ListenableBuilder(
        listenable: c ?? ValueNotifier(0),
        builder: (ctx, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title('הקלדה בטלוויזיה'),
          _hint('בטלוויזיה עמוד על שדה החיפוש (ביוטיוב, בנטפליקס או בכל אפליקציה) ולחץ OK, כך שהמקלדת של הטלוויזיה תופיע. מה שתקליד כאן יופיע שם מיד, גם בעברית.'),
          if (c?.reportsIme == true) Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              StatusDot(c?.imeActive == true ? TvStatus.ready : TvStatus.connecting),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    c?.imeActive == true
                        ? 'שדה ההקלדה בטלוויזיה מחובר'
                        : 'ממתין לשדה הקלדה בטלוויזיה…',
                    style: const TextStyle(color: C.muted, fontSize: 12.5)),
              ),
            ]),
          ),
          _field(text,
              hint: 'מה לחפש?',
              autofocus: true,
              onChanged: live,
              onSubmit: (_) => search()),
          _hint('הטקסט נשלח לטלוויזיה כשמפסיקים להקליד לשנייה, או בלחיצה על "חפש".'),
          Row(children: [
            Expanded(flex: 2, child: _primary('חפש ↵', search)),
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 46,
                child: TextButton(
                  style: TextButton.styleFrom(
                      backgroundColor: C.btn,
                      foregroundColor: C.text,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                  onPressed: () {
                    final v = text.text;
                    if (v.isEmpty) {
                      _key(K.del);
                      return;
                    }
                    final nv = v.characters.skipLast(1).toString();
                    text.text = nv;
                    if (nv.isEmpty) {
                      debounce?.cancel();
                      final c = cur;
                      if (c != null && sent.isNotEmpty) {
                        c.clearText(sent.length);
                      } else {
                        _key(K.del);
                      }
                      sent = '';
                    } else {
                      live(nv);
                    }
                  },
                  child: const Text('⌫ מחק'),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 6),
          if (c is TvConnection) TextButton(
            onPressed: asKeys,
            child: const Text('הטקסט לא מופיע? שלח כמקשים (אנגלית בלבד)',
                style: TextStyle(color: C.muted, fontSize: 12.5)),
          ),
          _ghost('סגור', () {
            debounce?.cancel();
            Navigator.pop(ctx);
          }),
        ]),
      );
    });
  }

  // ---------- פקודות קוליות ----------

  final _stt = SpeechToText();
  bool _sttReady = false;
  String _heLocale = 'he_IL';
  String _enLocale = 'en_US';
  void Function(String)? _onSttStatus;
  void Function(String)? _onSttError;

  Future<bool> _initStt() async {
    if (_sttReady) return true;
    try {
      _sttReady = await _stt.initialize(
        onStatus: (s) => _onSttStatus?.call(s),
        onError: (e) => _onSttError?.call(e.errorMsg),
      );
    } catch (_) {
      _sttReady = false;
    }
    if (_sttReady) {
      try {
        final ls = await _stt.locales();
        String? pick(String p) {
          for (final l in ls) {
            if (l.localeId.toLowerCase().replaceAll('-', '_').startsWith(p)) return l.localeId;
          }
          return null;
        }

        _heLocale = pick('he') ?? pick('iw') ?? 'he_IL';
        _enLocale = pick('en_us') ?? pick('en') ?? 'en_US';
      } catch (_) {}
    }
    return _sttReady;
  }

  AppButton _searchApp() => apps.firstWhere(
        (a) => a.package == TvConnection.youtubePkg || a.id == 'youtube',
        orElse: () => AppButton('youtube', 'YouTube', 0xFFFF3B3B, TvConnection.youtubePkg),
      );

  /// מבצע פקודה (מדוברת או מוקלדת) ומחזיר תיאור של מה שקרה
  Future<String> _runVoice(String text, String ytMode) async {
    final cmd = VoiceParser.parse(text, apps);
    if (cmd.kind == VoiceKind.unknown) {
      return 'לא הבנתי את הפקודה. נסה למשל: "פתח יוטיוב ומצא שיר של עומר אדם"';
    }
    final c = _need();
    if (c == null) return 'הטלוויזיה לא מחוברת';
    HapticFeedback.lightImpact();

    switch (cmd.kind) {
      case VoiceKind.openApp:
        final a = cmd.app!;
        final id = a.idFor(c.tv.brand);
        if (id.isEmpty) return 'לכפתור ${a.label} עדיין לא הוגדרה אפליקציה. לחיצה ארוכה על הכפתור מגדירה אותה';
        if (!await c.waitReady()) return 'הטלוויזיה לא עונה';
        c.launchApp(id);
        return 'פותח את ${a.label}';

      case VoiceKind.search:
        final a = cmd.app ?? _searchApp();
        if (c.tv.brand == 'atv' && a.package.isEmpty) {
          return 'לכפתור ${a.label} עדיין לא הוגדרה אפליקציה';
        }
        final q = cmd.query!;
        final r = await c.searchIn(a, q, preferLink: ytMode != 'list');
        switch (r) {
          case 'video':
            return 'מנגן ב-YouTube את התוצאה הראשונה ל"$q"';
          case 'novideo':
            return 'פתחתי את YouTube, אבל לא מצאתי תוצאה ל"$q"';
          case 'opened':
            return '${a.label} נפתחה. כאן אפשר לחפש בה דרך Keys';
          case 'link':
            return 'פותח ב-${a.label} את תוצאות החיפוש ל"$q"';
          case 'typed':
            return 'חיפשתי ב-${a.label}: "$q"';
          case 'no_field':
            return '${a.label} נפתחה, אבל שדה החיפוש לא נפתח. נסה שוב, או השתמש ב-Keys.';
          default:
            return 'הטלוויזיה לא עונה';
        }

      case VoiceKind.key:
        for (var i = 0; i < cmd.times; i++) {
          c.sendKey(cmd.key);
          await Future.delayed(const Duration(milliseconds: 130));
        }
        return cmd.label;

      case VoiceKind.channel:
        for (final d in cmd.digits!.split('')) {
          c.sendKey(K.digit(int.parse(d)));
          await Future.delayed(const Duration(milliseconds: 180));
        }
        return 'עובר לערוץ ${cmd.digits}';

      case VoiceKind.powerOff:
        if (c.isReady && c.powered == false) return 'הטלוויזיה כבר כבויה';
        c.sendKey(K.power);
        return 'מכבה את ${c.tv.name}';

      case VoiceKind.powerOn:
        if (c.isReady && c.powered == true) return 'הטלוויזיה כבר דלוקה';
        await _power();
        return 'מדליק את ${c.tv.name}';

      case VoiceKind.unknown:
        return '';
    }
  }

  void _showVoice() {
    if (store == null) return;
    final prefs = store!.prefs;
    final typed = TextEditingController();
    var heard = '';
    var status = 'לחץ על המיקרופון ואמור פקודה';
    var listening = false;
    var busy = false;
    var started = false;
    var closed = false;
    var lang = prefs.getString('voice_lang') ?? 'he';
    var mode = prefs.getString('voice_yt_play') ?? 'play';

    _sheet((ctx, setS) {
      void upd(VoidCallback f) {
        if (!closed && ctx.mounted) setS(f);
      }

      Future<void> run(String text) async {
        if (text.trim().isEmpty || busy) return;
        upd(() {
          busy = true;
          heard = text.trim();
          status = 'מבצע…';
        });
        final r = await _runVoice(text, mode);
        upd(() {
          busy = false;
          status = r;
        });
      }

      Future<void> listen() async {
        if (busy || closed) return;
        if (listening) {
          await _stt.stop();
          upd(() => listening = false);
          return;
        }
        upd(() => status = 'מכין את המיקרופון…');
        if (!await _initStt()) {
          upd(() => status =
              'אין גישה למיקרופון או לזיהוי דיבור. אשר לאפליקציה הרשאת מיקרופון בהגדרות הטלפון ונסה שוב. אפשר גם להקליד פקודה למטה.');
          return;
        }
        var done = false;
        _onSttStatus = (s) {
          if (s == 'done' || s == 'notListening') upd(() => listening = false);
        };
        _onSttError = (m) {
          upd(() {
            listening = false;
            status = (m.contains('no_match') || m.contains('timeout'))
                ? 'לא שמעתי פקודה. לחץ שוב על המיקרופון ודבר'
                : 'שגיאה בזיהוי הדיבור ($m)';
          });
        };
        upd(() {
          listening = true;
          heard = '';
          status = 'מקשיב…';
        });
        HapticFeedback.mediumImpact();
        try {
          await _stt.listen(
            localeId: lang == 'en' ? _enLocale : _heLocale,
            listenFor: const Duration(seconds: 15),
            pauseFor: const Duration(seconds: 3),
            onResult: (r) {
              upd(() => heard = r.recognizedWords);
              if (r.finalResult && !done) {
                done = true;
                upd(() => listening = false);
                run(r.recognizedWords);
              }
            },
          );
        } catch (_) {
          upd(() {
            listening = false;
            status = 'שגיאה בהפעלת המיקרופון';
          });
        }
      }

      if (!started) {
        started = true;
        Future.delayed(const Duration(milliseconds: 350), listen);
      }

      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('פקודות קוליות'),
        _hint('אמור למשל: "פתח יוטיוב ומצא שיר של עומר אדם", "תנגן ביוטיוב שירי ילדים", '
            '"פתח נטפליקס", "תגביר ווליום", "ערוץ 12", "כבה את הטלוויזיה".'),
        Center(
          child: GestureDetector(
            onTap: listen,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: listening ? C.red : const Color(0xFF15283F),
                border: Border.all(color: listening ? C.red : C.blue.withAlpha(130), width: 2),
                boxShadow: listening
                    ? [BoxShadow(color: C.red.withAlpha(110), blurRadius: 28)]
                    : const [],
              ),
              child: busy
                  ? const Padding(
                      padding: EdgeInsets.all(30),
                      child: CircularProgressIndicator(color: C.blue, strokeWidth: 3))
                  : Icon(listening ? Icons.stop_rounded : Icons.mic,
                      size: 44, color: listening ? Colors.white : C.blue),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Text(heard.isEmpty ? '…' : '"$heard"',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text(status,
            textAlign: TextAlign.center,
            style: const TextStyle(color: C.muted, fontSize: 13.5, height: 1.5)),
        const SizedBox(height: 16),
        const Text('שפת הדיבור', style: TextStyle(color: C.muted, fontSize: 12)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
              child: _chip('עברית', lang == 'he', () {
            upd(() => lang = 'he');
            prefs.setString('voice_lang', 'he');
          })),
          const SizedBox(width: 8),
          Expanded(
              child: _chip('English', lang == 'en', () {
            upd(() => lang = 'en');
            prefs.setString('voice_lang', 'en');
          })),
        ]),
        const SizedBox(height: 12),
        const Text('חיפוש ביוטיוב', style: TextStyle(color: C.muted, fontSize: 12)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
              child: _chip('נגן ישר', mode == 'play', () {
            upd(() => mode = 'play');
            prefs.setString('voice_yt_play', 'play');
          })),
          const SizedBox(width: 8),
          Expanded(
              child: _chip('הצג רשימת תוצאות', mode == 'list', () {
            upd(() => mode = 'list');
            prefs.setString('voice_yt_play', 'list');
          })),
        ]),
        const SizedBox(height: 16),
        _field(typed, hint: 'או הקלד פקודה…', onSubmit: (v) {
          run(v);
          typed.clear();
        }),
        _primary('בצע', () {
          run(typed.text);
          typed.clear();
        }),
        _ghost('סגור', () => Navigator.pop(ctx)),
      ]);
    }).whenComplete(() {
      closed = true;
      _onSttStatus = null;
      _onSttError = null;
      if (_stt.isListening) _stt.stop();
    });
  }

  Widget _chip(String label, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? const Color(0xFF123526) : C.btn,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? C.green.withAlpha(140) : Colors.transparent),
          ),
          child: Text(label,
              style: TextStyle(
                  color: on ? C.green : C.text, fontWeight: FontWeight.w700, fontSize: 13)),
        ),
      );

  void _editApp(AppButton a) {
    final c = cur;
    final brand = c?.tv.brand ?? 'atv';
    if (brand != 'atv' && c != null) {
      _pickApp(a, c);
      return;
    }
    _editAppAtv(a);
  }

  /// בחירת אפליקציה מהרשימה שבטלוויזיה (סמסונג / LG)
  void _pickApp(AppButton a, TvRemote c) {
    final brand = c.tv.brand;
    final manual = TextEditingController(text: a.idFor(brand));
    final label = TextEditingController(text: a.label);
    List<({String id, String name})>? list;
    var loading = true;
    var started = false;

    void save(String id) {
      setState(() {
        a.ids[brand] = id.trim();
        if (label.text.trim().isNotEmpty) a.label = label.text.trim();
      });
      store!.saveApps(apps);
      _toast('נשמר. לחיצה ארוכה על הכפתור פותחת שוב את ההגדרה');
    }

    _sheet((ctx, setS) {
      if (!started) {
        started = true;
        c.installedApps().then((r) {
          if (ctx.mounted) {
            setS(() {
              list = r;
              loading = false;
            });
          }
        });
      }
      final current = a.idFor(brand);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('הגדרת ${a.label} ב-${brandName(brand)}'),
        _hint('בחר את האפליקציה מהרשימה של הטלוויזיה.'),
        _field(label, hint: 'שם הכפתור'),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator(color: C.green)),
          )
        else if (list == null || list!.isEmpty)
          _hint('לא הצלחתי לקבל את רשימת האפליקציות מהטלוויזיה. אפשר להזין מזהה ידנית.')
        else
          for (final app in list!)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                tileColor: const Color(0xFF24252B),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                title: Text(app.name),
                subtitle: Text(app.id,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(color: C.muted, fontSize: 11)),
                trailing: app.id == current
                    ? const Text('✓', style: TextStyle(color: C.green, fontSize: 18))
                    : null,
                onTap: () {
                  save(app.id);
                  Navigator.pop(ctx);
                },
              ),
            ),
        const SizedBox(height: 10),
        _field(manual, hint: 'מזהה ידני', ltr: true),
        _primary('שמור', () {
          save(manual.text);
          Navigator.pop(ctx);
        }),
        _ghost('ביטול', () => Navigator.pop(ctx)),
      ]);
    });
  }

  void _editAppAtv(AppButton a) {
    final pkg = TextEditingController(text: a.package);
    final label = TextEditingController(text: a.label);
    _sheet((ctx, setS) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _title('הגדרת ${a.label}'),
          _hint('הזן את מזהה האפליקציה מ-Google Play: בטלפון פותחים את האפליקציה ב-Google Play ← ⋮ ← שיתוף ← העתקת קישור, ומעתיקים את מה שמופיע אחרי id='),
          _field(label, hint: 'שם הכפתור'),
          _field(pkg, hint: 'com.example.app', ltr: true),
          _primary('שמור', () {
            setState(() {
              a.package = pkg.text.trim();
              if (label.text.trim().isNotEmpty) a.label = label.text.trim();
            });
            store!.saveApps(apps);
            Navigator.pop(ctx);
            _toast('נשמר. לחיצה ארוכה על הכפתור פותחת שוב את ההגדרה');
          }),
          _ghost('ביטול', () => Navigator.pop(ctx)),
        ]));
  }

  // ---------- מסך השלט ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: identity == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(28),
                  child: _initError != null
                      ? Column(mainAxisSize: MainAxisSize.min, children: [
                          const Text('⚠️', style: TextStyle(fontSize: 38)),
                          const SizedBox(height: 14),
                          const Text('השלט לא הצליח לעלות',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Text(_initError!,
                              textAlign: TextAlign.center,
                              textDirection: TextDirection.ltr,
                              style: const TextStyle(color: C.muted, fontSize: 12)),
                          const SizedBox(height: 18),
                          _primary('נסה שוב', _init),
                        ])
                      : Column(mainAxisSize: MainAxisSize.min, children: [
                          const CircularProgressIndicator(color: C.green),
                          const SizedBox(height: 16),
                          const Text('מכין את השלט…', style: TextStyle(color: C.muted)),
                          if (_initSecs >= 3) ...[
                            const SizedBox(height: 8),
                            Text('פתיחה ראשונה: יוצר מפתח זיהוי לטלפון ($_initSecs שניות)',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Color(0xFF55585F), fontSize: 12)),
                          ],
                        ]),
                ),
              )
            : Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (_update != null) _updateBanner(),
                    _remote(),
                    const SizedBox(height: 10),
                    Text('גרסה $appVersion · עודכן $appStamp',
                        style: const TextStyle(color: Color(0xFF55585F), fontSize: 10.5)),
                  ]),
                ),
              ),
      ),
    );
  }

  Widget _remote() {
    final c = cur;
    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [C.body, C.body2]),
        borderRadius: BorderRadius.circular(34),
        border: Border.all(color: const Color(0xFF2A2C32)),
        boxShadow: const [BoxShadow(color: Color(0x8C000000), blurRadius: 60, offset: Offset(0, 30))],
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // שורה עליונה
          Row(children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _showTvSheet,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    Text(c?.brandLabel ?? 'TV',
                        style: const TextStyle(
                            color: C.red, fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: 3)),
                    const SizedBox(width: 6),
                    StatusDot(c?.status),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(c?.tv.name ?? 'הוסף טלוויזיה',
                          overflow: TextOverflow.ellipsis,
                          textDirection: TextDirection.rtl,
                          style: const TextStyle(color: C.muted, fontSize: 12)),
                    ),
                  ]),
                ),
              ),
            ),
            _round(Icons.input, _showInputs, 'מקור קלט'),
            const SizedBox(width: 10),
            _round(Icons.settings_outlined, () => _key(K.settings), 'הגדרות'),
            const SizedBox(width: 10),
            Press(
              semantics: 'הדלקה וכיבוי',
              fireOnDown: true,
              onPress: _power,
              width: 44,
              height: 44,
              decoration: c?.isReady == true && c?.powered != false
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF123526),
                      border: Border.all(color: const Color(0xFF1D6B4A)),
                      boxShadow: const [BoxShadow(color: Color(0x5922D38A), blurRadius: 16)],
                    )
                  : BoxDecoration(
                      shape: BoxShape.circle,
                      color: C.btn,
                      border: Border.all(color: C.line),
                    ),
              child: Icon(Icons.power_settings_new,
                  color: c?.isReady == true && c?.powered != false ? C.green : C.muted, size: 20),
            ),
          ]),
          const SizedBox(height: 22),
          const Text('אפליקציות ומקורות',
              textAlign: TextAlign.right,
              textDirection: TextDirection.rtl,
              style: TextStyle(color: C.muted, fontSize: 11)),
          const SizedBox(height: 10),
          for (var r = 0; r < apps.length; r += 2) ...[
            Row(children: [
              Expanded(child: _appBtn(apps[r])),
              const SizedBox(width: 10),
              Expanded(child: r + 1 < apps.length ? _appBtn(apps[r + 1]) : const SizedBox()),
            ]),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 16),
          Center(child: _dpad()),
          const SizedBox(height: 26),
          Row(children: [
            Expanded(child: _rocker('VOL', const Text('+', style: TextStyle(fontSize: 26)), K.volUp,
                const Text('−', style: TextStyle(fontSize: 26)), K.volDown)),
            const SizedBox(width: 12),
            Column(children: [
              _circle(
                Icons.volume_off,
                'MUTE',
                K.mute,
                BoxDecoration(
                  shape: BoxShape.circle,
                  color: c?.muted == true ? C.red : const Color(0xFF5A1C1F),
                  border: Border.all(color: const Color(0xFF8A2A2E)),
                ),
                c?.muted == true ? Colors.white : const Color(0xFFFF7B7D),
              ),
              const SizedBox(height: 10),
              _circle(Icons.play_arrow_rounded, 'PLAY', K.playPause,
                  const BoxDecoration(shape: BoxShape.circle, color: C.btn), C.text),
            ]),
            const SizedBox(width: 12),
            Expanded(child: _rocker('CH', const Icon(Icons.arrow_drop_up, size: 34), K.chUp,
                const Icon(Icons.arrow_drop_down, size: 34), K.chDown)),
          ]),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(child: _navBtn(Icons.arrow_back, 'Back', K.back, C.text, null)),
            const SizedBox(width: 8),
            Expanded(child: _navBtn(Icons.home_outlined, 'Home', K.home, C.green, C.green)),
            const SizedBox(width: 8),
            Expanded(child: _navBtn(Icons.search, 'Search', K.search, C.blue, C.blue)),
            const SizedBox(width: 8),
            Expanded(child: _navBtn(Icons.menu, 'Menu', K.menu, C.amber, C.amber)),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _wideBtn(Icons.dialpad, '123', _showNumpad)),
            const SizedBox(width: 8),
            Expanded(child: _voiceBtn()),
            const SizedBox(width: 8),
            Expanded(child: _wideBtn(Icons.keyboard_outlined, 'Keys', _showKeyboard)),
          ]),
        ]),
      ),
    );
  }

  Widget _round(IconData icon, VoidCallback onTap, String label) => Press(
        semantics: label,
        fireOnDown: true,
        onPress: onTap,
        width: 44,
        height: 44,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: C.btn),
        child: Icon(icon, size: 19, color: C.text),
      );

  Widget _appBtn(AppButton a) {
    final col = Color(a.color);
    return Press(
      semantics: a.label,
      onPress: () => _launch(a),
      onLongPress: () => _editApp(a),
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF1E1F24),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: col.withAlpha(102)),
      ),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(4)),
          child: const Icon(Icons.play_arrow_rounded, size: 14, color: Color(0xFF111111)),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(a.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: col, fontWeight: FontWeight.w700, fontSize: 14)),
        ),
      ]),
    );
  }

  Widget _dpad() {
    Widget arrow(IconData icon, int code, String label) => Press(
          semantics: label,
          fireOnDown: true,
          repeat: true,
          onPress: () => _key(code),
          width: 64,
          height: 64,
          decoration: const BoxDecoration(shape: BoxShape.circle),
          child: Icon(icon, size: 26, color: const Color(0xFFCFD1D6)),
        );

    return SizedBox(
      width: 228,
      height: 228,
      child: Stack(children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const RadialGradient(
                center: Alignment(0, -0.2), colors: [Color(0xFF25262B), Color(0xFF1C1D21)]),
            border: Border.all(color: const Color(0xFF2E3036)),
          ),
        ),
        Positioned(top: 4, left: 82, child: arrow(Icons.keyboard_arrow_up, K.up, 'למעלה')),
        Positioned(bottom: 4, left: 82, child: arrow(Icons.keyboard_arrow_down, K.down, 'למטה')),
        Positioned(left: 4, top: 82, child: arrow(Icons.keyboard_arrow_left, K.left, 'שמאלה')),
        Positioned(right: 4, top: 82, child: arrow(Icons.keyboard_arrow_right, K.right, 'ימינה')),
        Positioned(
          left: 57,
          top: 57,
          child: Press(
            semantics: 'אישור',
            fireOnDown: true,
            onPress: () => _key(K.ok),
            width: 114,
            height: 114,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF141518),
              border: Border.all(color: const Color(0xFF2C2E34)),
              boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 14, offset: Offset(0, 6))],
            ),
            child: const Text('OK', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
          ),
        ),
      ]),
    );
  }

  Widget _rocker(String label, Widget top, int topKey, Widget bottom, int bottomKey) {
    return Container(
      height: 118,
      decoration: BoxDecoration(color: C.btn, borderRadius: BorderRadius.circular(18)),
      child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Press(
            fireOnDown: true,
            repeat: true,
            onPress: () => _key(topKey),
            height: 44,
            child: DefaultTextStyle.merge(style: const TextStyle(color: Color(0xFFD7D9DE)), child: top)),
        Text(label,
            style: const TextStyle(color: C.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
        Press(
            fireOnDown: true,
            repeat: true,
            onPress: () => _key(bottomKey),
            height: 44,
            child: DefaultTextStyle.merge(style: const TextStyle(color: Color(0xFFD7D9DE)), child: bottom)),
      ]),
    );
  }

  Widget _circle(IconData icon, String label, int code, BoxDecoration deco, Color color) => Press(
        semantics: label,
        fireOnDown: true,
        onPress: () => _key(code),
        width: 56,
        height: 56,
        decoration: deco,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 17, color: color),
          const SizedBox(height: 1),
          Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
        ]),
      );

  Widget _navBtn(IconData icon, String label, int code, Color color, Color? ring) => Press(
        semantics: label,
        fireOnDown: true,
        onPress: () => _key(code),
        height: 56,
        decoration: BoxDecoration(
          color: C.btn,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ring == null ? Colors.transparent : ring.withAlpha(90)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 19, color: color),
          const SizedBox(height: 3),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
        ]),
      );

  Widget _voiceBtn() => Press(
        semantics: 'פקודה קולית',
        onPress: _showVoice,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF15283F),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: C.blue.withAlpha(110)),
        ),
        child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.mic, size: 19, color: C.blue),
          SizedBox(width: 6),
          Text('Voice', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: C.blue)),
        ]),
      );

  Widget _wideBtn(IconData icon, String label, VoidCallback onTap) => Press(
        semantics: label,
        onPress: onTap,
        height: 44,
        decoration: BoxDecoration(color: C.btn, borderRadius: BorderRadius.circular(12)),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 19, color: const Color(0xFFCFD1D6)),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFFCFD1D6))),
        ]),
      );
}

// ---------- פענוח פקודות קוליות ----------

enum VoiceKind { search, openApp, key, channel, powerOn, powerOff, unknown }

class VoiceCmd {
  final VoiceKind kind;
  final AppButton? app;
  final String? query;
  final int key;
  final int times;
  final String? digits;
  final String label;
  const VoiceCmd(this.kind,
      {this.app, this.query, this.key = 0, this.times = 1, this.digits, this.label = ''});
}

class VoiceParser {
  static const _searchVerbs = {
    'חפש', 'תחפש', 'חפשי', 'תחפשי', 'חיפוש', 'מצא', 'תמצא', 'מצאי', 'תמצאי',
    'נגן', 'תנגן', 'נגני', 'תנגני', 'השמע', 'תשמיע', 'השמיעי', 'תשמיעי',
    'שים', 'תשים', 'שימי', 'תשימי', 'הפעל', 'תפעיל', 'הפעילי', 'תפעילי',
    'הראה', 'תראה', 'תראי', 'search', 'find', 'play', 'show',
  };

  static const _fillStart = {
    'לי', 'לנו', 'את', 'אותו', 'השיר', 'שיר', 'השירים', 'שירים', 'של', 'בבקשה',
    'סרטון', 'סרטונים', 'קליפ', 'הקליפ', 'קליפים', 'משהו', 'על', 'ה',
    'please', 'me', 'for', 'song', 'songs', 'video', 'videos', 'some', 'by',
  };

  static const _fillEnd = {
    'בבקשה', 'עכשיו', 'לי', 'ב', 'באפליקציה', 'באפליקציית', 'אפליקציה', 'אפליקציית',
    'בטלוויזיה', 'בטלויזיה', 'please', 'now', 'on', 'in', 'app',
  };

  static const _aliases = {
    'youtube': ['יוטיוב', 'יוטוב', 'יוטיב', 'youtube'],
    'netflix': ['נטפליקס', 'נטפלקס', 'netflix'],
    'spotify': ['ספוטיפיי', 'ספוטיפי', 'ספוטיפאי', 'spotify'],
    'freetv': ['פריטיוי', 'פריטיבי', 'freetv'],
  };

  static const _numWords = {
    'אחת': 1, 'אחד': 1, 'שתיים': 2, 'שניים': 2, 'שתי': 2, 'שני': 2, 'שלוש': 3,
    'שלושה': 3, 'ארבע': 4, 'ארבעה': 4, 'חמש': 5, 'חמישה': 5, 'שש': 6, 'שישה': 6,
    'שבע': 7, 'שבעה': 7, 'שמונה': 8, 'תשע': 9, 'תשעה': 9, 'עשר': 10, 'עשרה': 10,
  };

  static String norm(String s) {
    var t = s
        .toLowerCase()
        .replaceAll(RegExp(r'''[.,!?;:״"׳'()–—]'''), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    // שמות של שתי מילים הופכים למילה אחת
    t = t.replaceAllMapped(
        RegExp(r'(^|\s)([ובלהמש]{0,3})(יו טיוב|you tube|פרי טי ?וי|פרי tv|free tv|פרי טי ?בי)(?=\s|$)'),
        (m) => '${m[1]}${m[2]}'
            '${m[3]!.contains('טיוב') || m[3]!.contains('tube') ? 'youtube' : 'freetv'}');
    return t;
  }

  static String? _appIdOf(String w, Map<String, String> table) {
    var x = w;
    for (var i = 0; i <= 3; i++) {
      final id = table[x];
      if (id != null) return id;
      if (x.length < 4 || !'ובלהמש'.contains(x[0])) break;
      x = x.substring(1);
    }
    return null;
  }

  static bool _isVerb(String w) =>
      _searchVerbs.contains(w) || (w.startsWith('ו') && _searchVerbs.contains(w.substring(1)));

  static VoiceCmd parse(String raw, List<AppButton> apps) {
    final t = norm(raw);
    if (t.isEmpty) return const VoiceCmd(VoiceKind.unknown);

    // טבלת שמות האפליקציות
    final table = <String, String>{};
    for (final a in apps) {
      for (final al in _aliases[a.id] ?? const <String>[]) {
        table[al] = a.id;
      }
      final l = norm(a.label).replaceAll(' ', '');
      if (l.length >= 3) table[l] = a.id;
    }

    // מוציאים את שם האפליקציה מהמשפט
    AppButton? app;
    final rest = <String>[];
    for (final w in t.split(' ')) {
      final id = _appIdOf(w, table);
      if (id != null) {
        app ??= apps.firstWhere((a) => a.id == id);
        continue;
      }
      rest.add(w);
    }

    // חיפוש: "מצא / חפש / תנגן ..."
    final vi = rest.indexWhere(_isVerb);
    if (vi >= 0) {
      final q = rest.sublist(vi + 1);
      while (q.isNotEmpty && _fillStart.contains(q.first)) {
        q.removeAt(0);
      }
      while (q.isNotEmpty && _fillEnd.contains(q.last)) {
        q.removeLast();
      }
      if (q.isNotEmpty) return VoiceCmd(VoiceKind.search, app: app, query: q.join(' '));
      if (app != null) return VoiceCmd(VoiceKind.openApp, app: app);
      return const VoiceCmd(VoiceKind.key, key: K.playPause, label: 'הפעלה / השהיה');
    }

    // פתיחת אפליקציה: "פתח נטפליקס", "יוטיוב"
    if (app != null) return VoiceCmd(VoiceKind.openApp, app: app);

    bool has(String p) => RegExp('(?:^|\\s)ו?(?:$p)(?=\\s|\$)').hasMatch(t);
    int? n = int.tryParse(RegExp(r'\d+').firstMatch(t)?.group(0) ?? '');
    if (n == null) {
      for (final w in t.split(' ')) {
        final v = _numWords[w];
        if (v != null) {
          n = v;
          break;
        }
      }
    }
    int count(int def) => (n ?? def).clamp(1, 30).toInt();

    const vol = '(?:ה?ו?וליום|ה?עוצמה|ה?קול|ה?סאונד|volume)';

    final hdmi = RegExp(r'hdmi ?(\d)').firstMatch(t);
    if (hdmi != null) {
      final h = int.parse(hdmi.group(1)!).clamp(1, 4).toInt();
      return VoiceCmd(VoiceKind.key, key: K.hdmi(h), label: 'עובר ל-HDMI $h');
    }
    if (has('מקור|מקורות|מקור קלט|input|source')) {
      return const VoiceCmd(VoiceKind.key, key: K.input, label: 'פותח את רשימת המקורות');
    }
    final ch = RegExp(r'ערוץ (\d+)').firstMatch(t);
    if (ch != null) return VoiceCmd(VoiceKind.channel, digits: ch.group(1));
    if (has('ל?ערוץ (?:ה)?(?:הבא|למעלה|קדימה)|next channel|channel up')) {
      return const VoiceCmd(VoiceKind.key, key: K.chUp, label: 'ערוץ הבא');
    }
    if (has('ל?ערוץ (?:ה)?(?:קודם|הקודם|למטה|אחורה)|previous channel|channel down')) {
      return const VoiceCmd(VoiceKind.key, key: K.chDown, label: 'ערוץ קודם');
    }
    if (has('השתק|תשתיק|השתיקי|תשתיקי|שקט|mute|unmute|בטל השתקה|תבטל השתקה|'
        '(?:כבה|תכבה|כבי|תכבי|החזר|תחזיר|תחזירי) (?:את )?$vol')) {
      return const VoiceCmd(VoiceKind.key, key: K.mute, label: 'השתקה');
    }
    if (has('תגביר|הגבר|הגבירי|תגבירי|(?:תעלה|העלה|תעלי|הגבר|תגביר) (?:את )?$vol|$vol למעלה|'
        'יותר חזק|חזק יותר|louder|volume up|turn it up')) {
      return VoiceCmd(VoiceKind.key, key: K.volUp, times: count(4), label: 'מגביר את הקול');
    }
    if (has('תנמיך|הנמך|הנמיכי|תנמיכי|(?:תוריד|הורד|תורידי|הנמך|תנמיך) (?:את )?$vol|$vol למטה|'
        'יותר חלש|חלש יותר|יותר בשקט|quieter|volume down|turn it down')) {
      return VoiceCmd(VoiceKind.key, key: K.volDown, times: count(4), label: 'מנמיך את הקול');
    }
    if (has('כבה|תכבה|כבי|תכבי|כיבוי|turn off|power off|switch off')) {
      return const VoiceCmd(VoiceKind.powerOff);
    }
    if (has('הדלק|תדליק|הדליקי|תדליקי|הדלקה|turn on|power on|switch on')) {
      return const VoiceCmd(VoiceKind.powerOn);
    }
    if (has('בית|הבית|למסך הבית|מסך הבית|מסך ראשי|home')) {
      return const VoiceCmd(VoiceKind.key, key: K.home, label: 'מסך הבית');
    }
    if (has('חזור|תחזור|חזרי|תחזרי|אחורה|back|go back')) {
      return const VoiceCmd(VoiceKind.key, key: K.back, label: 'חזרה');
    }
    if (has('עצור|תעצור|עצרי|תעצרי|פאוז|השהה|תשהה|pause|stop|המשך|תמשיך|המשיכי|תמשיכי|resume')) {
      return const VoiceCmd(VoiceKind.key, key: K.playPause, label: 'הפעלה / השהיה');
    }
    if (has('הגדרות|settings')) {
      return const VoiceCmd(VoiceKind.key, key: K.settings, label: 'הגדרות');
    }
    if (has('אישור|אוקיי|אוקי|ok|okay|enter|בחר|תבחר')) {
      return const VoiceCmd(VoiceKind.key, key: K.ok, label: 'אישור');
    }
    if (has('למעלה|up')) return VoiceCmd(VoiceKind.key, key: K.up, times: count(1), label: 'למעלה');
    if (has('למטה|down')) return VoiceCmd(VoiceKind.key, key: K.down, times: count(1), label: 'למטה');
    if (has('שמאלה|left')) return VoiceCmd(VoiceKind.key, key: K.left, times: count(1), label: 'שמאלה');
    if (has('ימינה|right')) return VoiceCmd(VoiceKind.key, key: K.right, times: count(1), label: 'ימינה');

    return const VoiceCmd(VoiceKind.unknown);
  }
}

class StatusDot extends StatelessWidget {
  final TvStatus? status;
  const StatusDot(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TvStatus.ready => C.green,
      TvStatus.connecting || TvStatus.pairing || TvStatus.approve => C.amber,
      TvStatus.error => C.red,
      _ => const Color(0xFF555555),
    };
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: status == TvStatus.ready ? const [BoxShadow(color: C.green, blurRadius: 8)] : null,
      ),
    );
  }
}

/// כפתור עם משוב לחיצה; fireOnDown לשליחה מיידית, repeat להחזקה, onLongPress ללחיצה ארוכה
class Press extends StatefulWidget {
  final Widget child;
  final VoidCallback? onPress;
  final VoidCallback? onLongPress;
  final bool repeat;
  final bool fireOnDown;
  final BoxDecoration? decoration;
  final double? width;
  final double? height;
  final String? semantics;

  const Press({
    super.key,
    required this.child,
    this.onPress,
    this.onLongPress,
    this.repeat = false,
    this.fireOnDown = false,
    this.decoration,
    this.width,
    this.height,
    this.semantics,
  });

  @override
  State<Press> createState() => _PressState();
}

class _PressState extends State<Press> {
  bool _down = false;
  bool _long = false;
  Timer? _t1;
  Timer? _t2;

  void _onDown(PointerDownEvent _) {
    setState(() => _down = true);
    _long = false;
    if (widget.fireOnDown) {
      widget.onPress?.call();
      if (widget.repeat) {
        _t1 = Timer(const Duration(milliseconds: 420), () {
          _t2 = Timer.periodic(const Duration(milliseconds: 140), (_) => widget.onPress?.call());
        });
      }
    } else if (widget.onLongPress != null) {
      _t1 = Timer(const Duration(milliseconds: 600), () {
        _long = true;
        HapticFeedback.mediumImpact();
        widget.onLongPress!();
      });
    }
  }

  void _onUp(PointerUpEvent _) {
    _stop();
    if (!widget.fireOnDown && !_long) widget.onPress?.call();
  }

  void _stop() {
    _t1?.cancel();
    _t2?.cancel();
    if (mounted) setState(() => _down = false);
  }

  @override
  void dispose() {
    _t1?.cancel();
    _t2?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.decoration;
    return Semantics(
      button: true,
      label: widget.semantics,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onDown,
        onPointerUp: _onUp,
        onPointerCancel: (_) => _stop(),
        child: AnimatedScale(
          scale: _down ? 0.95 : 1,
          duration: const Duration(milliseconds: 80),
          child: Container(
            width: widget.width,
            height: widget.height,
            alignment: Alignment.center,
            decoration: d,
            foregroundDecoration: _down
                ? BoxDecoration(
                    color: const Color(0x14FFFFFF),
                    shape: d?.shape ?? BoxShape.rectangle,
                    borderRadius: d?.borderRadius,
                  )
                : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
