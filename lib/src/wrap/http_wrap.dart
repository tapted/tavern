library pub.http_wrap;

import 'dart:async' hide TimeoutException;
import 'dart:convert';
import 'dart:html';
import 'dart:typed_data';
import '../io.dart';
import '../log.dart' as log;
import '../sdk.dart' as sdk;
import '../utils.dart';

/// The amount of time in milliseconds to allow HTTP requests before assuming
/// they've failed.
final HTTP_TIMEOUT = 30 * 1000;

/// Headers required for pub.dartlang.org API requests.
///
/// The Accept header tells pub.dartlang.org which version of the API we're
/// expecting, so it can either serve that version or give us a 406 error if
/// it's not supported.
final PUB_API_HEADERS = const {'Accept': 'application/vnd.pub.v2+json'};

/// An HTTP client that transforms 40* errors and socket exceptions into more
/// user-friendly error messages.
class PubHttpClient {
  final _requestStopwatches = new Map<HttpRequest, Stopwatch>();
  final completers = new Map<HttpRequest, Completer>();

  void decodeResponse(var event, HttpRequest request) {
    var completer = completers.remove(request);
    log.io("Received response ${request.statusText} (${request.status}).");

    if (request.status < 400 || request.status == 401) {
      completer.complete(request.response);
    } else {
      completer.complete(new PubHttpException());
    }
  }

  Future<dynamic> read(uri,
                       {Map<String, String> headers,
                        String responseType: "text"}) {
    log.io("Requesting HTTP uri $uri for $responseType");
    var request = new HttpRequest();
    completers[request] = new Completer();

    request.responseType = responseType;
    request.timeout = HTTP_TIMEOUT;
    request.open("GET", uri.toString());

    // The request headers must be set after calling 'open'.
    if (headers != null)
      headers.forEach((k, v) => request.setRequestHeader(k, v));

    // No need to send any body.
    request.send('');
    request.onLoadEnd.listen((e) => decodeResponse(e, request));

    return completers[request].future;
  }
}

/// The HTTP client to use for all HTTP requests.
final httpClient = new PubHttpClient();

/// Exception thrown when an HTTP operation fails.
class PubHttpException implements Exception {
  //final http.Response response;

  const PubHttpException();//this.response)

  String toString() => 'HTTP error';
  //${response.statusCode}: '
  //'${response.reasonPhrase}';
}