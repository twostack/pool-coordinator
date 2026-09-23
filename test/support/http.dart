import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One answer from the API: its status, headers and body.
typedef Answer = ({int status, HttpHeaders headers, String body});

/// [method] [path] on the API at [port] on loopback.
Future<Answer> request(int port, String path, {String method = 'GET'}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse('http://127.0.0.1:$port$path'));
    final res = await req.close();
    final body = await utf8.decodeStream(res);
    return (status: res.statusCode, headers: res.headers, body: body);
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, dynamic>> getJson(int port, String path) async {
  final a = await request(port, path);
  return jsonDecode(a.body) as Map<String, dynamic>;
}

/// [line] sent as the request line, byte for byte, as a client that does
/// not check its URLs would; the status and body of the answer, or null
/// when the server closed the connection without one.
Future<({int status, String body})?> rawRequest(int port, List<int> line) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
  try {
    socket.add([...line, ...ascii.encode('\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n')]);
    await socket.flush();
    final bytes = await socket.fold<List<int>>([], (a, b) => a..addAll(b)).timeout(const Duration(seconds: 10));
    final text = latin1.decode(bytes);
    if (text.isEmpty) return null;
    final m = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(text);
    if (m == null) throw StateError('not an HTTP answer: ${text.substring(0, text.length.clamp(0, 80))}');
    final split = text.indexOf('\r\n\r\n');
    var body = split < 0 ? '' : text.substring(split + 4);
    if (text.toLowerCase().contains('transfer-encoding: chunked')) body = _unchunk(body);
    return (status: int.parse(m.group(1)!), body: body);
  } finally {
    socket.destroy();
  }
}

String _unchunk(String s) {
  final out = StringBuffer();
  var at = 0;
  while (at < s.length) {
    final eol = s.indexOf('\r\n', at);
    if (eol < 0) break;
    final n = int.parse(s.substring(at, eol).split(';').first.trim(), radix: 16);
    if (n == 0) break;
    out.write(s.substring(eol + 2, eol + 2 + n));
    at = eol + 2 + n + 2;
  }
  return out.toString();
}

/// The event stream at [port]: each event's name and data, as they come.
class EventClient {
  final HttpClient _client = HttpClient();
  final events = <({String event, Map<String, dynamic> data})>[];
  final comments = <String>[];
  late final int status;
  StreamSubscription<String>? _sub;
  final _arrived = StreamController<void>.broadcast();

  static Future<EventClient> connect(int port) async {
    final c = EventClient();
    final req = await c._client.getUrl(Uri.parse('http://127.0.0.1:$port/api/events'));
    final res = await req.close();
    c.status = res.statusCode;
    if (res.statusCode != 200) {
      await res.drain<void>();
      return c;
    }
    var event = 'message';
    c._sub = res.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (line.startsWith(':')) {
        c.comments.add(line);
        c._arrived.add(null);
      } else if (line.startsWith('event: ')) {
        event = line.substring(7);
      } else if (line.startsWith('data: ')) {
        c.events.add((event: event, data: jsonDecode(line.substring(6)) as Map<String, dynamic>));
        event = 'message';
        c._arrived.add(null);
      }
    });
    return c;
  }

  /// Waits until [test] holds of what has arrived, or [timeout] passes.
  Future<void> until(bool Function() test, {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!test()) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('the event stream did not deliver in $timeout');
      try {
        await _arrived.stream.first.timeout(left);
      } on TimeoutException {
        // checked again at the top
      }
    }
  }

  Future<void> close() async {
    await _sub?.cancel();
    _client.close(force: true);
    await _arrived.close();
  }
}
