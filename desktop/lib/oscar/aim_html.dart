import 'dart:convert';
import 'dart:typed_data';

/// AIM sends messages as a small subset of HTML. This turns that into plain
/// text for the chat view, and plain text back into AIM-compatible HTML.
String htmlToText(String html) {
  var s = html;
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<[^>]*>'), '');
  s = s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ');
  s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    return code == null ? m.group(0)! : String.fromCharCode(code);
  });
  s = s.replaceAll('&amp;', '&');
  return s.trim();
}

/// Text of a received message. Older builds of this app sent away
/// auto-replies with their HTML escaped, so after one pass the text still
/// looks like `<HTML><BODY…>…`; strip that second layer too.
String messageText(String html) {
  var t = htmlToText(html);
  if (RegExp(r'^\s*<(html|body|font)\b', caseSensitive: false).hasMatch(t)) t = htmlToText(t);
  return t;
}

String escapeHtml(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Colours (ARGB) put on outgoing messages, like AIM's font/background
/// colour buttons. null = AIM's defaults (black on white).
class OutgoingStyle {
  static int? textColor;
  static int? backColor;
}

String _hex(int argb) => '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

String textToAimHtml(String text, {int? fg, int? bg}) {
  fg ??= OutgoingStyle.textColor;
  bg ??= OutgoingStyle.backColor;
  final body = escapeHtml(text).replaceAll('\r\n', '\n').replaceAll('\n', '<BR>');
  final font = fg == null ? '<FONT LANG="0">' : '<FONT COLOR="${_hex(fg)}" LANG="0">';
  return '<HTML><BODY BGCOLOR="${bg == null ? '#ffffff' : _hex(bg)}">$font$body</FONT></BODY></HTML>';
}

const _named = {
  'black': 0x000000, 'white': 0xffffff, 'red': 0xff0000, 'green': 0x008000, 'blue': 0x0000ff,
  'yellow': 0xffff00, 'purple': 0x800080, 'orange': 0xffa500, 'pink': 0xffc0cb, 'gray': 0x808080,
  'grey': 0x808080, 'navy': 0x000080, 'maroon': 0x800000, 'teal': 0x008080, 'lime': 0x00ff00,
  'aqua': 0x00ffff, 'cyan': 0x00ffff, 'fuchsia': 0xff00ff, 'magenta': 0xff00ff, 'silver': 0xc0c0c0,
  'olive': 0x808000,
};

int? _parseColor(String? v) {
  if (v == null) return null;
  var t = v.trim().toLowerCase().replaceAll('"', '').replaceAll("'", '');
  if (_named.containsKey(t)) return 0xFF000000 | _named[t]!;
  if (t.startsWith('#')) t = t.substring(1);
  if (t.length == 3) t = t.split('').map((c) => '$c$c').join();
  if (t.length != 6) return null;
  final n = int.tryParse(t, radix: 16);
  return n == null ? null : 0xFF000000 | n;
}

/// The text and background colours a sender picked, if any.
/// White backgrounds and black text are AIM's defaults, so they count as none.
(int?, int?) aimHtmlColors(String html) {
  final fg = _parseColor(RegExp(r'<font[^>]*\scolor\s*=\s*("[^"]*"|\S+?)[\s>]', caseSensitive: false)
      .firstMatch(html)
      ?.group(1));
  final bg = _parseColor(
      RegExp(r'<(?:body|font)[^>]*\s(?:bgcolor|back)\s*=\s*("[^"]*"|\S+?)[\s>]', caseSensitive: false)
          .firstMatch(html)
          ?.group(1));
  return (fg == 0xFF000000 ? null : fg, bg == 0xFFFFFFFF ? null : bg);
}

bool isAscii(String s) => s.codeUnits.every((c) => c < 128);

/// Encodes text for an ICBM text fragment. Returns (charset, bytes).
(int, Uint8List) encodeImText(String html) {
  if (isAscii(html)) return (0x0000, Uint8List.fromList(ascii.encode(html)));
  final units = html.codeUnits; // UTF-16 code units
  final out = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    out[i * 2] = (units[i] >> 8) & 0xff;
    out[i * 2 + 1] = units[i] & 0xff;
  }
  return (0x0002, out);
}

String decodeImText(int charset, List<int> bytes) {
  if (charset == 0x0002) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  if (charset == 0x0003) return latin1.decode(bytes);
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes);
  }
}
