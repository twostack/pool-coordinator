import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'chain_access.dart';

/// What an endpoint answered: the status and the body as text.
class HttpReply {
  final int status;
  final String body;
  const HttpReply(this.status, this.body);
}

/// HTTP with the bounds every chain call has: each attempt times out, a
/// network failure is retried a configured number of times, and what
/// comes back after that is a [ChainError] naming the endpoint. A
/// response with any status is an answer, not a failure; what it means is
/// the caller's to decide.
///
/// Each attempt has its own client, closed after it. A shared client would
/// have to be reset when an attempt times out, and closing it cancels every
/// other caller's request in flight, which is what happened when proving
/// held the isolate for minutes and a backlog of calls timed out together.
/// The node closes idle connections anyway, so pooling saves nothing.
class BoundedHttp {
  final Duration timeout;
  final int retries;
  final http.Client Function() _newClient;

  BoundedHttp({required this.timeout, required this.retries, http.Client Function()? client})
      : _newClient = client ?? http.Client.new;

  Future<HttpReply> send(String endpoint, Uri uri, {String method = 'GET', Map<String, String>? headers, String? body}) async {
    Object? last;
    for (int attempt = 0; attempt <= retries; attempt++) {
      final client = _newClient();
      try {
        final req = http.Request(method, uri);
        if (headers != null) req.headers.addAll(headers);
        if (body != null) req.body = body;
        final streamed = await client.send(req).timeout(timeout);
        final res = await http.Response.fromStream(streamed).timeout(timeout);
        return HttpReply(res.statusCode, res.body);
      } on TimeoutException {
        last = 'no answer within ${timeout.inMilliseconds} ms';
      } on SocketException catch (e) {
        last = 'connection failed (${e.message})';
      } on http.ClientException catch (e) {
        last = 'connection failed (${e.message})';
      } on HttpException catch (e) {
        last = 'connection failed (${e.message})';
      } finally {
        client.close();
      }
    }
    throw ChainError(endpoint, 'did not answer after ${retries + 1} attempts: $last');
  }

  /// Nothing is held between calls; kept so callers can say they are done.
  void close() {}
}
