import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'atv/connection.dart';
import 'atv/identity.dart';
import 'atv/keys.dart';
import 'scanner.dart';
import 'store.dart';

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
      title: 'שלט TCL',
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
  final conns = <String, TvConnection>{};
  String? sel;
  String? _pairPromptFor;

  TvConnection? get cur => sel == null ? null : conns[sel];

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
      for (final c in conns.values) {
        if (!c.isReady && c.status != TvStatus.pairing) c.connect();
      }
    }
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
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
  }

  void _open(TvDevice tv) {
    final c = TvConnection(tv, identity!, () => store!.saveTvs(tvs));
    c.addListener(() => _onConnChange(c));
    conns[tv.id] = c;
    c.connect();
  }

  void _onConnChange(TvConnection c) {
    if (!mounted) return;
    setState(() {});
    if (c.tv.id == sel &&
        c.status == TvStatus.pairing &&
        _pairPromptFor != c.tv.id) {
      _pairPromptFor = c.tv.id;
      _showPairSheet(c);
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

  TvConnection? _need() {
    final c = cur;
    if (c == null) {
      _showTvSheet();
      _toast('הוסף טלוויזיה כדי להתחיל');
      return null;
    }
    if (!c.isReady) {
      if (c.status == TvStatus.pairing) {
        _showPairSheet(c);
        return null;
      }
      if (c.canSend) {
        // מתחבר מחדש ושולח את הפקודה ברגע שהחיבור מוכן
        if (c.status != TvStatus.connecting) _toast('מתחבר לטלוויזיה…');
        return c;
      }
      _toast('הטלוויזיה לא מחוברת. לחץ על TCL');
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
            ? 'הטלוויזיה בכיבוי מלא ולא עונה. צריך להפעיל בה "המתנה ברשת" – או להזין כתובת MAC (TCL ← ⋮)'
            : 'הטלוויזיה לא עונה. בדוק שהופעלה בה "המתנה ברשת"');
        break;
    }
  }

  void _launch(AppButton a) {
    if (a.package.isEmpty) {
      _editApp(a);
      return;
    }
    final c = _need();
    if (c == null) return;
    HapticFeedback.lightImpact();
    final r = c.launchApp(a.package);
    _toast(r == 'store' ? 'פותח את ${a.label} דרך החנות…' : 'פותח את ${a.label}…');
  }

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
    TvStatus.error: 'שגיאה',
    TvStatus.offline: 'לא מחובר',
  };

  void _showTvSheet() {
    if (identity == null) return;
    final name = TextEditingController();
    final host = TextEditingController();
    var scanning = false;
    double progress = 0;
    List<String>? found;

    _sheet((ctx, setS) {
      void addTv(String n, String h) {
        h = h.trim();
        if (!RegExp(r'^[\w.-]+$').hasMatch(h)) {
          _toast('כתובת IP לא תקינה');
          return;
        }
        final tv = TvDevice(
            id: DateTime.now().millisecondsSinceEpoch.toRadixString(36),
            name: n.trim().isEmpty ? 'טלוויזיה ${tvs.length + 1}' : n.trim(),
            host: h);
        tvs.add(tv);
        store!.saveTvs(tvs);
        _select(tv.id);
        _open(tv);
        Navigator.pop(ctx);
        _toast('מתחבר… בעוד רגע יופיע קוד על הטלוויזיה');
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
              if (found!.where((ip) => !tvs.any((t) => t.host == ip)).isEmpty)
                _hint('לא נמצאו טלוויזיות חדשות. ודא שהטלוויזיה דלוקה, או הזן כתובת ידנית.'),
              for (final ip in found!.where((ip) => !tvs.any((t) => t.host == ip)))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    tileColor: const Color(0xFF24252B),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    leading: const Icon(Icons.tv, color: C.green),
                    title: Text(ip, textDirection: TextDirection.ltr, textAlign: TextAlign.right),
                    trailing: const Text('הוסף', style: TextStyle(color: C.green)),
                    onTap: () => addTv(name.text, ip),
                  ),
                ),
            ],
            const SizedBox(height: 16),
            _hint('או הוספה ידנית. את הכתובת מוצאים בטלוויזיה: הגדרות ← רשת ואינטרנט ← הרשת המחוברת.'),
            _field(name, hint: 'שם (למשל: סלון)'),
            _field(host,
                hint: 'כתובת IP (למשל 192.168.1.40)',
                ltr: true,
                type: const TextInputType.numberWithOptions(decimal: true)),
            _primary('הוסף טלוויזיה', () => addTv(name.text, host.text)),
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
                Text('${tv.host}  ${_statusText[st]}$err',
                    style: const TextStyle(color: C.muted, fontSize: 12)),
              ]),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: C.muted),
              color: const Color(0xFF2B2D33),
              onSelected: (v) async {
                if (v == 're') {
                  c?.connect();
                } else if (v == 'pair') {
                  tv.paired = false;
                  store!.saveTvs(tvs);
                  _pairPromptFor = null;
                  _select(tv.id);
                  c?.startPairing();
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
                PopupMenuItem(value: 're', child: Text('חבר מחדש')),
                PopupMenuItem(value: 'pair', child: Text('צמד מחדש')),
                PopupMenuItem(value: 'mac', child: Text('כתובת MAC להדלקה')),
                PopupMenuItem(value: 'del', child: Text('מחק')),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  void _showPairSheet(TvConnection c) {
    final code = TextEditingController();
    String? err;
    _sheet((ctx, setS) {
      void submit() {
        if (c.submitCode(code.text)) {
          Navigator.pop(ctx);
          _toast('מצמד…');
        } else {
          setS(() => err = c.status == TvStatus.pairing
              ? 'הקוד לא תואם. בדוק ונסה שוב'
              : 'הבקשה פגה. לחץ על TCL ← צמד מחדש');
        }
      }

      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('צימוד ל${c.tv.name}'),
        _hint('על מסך הטלוויזיה מופיע קוד בן 6 תווים. הקלד אותו כאן.'),
        _field(code,
            ltr: true,
            autofocus: true,
            maxLength: 6,
            align: TextAlign.center,
            caps: TextCapitalization.characters,
            formatters: [
              FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]')),
              TextInputFormatter.withFunction(
                  (o, n) => n.copyWith(text: n.text.toUpperCase())),
            ],
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: 8),
            onSubmit: (_) => submit()),
        if (err != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(err!, style: const TextStyle(color: C.red, fontSize: 13.5)),
          ),
        _primary('אשר צימוד', submit),
        _ghost('ביטול', () => Navigator.pop(ctx)),
      ]);
    });
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

    _sheet((ctx, setS) {
      void live(String v) {
        debounce?.cancel();
        debounce = Timer(const Duration(milliseconds: 180), () {
          final c = cur;
          if (c == null || !c.isReady || v.isEmpty) return;
          c.sendImeText(v);
        });
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
          Padding(
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
              onSubmit: (_) => _key(K.enter)),
          Row(children: [
            Expanded(flex: 2, child: _primary('חפש ↵', () => _key(K.enter))),
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
                      _key(K.del);
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
          TextButton(
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

  void _editApp(AppButton a) {
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
            ? const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  CircularProgressIndicator(color: C.green),
                  SizedBox(height: 16),
                  Text('מכין את השלט…', style: TextStyle(color: C.muted)),
                ]),
              )
            : Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: _remote(),
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
                    const Text('TCL',
                        style: TextStyle(
                            color: C.red, fontWeight: FontWeight.w800, fontSize: 17, letterSpacing: 5)),
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
            Expanded(child: _navBtn(Icons.mic_none, 'Search', K.search, C.blue, C.blue)),
            const SizedBox(width: 8),
            Expanded(child: _navBtn(Icons.menu, 'Menu', K.menu, C.amber, C.amber)),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(child: _wideBtn(Icons.dialpad, '123', _showNumpad)),
            const SizedBox(width: 10),
            Expanded(child: _wideBtn(Icons.keyboard_outlined, 'Keyboard', _showKeyboard)),
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

class StatusDot extends StatelessWidget {
  final TvStatus? status;
  const StatusDot(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      TvStatus.ready => C.green,
      TvStatus.connecting || TvStatus.pairing => C.amber,
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
