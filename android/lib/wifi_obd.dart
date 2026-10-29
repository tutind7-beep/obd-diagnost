import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Связь с Wi-Fi адаптером ELM327.
///
/// Такой адаптер создаёт свою Wi-Fi сеть (обычно `WiFi_OBDII`), телефон
/// подключается к ней, а команды идут по TCP на порт 35000. Протокол тот же,
/// что у Bluetooth: отправляем команду с символом возврата каретки, ждём ответ
/// до символа `>`.
class WifiObd {
  WifiObd({this.onDisconnected});

  /// Вызывается, когда соединение оборвалось (адаптер выключили, ушли из сети).
  final void Function()? onDisconnected;

  Socket? _socket;
  final StringBuffer _buffer = StringBuffer();
  Completer<void>? _waiter;
  bool _closed = false;

  bool get isConnected => _socket != null;

  /// Подключается к адаптеру. [host] — адрес из сети адаптера.
  Future<void> connect(String host, {int port = 35000}) async {
    await close();

    _buffer.clear();
    _closed = false;

    final socket = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 8),
    );
    _socket = socket;

    socket.listen(
      (data) {
        _buffer.write(utf8.decode(data, allowMalformed: true));
        _completeIfReady();
      },
      onError: (Object error) => _close(),
      onDone: _close,
      cancelOnError: true,
    );
  }

  Future<String> command(
    String text, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final socket = _socket;
    if (socket == null) {
      return "";
    }

    _buffer.clear();
    _waiter = Completer<void>();

    try {
      socket.write("$text\r");
      await _waiter!.future.timeout(timeout);
      return _buffer.toString();
    } on TimeoutException {
      return _buffer.toString();
    } finally {
      _waiter = null;
    }
  }

  Future<void> close() async {
    _closed = true;
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      socket.destroy();
    }
  }

  /// Отключение по нашей инициативе: без уведомления интерфейса.
  Future<void> disconnect() async {
    if (_socket != null) {
      _closed = true;
      final socket = _socket;
      _socket = null;
      socket?.destroy();
    }
  }

  void _close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _socket?.destroy();
    _socket = null;
    onDisconnected?.call();
  }

  void _completeIfReady() {
    final waiter = _waiter;
    if (waiter == null || waiter.isCompleted) {
      return;
    }
    if (_buffer.toString().contains(">")) {
      waiter.complete();
    }
  }
}
