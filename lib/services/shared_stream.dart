import 'dart:async';

/// One live database listener shared by every screen that wants the same data.
///
/// New listeners get the latest value straight away. When nobody has listened for a
/// little while the underlying listener is closed, so nothing keeps running in the
/// background.
class SharedStream<T> {
  final Stream<T> Function() _open;
  final void Function()? _onClosed;
  final Duration _grace;

  late final StreamController<T> _controller = StreamController<T>.broadcast(onListen: _start, onCancel: _maybeStop);
  StreamSubscription<T>? _source;
  Timer? _stopTimer;
  bool _hasValue = false;
  late T _last;

  SharedStream(this._open, {void Function()? onClosed, Duration grace = const Duration(seconds: 20)})
      : _onClosed = onClosed,
        _grace = grace;

  Stream<T> get stream => Stream<T>.multi((listener) {
        if (_hasValue) listener.add(_last);
        final sub = _controller.stream.listen(listener.add, onError: listener.addError, onDone: listener.close);
        listener.onCancel = sub.cancel;
      });

  bool get hasValue => _hasValue;
  T? get latest => _hasValue ? _last : null;

  void _start() {
    _stopTimer?.cancel();
    _source ??= _open().listen(
      (value) {
        _hasValue = true;
        _last = value;
        _controller.add(value);
      },
      onError: _controller.addError,
      // If the database ends the listener (an error, say), open a fresh one next time.
      onDone: () => _source = null,
    );
  }

  void _maybeStop() {
    _stopTimer?.cancel();
    _stopTimer = Timer(_grace, () {
      if (_controller.hasListener) return;
      _source?.cancel();
      _source = null;
      _hasValue = false;
      _onClosed?.call();
    });
  }
}
