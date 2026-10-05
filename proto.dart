// Protobuf מינימלי – מספיק להודעות של Android TV Remote v2
import 'dart:convert';
import 'dart:typed_data';

class Pb {
  final _b = BytesBuilder();

  void _varint(int v) {
    var x = v;
    while (x >= 0x80) {
      _b.addByte((x & 0x7f) | 0x80);
      x >>= 7;
    }
    _b.addByte(x);
  }

  void _tag(int field, int wire) => _varint((field << 3) | wire);

  Pb int32(int field, int v) {
    _tag(field, 0);
    _varint(v);
    return this;
  }

  Pb bytes(int field, List<int> data) {
    _tag(field, 2);
    _varint(data.length);
    _b.add(data);
    return this;
  }

  Pb str(int field, String s) => bytes(field, utf8.encode(s));
  Pb msg(int field, Pb m) => bytes(field, m.toBytes());

  Uint8List toBytes() => _b.toBytes();

  /// הודעה עם קידומת אורך (varint), כמו encodeDelimited
  Uint8List framed() {
    final body = toBytes();
    final f = Pb().._varint(body.length);
    f._b.add(body);
    return f.toBytes();
  }
}

class PbFields {
  final Map<int, List<Object>> _f;
  PbFields(this._f);

  bool has(int field) => _f.containsKey(field);
  int int32(int field, [int def = 0]) {
    final v = _f[field]?.first;
    return v is int ? v : def;
  }

  PbFields? msg(int field) {
    final v = _f[field]?.first;
    return v is Uint8List ? PbFields.decode(v) : null;
  }

  static PbFields decode(Uint8List d) {
    final f = <int, List<Object>>{};
    var i = 0;
    int readVarint() {
      var shift = 0, result = 0;
      while (true) {
        final b = d[i++];
        result |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) break;
        shift += 7;
      }
      return result;
    }

    while (i < d.length) {
      final key = readVarint();
      final field = key >> 3, wire = key & 7;
      Object value;
      switch (wire) {
        case 0:
          value = readVarint();
          break;
        case 2:
          final len = readVarint();
          value = Uint8List.sublistView(d, i, i + len);
          i += len;
          break;
        case 1:
          i += 8;
          continue;
        case 5:
          i += 4;
          continue;
        default:
          return PbFields(f);
      }
      (f[field] ??= []).add(value);
    }
    return PbFields(f);
  }
}

/// מפרק זרם בתים להודעות עם קידומת אורך
class FrameReader {
  final void Function(Uint8List msg) onMessage;
  FrameReader(this.onMessage);
  final _buf = <int>[];

  void add(List<int> data) {
    _buf.addAll(data);
    while (true) {
      var i = 0, shift = 0, len = 0;
      var complete = false;
      while (i < _buf.length) {
        final b = _buf[i++];
        len |= (b & 0x7f) << shift;
        if (b & 0x80 == 0) {
          complete = true;
          break;
        }
        shift += 7;
      }
      if (!complete || _buf.length < i + len) return;
      final msg = Uint8List.fromList(_buf.sublist(i, i + len));
      _buf.removeRange(0, i + len);
      onMessage(msg);
    }
  }
}
