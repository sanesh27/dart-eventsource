library eventsource;

export "src/event.dart";

import "dart:async";
import "dart:convert";

import "package:http/http.dart" as http;
import "package:http/src/utils.dart" show encodingForCharset;
import "package:http_parser/http_parser.dart" show MediaType;

import "src/event.dart";
import "src/decoder.dart";

enum EventSourceReadyState {
  CONNECTING,
  OPEN,
  CLOSED,
}

class EventSourceSubscriptionException extends Event implements Exception {
  int statusCode;
  String message;

  @override
  String get data => "$statusCode: $message";

  EventSourceSubscriptionException(this.statusCode, this.message)
      : super(event: "error");
}

/// An EventSource client that exposes a [Stream] of [Event]s.
class EventSource extends Stream<Event> {
  // interface attributes

  final Uri url;
  final Map headers;

  EventSourceReadyState get readyState => _readyState;

  Stream<Event> get onOpen => this.where((e) => e.event == "open");
  Stream<Event> get onMessage => this.where((e) => e.event == "message");
  Stream<Event> get onError => this.where((e) => e.event == "error");

  // internal attributes

  StreamController<Event> _streamController =
      new StreamController<Event>.broadcast();

  EventSourceReadyState _readyState = EventSourceReadyState.CLOSED;

  http.Client client;
  Duration _retryDelay = const Duration(milliseconds: 3000);
  String _lastEventId;
  Event _lastEvent;
  EventSourceDecoder _decoder;
  String _body;
  String _method;


  /// Create a new EventSource by connecting to the specified url.
  static Future<EventSource> connect(url,
      {http.Client client, String lastEventId, Map headers, String body, String method}) async {
    // parameter initialization
    url = url is Uri ? url : Uri.parse(url);
    client = client ?? new http.Client();
    lastEventId = lastEventId ?? "";
    body = body ?? "";
    method = method ?? "GET";
    print("Event connect ------ ${url}");
    print("Last Event Id----- $lastEventId");
    EventSource es = new EventSource._internal(url, client, lastEventId, headers, body, method);
    await es._start();
    return es;
  }

  EventSource._internal(this.url, this.client, this._lastEventId, this.headers, this._body, this._method) {
    _decoder = new EventSourceDecoder(retryIndicator: _updateRetryDelay);
  }

  // proxy the listen call to the controller's listen call
  @override
  StreamSubscription<Event> listen(void onData(Event event),
          {Function onError, void onDone(), bool cancelOnError}) =>
      _streamController.stream.listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  /// Attempt to start a new connection.
  Future _start() async {
    try {
      print("State before connection --- $_readyState");
      var request = new http.Request(_method, url);
      request.headers["Cache-Control"] = "no-cache";
      request.headers["Connection"] = "Keep-Alive";
      request.headers["Accept"] = "text/event-stream";
      request.headers["Content-type"] = "application/json";
      if (_lastEventId.isNotEmpty) {
        request.headers["Last-Event-ID"] = _lastEventId;
      }
      if (headers != null) {
        headers.forEach((k,v) {
          request.headers[k] = v;
        });
      }
      request.body = _body;
      print("Send Event______");
      var response = await client.send(request);
      print("response event ---- ${response.toString()}");
      print("response event ---- ${response.statusCode.toString()}");
      if (response.statusCode != 200) {
        // server returned an error
        var bodyBytes = await response.stream.toBytes();
        String body = _encodingForHeaders(response.headers).decode(bodyBytes);
        throw new EventSourceSubscriptionException(response.statusCode, body);
      }
      _readyState = EventSourceReadyState.OPEN;
      print("State after response --- $_readyState");
      // start streaming the data
      response.stream.transform(_decoder).listen((Event event) {
        print("Listen event ---- $_lastEventId");
        if (_streamController != null) {
          if (!_streamController.isClosed) {
            // if (_lastEventId != event) {
              _streamController.add(event);
              _lastEvent = event;
              _lastEventId = event.id;
              print("Last Event Id----- $_lastEventId");
            // }
          }
        }

      },
          cancelOnError: true,
          onError: _retry,
          onDone: () {
        print("Event done function..");
            _readyState = EventSourceReadyState.CLOSED;

          }
      );
    } on Exception catch (e) {
      cancelEventListen();
      print("State on exception --- $_readyState");
      print("Exception --- $e");
      if (e is http.ClientException) {
        print("Exception http--- $e");
      }
    }

  }

  Future cancelEventListen() async {
    print("Cancel Event_____");
    try {
      if (_streamController != null) {
        if (_streamController.isPaused) {
          print("Pause event--- ${_streamController.isPaused}");
          _streamController = new StreamController<Event>.broadcast();
        }
        else {
          print("Close stream____");
          await _streamController.close();
        }
      }
    _streamController = null;
    Future.delayed(Duration(seconds: 3), () => client.close());
      } catch(e) {
      print("exception $e");
    }

  }

  /// Retries until a new connection is established. Uses exponential backoff.
  Future _retry(dynamic e) async {
    print("Retry Event______");
    _readyState = EventSourceReadyState.CONNECTING;
    // try reopening with exponential backoff
    Duration backoff = _retryDelay;
    while (true) {
      await new Future.delayed(backoff);
      if (_streamController.isClosed || _streamController.isPaused) {
        print("Retry pause check_____");
        break;
      } else {
        try {
          await _start();
          break;
        } catch (error) {
          print("Retry backoff_____");
          _streamController.addError(error);
          backoff *= 10;
        }
      }
    }
  }

  void _updateRetryDelay(Duration retry) {
    _retryDelay = retry;
  }
}

/// Returns the encoding to use for a response with the given headers. This
/// defaults to [LATIN1] if the headers don't specify a charset or
/// if that charset is unknown.
Encoding _encodingForHeaders(Map<String, String> headers) =>
    encodingForCharset(_contentTypeForHeaders(headers).parameters['charset']);

/// Returns the [MediaType] object for the given headers's content-type.
///
/// Defaults to `application/octet-stream`.
MediaType _contentTypeForHeaders(Map<String, String> headers) {
  var contentType = headers['content-type'];
  if (contentType != null) return new MediaType.parse(contentType);
  return new MediaType("application", "octet-stream");
}
