// קודי מקשים של Android
class K {
  static const home = 3, back = 4, star = 17, pound = 18;
  static const up = 19, down = 20, left = 21, right = 22, ok = 23;
  static const volUp = 24, volDown = 25, power = 26;
  static const comma = 55, period = 56, space = 62, enter = 66, del = 67;
  static const minus = 69, equals = 70, semicolon = 74, apostrophe = 75;
  static const slash = 76, at = 77, plus = 81;
  static const menu = 82, search = 84, playPause = 85;
  static const mute = 164, chUp = 166, chDown = 167;
  static const settings = 176, input = 178;

  static int digit(int d) => 7 + d;

  static int? forChar(String ch) {
    final c = ch.toLowerCase().codeUnitAt(0);
    if (c >= 0x61 && c <= 0x7a) return 29 + (c - 0x61);
    if (c >= 0x30 && c <= 0x39) return digit(c - 0x30);
    const map = {
      ' ': space, '.': period, ',': comma, '@': at, '-': minus, '_': minus,
      '/': slash, '=': equals, '+': plus, '#': pound, '*': star,
      "'": apostrophe, ';': semicolon,
    };
    return map[ch];
  }
}
