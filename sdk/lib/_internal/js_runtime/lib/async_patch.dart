// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Patch file for the dart:async library.

import 'dart:_js_helper' show
    patch,
    ExceptionAndStackTrace,
    Primitives,
    convertDartClosureToJS,
    getTraceFromException,
    requiresPreamble,
    unwrapException;
import 'dart:_isolate_helper' show
    IsolateNatives,
    TimerImpl,
    leaveJsAsync,
    enterJsAsync,
    isWorker;

import 'dart:_foreign_helper' show JS;

import 'dart:_async_await_error_codes' as async_error_codes;

@patch
class _AsyncRun {
  @patch
  static void _scheduleImmediate(void callback()) {
    scheduleImmediateClosure(callback);
  }

  // Lazily initialized.
  static final Function scheduleImmediateClosure =
      _initializeScheduleImmediate();

  static Function _initializeScheduleImmediate() {
    requiresPreamble();
    if (JS('', 'self.scheduleImmediate') != null) {
      return _scheduleImmediateJsOverride;
    }
    if (JS('', 'self.MutationObserver') != null &&
        JS('', 'self.document') != null) {
      // Use mutationObservers.
      var div = JS('', 'self.document.createElement("div")');
      var span = JS('', 'self.document.createElement("span")');
      var storedCallback;

      internalCallback(_) {
        leaveJsAsync();
        var f = storedCallback;
        storedCallback = null;
        f();
      };

      var observer = JS('', 'new self.MutationObserver(#)',
          convertDartClosureToJS(internalCallback, 1));
      JS('', '#.observe(#, { childList: true })',
          observer, div);

      return (void callback()) {
        assert(storedCallback == null);
        enterJsAsync();
        storedCallback = callback;
        // Because of a broken shadow-dom polyfill we have to change the
        // children instead a cheap property.
        // See https://github.com/Polymer/ShadowDOM/issues/468
        JS('', '#.firstChild ? #.removeChild(#): #.appendChild(#)',
            div, div, span, div, span);
      };
    } else if (JS('', 'self.setImmediate') != null) {
      return _scheduleImmediateWithSetImmediate;
    }
    // TODO(20055): We should use DOM promises when available.
    return _scheduleImmediateWithTimer;
  }

  static void _scheduleImmediateJsOverride(void callback()) {
    internalCallback() {
      leaveJsAsync();
      callback();
    };
    enterJsAsync();
    JS('void', 'self.scheduleImmediate(#)',
       convertDartClosureToJS(internalCallback, 0));
  }

  static void _scheduleImmediateWithSetImmediate(void callback()) {
    internalCallback() {
      leaveJsAsync();
      callback();
    };
    enterJsAsync();
    JS('void', 'self.setImmediate(#)',
       convertDartClosureToJS(internalCallback, 0));
  }

  static void _scheduleImmediateWithTimer(void callback()) {
    Timer._createTimer(Duration.ZERO, callback);
  }
}

@patch
class DeferredLibrary {
  @patch
  Future<Null> load() {
    throw 'DeferredLibrary not supported. '
          'please use the `import "lib.dart" deferred as lib` syntax.';
  }
}

@patch
class Timer {
  @patch
  static Timer _createTimer(Duration duration, void callback()) {
    int milliseconds = duration.inMilliseconds;
    if (milliseconds < 0) milliseconds = 0;
    return new TimerImpl(milliseconds, callback);
  }

  @patch
  static Timer _createPeriodicTimer(Duration duration,
                             void callback(Timer timer)) {
    int milliseconds = duration.inMilliseconds;
    if (milliseconds < 0) milliseconds = 0;
    return new TimerImpl.periodic(milliseconds, callback);
  }
}

/// Runtime support for async-await transformation.
///
/// This function is called by a transformed function on each await and return
/// in the untransformed function, and before starting.
///
/// If [object] is not a future it will be wrapped in a `new Future.value`.
///
/// If [asyncBody] is [async_error_codes.SUCCESS]/[async_error_codes.ERROR] it
/// indicates a return or throw from the async function, and
/// complete/completeError is called on [completer] with [object].
///
/// Otherwise [asyncBody] is set up to be called when the future is completed
/// with a code [async_error_codes.SUCCESS]/[async_error_codes.ERROR] depending
/// on the success of the future.
///
/// Returns the future of the completer for convenience of the first call.
dynamic _asyncHelper(dynamic object,
    dynamic /* int | _WrappedAsyncBody */ bodyFunctionOrErrorCode,
    Completer completer) {
  if (identical(bodyFunctionOrErrorCode, async_error_codes.SUCCESS)) {
    completer.complete(object);
    return;
  } else if (identical(bodyFunctionOrErrorCode, async_error_codes.ERROR)) {
    // The error is a js-error.
    completer.completeError(unwrapException(object),
    getTraceFromException(object));
    return;
  }

  _awaitOnObject(object, bodyFunctionOrErrorCode);
  return completer.future;
}

/// Awaits on the given [object].
///
/// If the [object] is a Future, registers on it, otherwise wraps it into a
/// future first.
///
/// The [bodyFunction] argument is the continuation that should be invoked
/// when the future completes.
void _awaitOnObject(object, _WrappedAsyncBody bodyFunction) {
  Function thenCallback =
      (result) => bodyFunction(async_error_codes.SUCCESS, result);

  Function errorCallback = (dynamic error, StackTrace stackTrace) {
    ExceptionAndStackTrace wrappedException =
        new ExceptionAndStackTrace(error, stackTrace);
    bodyFunction(async_error_codes.ERROR, wrappedException);
  };

  if (object is _Future) {
    // We can skip the zone registration, since the bodyFunction is already
    // registered (see [_wrapJsFunctionForAsync]).
    object._thenNoZoneRegistration(thenCallback, errorCallback);
  } else if (object is Future) {
    object.then(thenCallback, onError: errorCallback);
  } else {
    _Future future = new _Future();
    future._setValue(object);
    // We can skip the zone registration, since the bodyFunction is already
    // registered (see [_wrapJsFunctionForAsync]).
    future._thenNoZoneRegistration(thenCallback, null);
  }
}

typedef void _WrappedAsyncBody(int errorCode, dynamic result);

_WrappedAsyncBody _wrapJsFunctionForAsync(dynamic /* js function */ function) {
  var protected = JS('', """
    // Invokes [function] with [errorCode] and [result].
    //
    // If (and as long as) the invocation throws, calls [function] again,
    // with an error-code.
    function(errorCode, result) {
      while (true) {
        try {
          #(errorCode, result);
          break;
        } catch (error) {
          result = error;
          errorCode = #;
        }
      }
    }""", function, async_error_codes.ERROR);
  return Zone.current.registerBinaryCallback((int errorCode, dynamic result) {
    JS('', '#(#, #)', protected, errorCode, result);
  });
}

/// Implements the runtime support for async* functions.
///
/// Called by the transformed function for each original return, await, yield,
/// yield* and before starting the function.
///
/// When the async* function wants to return it calls this function with
/// [asyncBody] == [async_error_codes.SUCCESS], the asyncStarHelper takes this
/// as signal to close the stream.
///
/// When the async* function wants to signal that an uncaught error was thrown,
/// it calls this function with [asyncBody] == [async_error_codes.ERROR],
/// the streamHelper takes this as signal to addError [object] to the
/// [controller] and close it.
///
/// If the async* function wants to do a yield or yield*, it calls this function
/// with [object] being an [IterationMarker].
///
/// In the case of a yield or yield*, if the stream subscription has been
/// canceled, schedules [asyncBody] to be called with
/// [async_error_codes.STREAM_WAS_CANCELED].
///
/// If [object] is a single-yield [IterationMarker], adds the value of the
/// [IterationMarker] to the stream. If the stream subscription has been
/// paused, return early. Otherwise schedule the helper function to be
/// executed again.
///
/// If [object] is a yield-star [IterationMarker], starts listening to the
/// yielded stream, and adds all events and errors to our own controller (taking
/// care if the subscription has been paused or canceled) - when the sub-stream
/// is done, schedules [asyncBody] again.
///
/// If the async* function wants to do an await it calls this function with
/// [object] not and [IterationMarker].
///
/// If [object] is not a [Future], it is wrapped in a `Future.value`.
/// The [asyncBody] is called on completion of the future (see [asyncHelper].
void _asyncStarHelper(dynamic object,
    dynamic /* int | _WrappedAsyncBody */ bodyFunctionOrErrorCode,
    _AsyncStarStreamController controller) {
  if (identical(bodyFunctionOrErrorCode, async_error_codes.SUCCESS)) {
    // This happens on return from the async* function.
    if (controller.isCanceled) {
      controller.cancelationCompleter.complete();
    } else {
      controller.close();
    }
    return;
  } else if (identical(bodyFunctionOrErrorCode, async_error_codes.ERROR)) {
    // The error is a js-error.
    if (controller.isCanceled) {
      controller.cancelationCompleter.completeError(
          unwrapException(object),
          getTraceFromException(object));
    } else {
      controller.addError(unwrapException(object),
                          getTraceFromException(object));
      controller.close();
    }
    return;
  }

  if (object is _IterationMarker) {
    if (controller.isCanceled) {
      bodyFunctionOrErrorCode(async_error_codes.STREAM_WAS_CANCELED, null);
      return;
    }
    if (object.state == _IterationMarker.YIELD_SINGLE) {
      controller.add(object.value);

      scheduleMicrotask(() {
        if (controller.isPaused) {
          // We only suspend the thread inside the microtask in order to allow
          // listeners on the output stream to pause in response to the just
          // output value, and have the stream immediately stop producing.
          controller.isSuspended = true;
          return;
        }
        bodyFunctionOrErrorCode(null, async_error_codes.SUCCESS);
      });
      return;
    } else if (object.state == _IterationMarker.YIELD_STAR) {
      Stream stream = object.value;
      // Errors of [stream] are passed though to the main stream. (see
      // [AsyncStreamController.addStream]).
      // TODO(sigurdm): The spec is not very clear here. Clarify with Gilad.
      controller.addStream(stream).then((_) {
        // No check for isPaused here because the spec 17.16.2 only
        // demands checks *before* each element in [stream] not after the last
        // one. On the other hand we check for isCanceled, as that check happens
        // after insertion of each element.
        int errorCode = controller.isCanceled
            ? async_error_codes.STREAM_WAS_CANCELED
            : async_error_codes.SUCCESS;
        bodyFunctionOrErrorCode(errorCode, null);
      });
      return;
    }
  }

  _awaitOnObject(object, bodyFunctionOrErrorCode);
}

Stream _streamOfController(_AsyncStarStreamController controller) {
  return controller.stream;
}

/// A wrapper around a [StreamController] that keeps track of the state of
/// the execution of an async* function.
/// It can be in 1 of 3 states:
///
/// - running/scheduled
/// - suspended
/// - canceled
///
/// If yielding while the subscription is paused it will become suspended. And
/// only resume after the subscription is resumed or canceled.
class _AsyncStarStreamController {
  StreamController controller;
  Stream get stream => controller.stream;

  /// True when the async* function has yielded while being paused.
  /// When true execution will only resume after a `onResume` or `onCancel`
  /// event.
  bool isSuspended = false;

  bool get isPaused => controller.isPaused;

  Completer cancelationCompleter = null;

  /// True after the StreamSubscription has been cancelled.
  /// When this is true, errors thrown from the async* body should go to the
  /// [cancelationCompleter] instead of adding them to [controller], and
  /// returning from the async function should complete [cancelationCompleter].
  bool get isCanceled => cancelationCompleter != null;

  add(event) => controller.add(event);

  addStream(Stream stream) {
    return controller.addStream(stream, cancelOnError: false);
  }

  addError(error, stackTrace) => controller.addError(error, stackTrace);

  close() => controller.close();

  _AsyncStarStreamController(_WrappedAsyncBody body) {

    _resumeBody() {
      scheduleMicrotask(() {
        body(async_error_codes.SUCCESS, null);
      });
    }

    controller = new StreamController(
      onListen: () {
        _resumeBody();
      }, onResume: () {
        // Only schedule again if the async* function actually is suspended.
        // Resume directly instead of scheduling, so that the sequence
        // `pause-resume-pause` will result in one extra event produced.
        if (isSuspended) {
          isSuspended = false;
          _resumeBody();
        }
      }, onCancel: () {
        // If the async* is finished we ignore cancel events.
        if (!controller.isClosed) {
          cancelationCompleter = new Completer();
          if (isSuspended) {
            // Resume the suspended async* function to run finalizers.
            isSuspended = false;
            scheduleMicrotask(() {
              body(async_error_codes.STREAM_WAS_CANCELED, null);
            });
          }
          return cancelationCompleter.future;
        }
      });
  }
}

_makeAsyncStarController(body) {
  return new _AsyncStarStreamController(body);
}

class _IterationMarker {
  static const YIELD_SINGLE = 0;
  static const YIELD_STAR = 1;
  static const ITERATION_ENDED = 2;
  static const UNCAUGHT_ERROR = 3;

  final value;
  final int state;

  _IterationMarker._(this.state, this.value);

  static yieldStar(dynamic /* Iterable or Stream */ values) {
    return new _IterationMarker._(YIELD_STAR, values);
  }

  static endOfIteration() {
    return new _IterationMarker._(ITERATION_ENDED, null);
  }

  static yieldSingle(dynamic value) {
    return new _IterationMarker._(YIELD_SINGLE, value);
  }

  static uncaughtError(dynamic error) {
    return new _IterationMarker._(UNCAUGHT_ERROR, error);
  }

  toString() => "IterationMarker($state, $value)";
}

class _SyncStarIterator implements Iterator {
  final dynamic _body;

  // If [runningNested] this is the nested iterator, otherwise it is the
  // current value.
  dynamic _current = null;
  bool _runningNested = false;

  get current => _runningNested ? _current.current : _current;

  _SyncStarIterator(this._body);

  _runBody() {
    return JS('', '''
// Invokes [body] with [errorCode] and [result].
//
// If (and as long as) the invocation throws, calls [function] again,
// with an error-code.
(function(body) {
  var errorValue, errorCode = #;
  while (true) {
    try {
      return body(errorCode, errorValue);
    } catch (error) {
      errorValue = error;
      errorCode = #
    }
  }
})(#)''', async_error_codes.SUCCESS, async_error_codes.ERROR, _body);
  }


  bool moveNext() {
    if (_runningNested) {
      if (_current.moveNext()) {
        return true;
      } else {
        _runningNested = false;
      }
    }
    _current = _runBody();
    if (_current is _IterationMarker) {
      if (_current.state == _IterationMarker.ITERATION_ENDED) {
        _current = null;
        // Rely on [_body] to repeatedly return `ITERATION_ENDED`.
        return false;
      } else if (_current.state == _IterationMarker.UNCAUGHT_ERROR) {
        // Rely on [_body] to repeatedly return `UNCAUGHT_ERROR`.
        // This is a wrapped exception, so we use JavaScript throw to throw it.
        JS('', 'throw #', _current.value);
      } else {
        assert(_current.state == _IterationMarker.YIELD_STAR);
        _current = _current.value.iterator;
        _runningNested = true;
        return moveNext();
      }
    }
    return true;
  }
}

/// An Iterable corresponding to a sync* method.
///
/// Each invocation of a sync* method will return a new instance of this class.
class _SyncStarIterable extends IterableBase {
  // This is a function that will return a helper function that does the
  // iteration of the sync*.
  //
  // Each invocation should give a body with fresh state.
  final dynamic /* js function */ _outerHelper;

  _SyncStarIterable(this._outerHelper);

  Iterator get iterator => new _SyncStarIterator(JS('', '#()', _outerHelper));
}
