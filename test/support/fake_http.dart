import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One answer a fake endpoint gives.
class Answer {
  final int status;
  final String body;
  const Answer(this.status, this.body);
  Answer.json(this.status, Object json) : body = jsonEncode(json);
}

/// A local HTTP server the chain accesses are pointed at: it answers by
/// path (and by the JSON-RPC method for a node), records every request,
/// and can hang instead of answering, which is how the timeout and
/// retries are seen.
class FakeHttp {
  late final HttpServer _server;
  final requests = <({String method, String path, String body})>[];

  /// Each request's headers, in the order of [requests].
  final headers = <Map<String, String>>[];
  final _pending = <HttpRequest>[];

  /// Answers by request path (query included); a path with no route is a
  /// 404 with a plain body.
  final routes = <String, Answer Function(String body)>{};

  /// When set, every request is held open and never answered.
  bool hang = false;

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}');

  static Future<FakeHttp> start() async {
    final f = FakeHttp();
    f._server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    f._server.listen(f._handle);
    return f;
  }

  Future<void> _handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    requests.add((method: req.method, path: req.uri.toString(), body: body));
    final h = <String, String>{};
    req.headers.forEach((name, values) => h[name] = values.join(','));
    headers.add(h);
    if (hang) {
      _pending.add(req);
      return;
    }
    final route = routes[req.uri.path] ?? routes[req.uri.toString()];
    final a = route == null ? const Answer(404, 'no such route') : route(body);
    req.response.statusCode = a.status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(a.body);
    await req.response.close();
  }

  Future<void> close() async {
    for (final p in _pending) {
      try {
        await p.response.close();
      } catch (_) {}
    }
    await _server.close(force: true);
  }
}

/// A JSON-RPC answer, as a node gives it.
Answer rpcResult(Object? result) => Answer.json(200, {'result': result, 'error': null, 'id': 'x'});
Answer rpcError(int code, String message) => Answer.json(500, {
      'result': null,
      'error': {'code': code, 'message': message},
      'id': 'x'
    });
