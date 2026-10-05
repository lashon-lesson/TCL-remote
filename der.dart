// קידוד ופענוח DER מינימלי – ליצירת תעודה ולקריאת המפתח הציבורי של הטלוויזיה
import 'dart:convert';
import 'dart:typed_data';

class Der {
  static List<int> _len(int n) {
    if (n < 0x80) return [n];
    final bytes = <int>[];
    var v = n;
    while (v > 0) {
      bytes.insert(0, v & 0xff);
      v >>= 8;
    }
    return [0x80 | bytes.length, ...bytes];
  }

  static Uint8List tlv(int tag, List<int> content) =>
      Uint8List.fromList([tag, ..._len(content.length), ...content]);

  static Uint8List seq(List<List<int>> items) =>
      tlv(0x30, items.expand((e) => e).toList());

  static Uint8List set(List<List<int>> items) =>
      tlv(0x31, items.expand((e) => e).toList());

  static Uint8List integer(BigInt v) {
    var bytes = unsignedBytes(v);
    if (bytes[0] & 0x80 != 0) bytes = [0, ...bytes];
    return tlv(0x02, bytes);
  }

  static Uint8List nul() => Uint8List.fromList([0x05, 0x00]);

  static Uint8List oid(List<int> parts) {
    final out = <int>[40 * parts[0] + parts[1]];
    for (final p in parts.skip(2)) {
      final chunk = <int>[p & 0x7f];
      var v = p >> 7;
      while (v > 0) {
        chunk.insert(0, (v & 0x7f) | 0x80);
        v >>= 7;
      }
      out.addAll(chunk);
    }
    return tlv(0x06, out);
  }

  static Uint8List utf8Str(String s) => tlv(0x0c, utf8.encode(s));

  static Uint8List utcTime(DateTime t) {
    final u = t.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final s = '${two(u.year % 100)}${two(u.month)}${two(u.day)}'
        '${two(u.hour)}${two(u.minute)}${two(u.second)}Z';
    return tlv(0x17, ascii.encode(s));
  }

  static Uint8List bitString(List<int> data) => tlv(0x03, [0, ...data]);

  static Uint8List explicit(int n, List<int> content) => tlv(0xa0 | n, content);

  /// ספרות ההקסה של המספר כבתים (כמו שהטלוויזיה מחשבת את ה-hash)
  static List<int> unsignedBytes(BigInt v) {
    var hex = v.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    return [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16)
    ];
  }

  static String pem(String label, List<int> der) {
    final b64 = base64.encode(der);
    final lines = <String>[];
    for (var i = 0; i < b64.length; i += 64) {
      lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
    }
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }

  static Uint8List fromPem(String pem) {
    final body = pem
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('-----'))
        .join();
    return base64.decode(body);
  }
}

class DerNode {
  final int tag;
  final Uint8List content;
  DerNode(this.tag, this.content);

  static ({DerNode node, int next}) read(Uint8List d, int i) {
    final tag = d[i];
    var len = d[i + 1];
    var p = i + 2;
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | d[p + k];
      }
      p += n;
    }
    return (
      node: DerNode(tag, Uint8List.sublistView(d, p, p + len)),
      next: p + len
    );
  }

  List<DerNode> get children {
    final out = <DerNode>[];
    var i = 0;
    while (i < content.length) {
      final r = read(content, i);
      out.add(r.node);
      i = r.next;
    }
    return out;
  }

  BigInt get asBigInt =>
      content.fold(BigInt.zero, (a, b) => (a << 8) | BigInt.from(b));
}

/// מחזיר (modulus, exponent) של מפתח RSA מתוך תעודת X.509 בפורמט DER
({BigInt n, BigInt e}) rsaPublicFromCert(Uint8List der) {
  final cert = DerNode.read(der, 0).node;
  final tbs = cert.children[0].children;
  final idx = tbs[0].tag == 0xa0 ? 6 : 5;
  final spki = tbs[idx].children;
  final bits = spki[1].content;
  final key = DerNode.read(Uint8List.sublistView(bits, 1), 0).node.children;
  return (n: key[0].asBigInt, e: key[1].asBigInt);
}
