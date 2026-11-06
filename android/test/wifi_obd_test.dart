import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:obd_diagnost/wifi_obd.dart';

/// Простой «виртуальный ELM327»: сначала изображает инициализацию шины
/// (`BUS INIT` без завершающего `>`), а после команды `ATI` освобождается,
/// как настоящий адаптер.
class _FakeElm {
  _FakeElm._(this._server) {
    _server.listen((socket) {
      socket.listen((data) => _onData(socket, data), onError: (Object _) {});
    });
  }

  final ServerSocket _server;
  final List<String> received = [];
  String _pending = "";
  bool busy = true;

  int get port => _server.port;

  static Future<_FakeElm> start() async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    return _FakeElm._(server);
  }

  void _onData(Socket socket, List<int> data) {
    _pending += utf8.decode(data, allowMalformed: true);
    while (_pending.contains("\r")) {
      final index = _pending.indexOf("\r");
      final command = _pending.substring(0, index).trim();
      _pending = _pending.substring(index + 1);
      if (command.isEmpty) {
        continue;
      }
      received.add(command);
      _handle(socket, command);
    }
  }

  void _handle(Socket socket, String command) {
    if (command == "ATI") {
      busy = false;
      socket.write("STOPPED\r\rELM327 v1.5\r\r>");
      return;
    }
    if (command == "0100") {
      if (busy) {
        // Адаптер ещё ищет шину и не присылает ">" — это и есть таймаут.
        socket.write("BUS INIT: ...");
        return;
      }
      socket.write("41 00 BE 3E B8 13\r\r>");
      return;
    }
    socket.write("OK\r\r>");
  }

  Future<void> close() async {
    await _server.close();
  }
}

void main() {
  test("после таймаута адаптер освобождается и данные читаются", () async {
    final fake = await _FakeElm.start();
    final wifi = WifiObd();
    await wifi.connect("127.0.0.1", port: fake.port);

    final first = await wifi.command(
      "0100",
      timeout: const Duration(milliseconds: 400),
    );
    expect(first, contains("BUS INIT"), reason: "первый ответ — инициализация");

    final second = await wifi.command(
      "0100",
      timeout: const Duration(seconds: 2),
    );
    expect(second, contains("41 00"), reason: "после сброса приходят данные");
    expect(fake.received, contains("ATI"), reason: "линия сброшена через ATI");

    await wifi.disconnect();
    await fake.close();
  });
}
