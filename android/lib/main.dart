import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

void main() {
  runApp(const ObdApp());
}

// ============================================================
//  Служебные UUID адаптера ELM327 (стандартные для BLE-клонов)
// ============================================================
const String serviceUuid = "0000fff0-0000-1000-8000-00805f9b34fb";
const String rxUuid = "0000fff2-0000-1000-8000-00805f9b34fb"; // пишем команды
const String txUuid = "0000fff1-0000-1000-8000-00805f9b34fb"; // читаем ответы

// Параметры, которые читаем: ключ -> (PID-команда, способ разбора)
const Map<String, List<String>> pidCommands = {
  "rpm": ["010C", "rpm"],
  "coolant": ["0105", "temp"],
  "speed": ["010D", "byte"],
  "voltage": ["0142", "voltage"],
  "fuel_trim_short": ["0106", "trim"],
  "fuel_trim_long": ["0107", "trim"],
  "throttle": ["0111", "throttle"],
  "maf": ["0110", "maf"],
  "intake_temp": ["010F", "temp"],
};

/// Расширенный набор параметров: ключ -> [PID, тип расчёта, подпись, единица, группа]
const List<List<String>> extendedParams = [
  ["engine_load", "0104", "pct", "Нагрузка двигателя", "%", "Двигатель"],
  ["throttle_rel", "0145", "pct", "Дроссель (относит.)", "%", "Двигатель"],
  ["timing", "010E", "timing", "Угол зажигания", "°", "Двигатель"],
  ["runtime", "011F", "two", "Время работы", "с", "Двигатель"],
  ["ambient_temp", "0146", "temp", "Темп. снаружи", "°C", "Температуры"],
  ["catalyst_temp", "013C", "cat", "Темп. катализатора", "°C", "Температуры"],
  ["fuel_pressure", "010A", "fuelpress", "Давление топлива", "кПа", "Топливо"],
  ["rail_pressure", "0122", "rail", "Давление в рампе", "кПа", "Топливо"],
  ["fuel_level", "012F", "pct", "Уровень топлива", "%", "Топливо"],
  ["fuel_rate", "015E", "fuelrate", "Расход топлива", "л/ч", "Топливо"],
  ["map", "010B", "byte", "Давление во впуске", "кПа", "Воздух"],
  ["baro", "0133", "byte", "Атмосферное давление", "кПа", "Воздух"],
  ["o2_b1s1", "0114", "o2", "Лямбда B1S1", "В", "Датчики кислорода"],
  ["o2_b1s2", "0115", "o2", "Лямбда B1S2", "В", "Датчики кислорода"],
  ["o2_b1s3", "0116", "o2", "Лямбда B1S3", "В", "Датчики кислорода"],
  ["o2_b1s4", "0117", "o2", "Лямбда B1S4", "В", "Датчики кислорода"],
  ["dist_cleared", "0131", "two", "Пробег после сброса", "км", "Пробег"],
];

// Подписи для плиток
const Map<String, String> tileLabels = {
  "rpm": "Обороты",
  "coolant": "Температура ОЖ",
  "speed": "Скорость",
  "voltage": "Напряжение",
  "fuel_trim_short": "Коррекция кратк.",
  "fuel_trim_long": "Коррекция долг.",
  "throttle": "Дроссель",
  "maf": "Расход воздуха",
  "intake_temp": "Темп. воздуха",
};

const Map<String, String> tileUnits = {
  "rpm": "об/мин",
  "coolant": "°C",
  "speed": "км/ч",
  "voltage": "В",
  "fuel_trim_short": "%",
  "fuel_trim_long": "%",
  "throttle": "%",
  "maf": "г/с",
  "intake_temp": "°C",
};

/// Протоколы ELM327 в порядке проверки: сначала авто, затем самые частые
const List<List<String>> _protocols = [
  ["0", "Автоопределение"],
  ["6", "CAN 11-бит, 500 кбод"],
  ["7", "CAN 29-бит, 500 кбод"],
  ["8", "CAN 11-бит, 250 кбод"],
  ["9", "CAN 29-бит, 250 кбод"],
  ["3", "ISO 9141-2"],
  ["5", "ISO 14230-4 KWP (быстрая инициализация)"],
  ["4", "ISO 14230-4 KWP (5 baud)"],
  ["1", "SAE J1850 PWM"],
  ["2", "SAE J1850 VPW"],
  ["A", "SAE J1939 CAN"],
];

/// Марка по первым трём знакам VIN (код производителя)
const Map<String, String> _vinMakes = {
  "JTD": "Toyota", "JTE": "Toyota", "JTF": "Toyota", "JTG": "Toyota",
  "JTH": "Toyota", "JTJ": "Toyota", "JTK": "Toyota", "JTL": "Toyota",
  "JTM": "Toyota", "JTN": "Toyota", "JTP": "Toyota", "JT2": "Toyota",
  "JT3": "Toyota", "JT4": "Toyota", "JT5": "Toyota", "JT6": "Toyota",
  "JT8": "Toyota", "JT1": "Toyota",
  "JN1": "Nissan", "JN3": "Nissan", "JN6": "Nissan", "JN8": "Nissan",
  "JNK": "Infiniti", "JNR": "Infiniti", "VSK": "Nissan", "SJN": "Nissan",
  "JHM": "Honda", "JHL": "Honda", "JHG": "Honda",
  "1HG": "Honda", "2HG": "Honda", "3HG": "Honda", "5FN": "Honda",
  "JM1": "Mazda", "JM3": "Mazda", "JMZ": "Mazda",
  "JF1": "Subaru", "JF2": "Subaru", "4S3": "Subaru", "4S4": "Subaru",
  "JA3": "Mitsubishi", "JA4": "Mitsubishi", "4A3": "Mitsubishi",
  "JMB": "Mitsubishi", "JMY": "Mitsubishi", "Z8T": "Mitsubishi",
  "JS1": "Suzuki", "JS2": "Suzuki", "JS3": "Suzuki", "TSM": "Suzuki",
  "KMH": "Hyundai", "KM8": "Hyundai", "KMU": "Hyundai", "5NP": "Hyundai",
  "KNA": "Kia", "KND": "Kia", "KNM": "Kia", "U5Y": "Kia",
  "KL4": "Daewoo", "KLA": "Daewoo",
  "WBA": "BMW", "WBS": "BMW", "WBU": "BMW", "WBX": "BMW", "WBY": "BMW",
  "WDB": "Mercedes-Benz", "WDC": "Mercedes-Benz", "WDD": "Mercedes-Benz",
  "WDF": "Mercedes-Benz", "W1K": "Mercedes-Benz", "W1N": "Mercedes-Benz",
  "WAU": "Audi", "WA1": "Audi", "TRU": "Audi", "WUA": "Audi",
  "WVW": "Volkswagen", "WV1": "Volkswagen", "WV2": "Volkswagen",
  "3VW": "Volkswagen", "1VW": "Volkswagen", "WVG": "Volkswagen",
  "TMB": "Skoda", "TMP": "Skoda", "TMT": "Skoda",
  "VF1": "Renault", "VF2": "Renault", "VFS": "Renault", "VF6": "Renault",
  "VF3": "Peugeot", "VF7": "Citroen",
  "YV1": "Volvo", "YV4": "Volvo", "YV2": "Volvo",
  "SAJ": "Jaguar", "SAL": "Land Rover", "SAD": "Land Rover",
  "ZFA": "Fiat", "ZFF": "Ferrari", "ZAR": "Alfa Romeo",
  "VSS": "SEAT", "VWV": "Volkswagen",
  "1FA": "Ford", "1FB": "Ford", "1FC": "Ford", "1FD": "Ford",
  "2FA": "Ford", "3FA": "Ford", "WF0": "Ford", "MAJ": "Ford",
  "1G1": "Chevrolet", "1GC": "Chevrolet", "2G1": "Chevrolet",
  "1GT": "GMC", "3GT": "GMC",
  "1C3": "Chrysler", "1C4": "Jeep", "1J4": "Jeep", "1J8": "Jeep",
  "1B3": "Dodge", "2B3": "Dodge",
  "5YJ": "Tesla", "7SA": "Tesla",
  "XTA": "Lada", "XTT": "Lada", "XTU": "Lada", "X9F": "Lada",
  "XW8": "Volkswagen", "X4X": "BMW",
  "LVV": "Chery", "LVT": "Chery", "LSV": "Chery",
  "LB3": "Geely", "L6T": "Geely",
  "LGW": "Haval", "LVS": "Changan",
};

class ObdApp extends StatelessWidget {
  const ObdApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "OBD-Диагност",
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E141A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF35C28F),
          surface: Color(0xFF172029),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _tx; // уведомления (ответы)
  BluetoothCharacteristic? _rx; // запись команд

  bool _connected = false;
  String _status = "Не подключено";
  String _adapterName = "—";

  Map<String, double?> _live = {};
  List<String> _dtcCodes = [];
  List<String> _scanResults = [];
  String _debug = ""; // последние сырые байты от адаптера
  String _cmdDebug = ""; // последний разобранный ответ
  String _protocolName = ""; // определённый протокол связи
  String _vin = ""; // VIN, прочитанный из ЭБУ
  String _detectedMake = ""; // марка, определённая по VIN
  Map<String, double?> _extended = {}; // расширенные параметры
  String _extStatus = ""; // статус чтения расширенных параметров

  final StringBuffer _replyBuffer = StringBuffer();
  Completer<String>? _replyCompleter;
  Timer? _pollTimer;
  bool _scanning = false;

  @override
  void dispose() {
    _pollTimer?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  // ----------------------------------------------------------
  //  Сканирование устройств
  // ----------------------------------------------------------
  Future<void> _startScan() async {
    setState(() {
      _scanResults = [];
      _scanning = true;
      _status = "Ищу адаптер…";
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } catch (e) {
      setState(() {
        _status = "Ошибка сканирования: $e";
        _scanning = false;
      });
      return;
    }

    FlutterBluePlus.scanResults.listen((results) {
      final names = <String>{};
      for (final r in results) {
        final name = r.device.platformName.trim();
        if (name.isNotEmpty) {
          names.add(name);
        }
      }
      if (mounted) {
        setState(() {
          _scanResults = names.toList()..sort();
        });
      }
    });

    FlutterBluePlus.isScanning.listen((scanning) {
      if (!scanning && mounted) {
        setState(() => _scanning = false);
      }
    });
  }

  // ----------------------------------------------------------
  //  Подключение к выбранному устройству
  // ----------------------------------------------------------
  Future<void> _connectByName(String name) async {
    setState(() => _status = "Подключаюсь к $name…");
    try {
      await FlutterBluePlus.stopScan();

      BluetoothDevice? device;
      for (final r in FlutterBluePlus.lastScanResults) {
        if (r.device.platformName.trim() == name) {
          device = r.device;
          break;
        }
      }
      if (device == null) {
        for (final d in await FlutterBluePlus.systemDevices([])) {
          if (d.platformName.trim() == name) {
            device = d;
            break;
          }
        }
      }
      if (device == null) {
        setState(() => _status = "Устройство не найдено. Повторите поиск.");
        return;
      }
      await _connect(device);
    } catch (e) {
      setState(() => _status = "Ошибка: $e");
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    _device = device;
    _device!.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && mounted) {
        setState(() {
          _connected = false;
          _status = "Соединение потеряно";
        });
      }
    });

    await device.connect(autoConnect: false, license: License.nonprofit);
    setState(() {
      _connected = true;
      _adapterName = device.platformName;
      _status = "Подключено. Инициализирую…";
    });

    final services = await device.discoverServices();
    for (final service in services) {
      if (service.uuid.toString().toUpperCase().contains("FFF0")) {
        for (final ch in service.characteristics) {
          final uuid = ch.uuid.toString().toUpperCase();
          if (uuid.contains("FFF1")) {
            _tx = ch;
            await ch.setNotifyValue(true);
          } else if (uuid.contains("FFF2")) {
            _rx = ch;
          }
        }
      }
    }

    if (_rx == null || _tx == null) {
      setState(() => _status = "Не найдены характеристики ELM327");
      return;
    }

    _tx!.lastValueStream.listen((value) {
      _onData(value);
    });

    await _initialize();
    setState(() => _status = "Подключено");
    _startPolling();
  }

  // ----------------------------------------------------------
  //  Приём данных от адаптера
  // ----------------------------------------------------------
  void _onData(List<int> value) {
    final text = utf8.decode(value, allowMalformed: true);
    _replyBuffer.write(text);

    // Показываем, что именно приходит от адаптера (для отладки)
    if (mounted) {
      setState(() {
        _debug = "пришло ${value.length} байт: ${value.take(30).toString()}";
      });
    }

    // Ответ ELM327 заканчивается символом ">"
    if (_replyBuffer.toString().contains(">")) {
      final completer = _replyCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(_replyBuffer.toString());
        _replyBuffer.clear();
      }
    }
  }

  // ----------------------------------------------------------
  //  Отправка команды и ожидание ответа
  // ----------------------------------------------------------
  Future<String> _command(String cmd,
      {Duration timeout = const Duration(seconds: 3)}) async {
    if (_rx == null) return "";
    _replyBuffer.clear();
    _replyCompleter = Completer<String>();

    final bytes = Uint8List.fromList(ascii.encode("$cmd\r"));

    // Выбираем тип записи по свойствам характеристики адаптера:
    // на Mac он требует "с ответом", на Android бывает "без ответа"
    final withoutResponse = _rx!.properties.writeWithoutResponse;
    await _rx!.write(bytes, withoutResponse: withoutResponse);

    try {
      return await _replyCompleter!.future.timeout(timeout);
    } on TimeoutException {
      return _replyBuffer.toString();
    }
  }

  Future<void> _initialize() async {
    // Без ATZ: сброс рвёт BLE-соединение у многих адаптеров
    await _command("ATE0");
    await _command("ATL0");
    await _command("ATH0");
    await Future.delayed(const Duration(milliseconds: 200));

    // Автоподбор протокола: автоопределение работает не на всех машинах
    await _command("ATSP0");
    await Future.delayed(const Duration(milliseconds: 250));

    for (final protocol in _protocols) {
      await _command("ATSP${protocol[0]}");
      await Future.delayed(const Duration(milliseconds: 250));
      final answer =
          await _command("0100", timeout: const Duration(seconds: 4));
      if (answer.contains("41")) {
        setState(() => _protocolName = protocol[1]);
        break;
      }
    }

    // Определяем марку по VIN из ЭБУ
    await _readVehicleInfo();
  }

  Future<void> _readVehicleInfo() async {
    final answer = await _command("0902", timeout: const Duration(seconds: 6));
    final codes = <int>[];

    for (final line in answer.split("\n")) {
      final raw = _parseLine(line);
      if (raw == null || raw.length < 3) continue;
      if (raw[0] == 0x49 && raw[1] == 0x02) {
        for (final byte in raw.sublist(3)) {
          if (byte >= 0x20 && byte <= 0x7E) codes.add(byte);
        }
      }
    }

    var vin = String.fromCharCodes(codes).trim();
    if (vin.length >= 17) {
      vin = vin.substring(vin.length - 17);
    }
    final make = vin.length == 17 ? _vinToMake(vin) : "";

    if (mounted) {
      setState(() {
        _vin = vin.length == 17 ? vin : "";
        _detectedMake = make;
      });
    }
  }

  static String _vinToMake(String vin) {
    final prefix = vin.substring(0, 3).toUpperCase();
    return _vinMakes[prefix] ?? "";
  }

  // ----------------------------------------------------------
  //  Разбор ответов ELM327
  // ----------------------------------------------------------
  static bool _isHex(String s) {
    const hex = "0123456789ABCDEF";
    for (final ch in s.toUpperCase().split('')) {
      if (!hex.contains(ch)) return false;
    }
    return true;
  }

  Uint8List? _parseLine(String line) {
    var cleaned = line
        .replaceAll(">", "")
        .replaceAll("\r", "")
        .replaceAll(" ", "") // убираем пробелы: ответ может быть "41 0C" или "410C"
        .trim()
        .toUpperCase();
    if (cleaned.isEmpty || !_isHex(cleaned)) return null;
    if (cleaned.length.isOdd) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    if (cleaned.isEmpty) return null;
    final bytes = <int>[];
    for (var i = 0; i + 1 < cleaned.length; i += 2) {
      bytes.add(int.parse(cleaned.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  double? _parsePidValue(String kind, List<int> payload) {
    if (kind == "rpm" && payload.length >= 2) {
      return (payload[0] * 256 + payload[1]) / 4;
    }
    if (kind == "temp" && payload.isNotEmpty) {
      return (payload[0] - 40).toDouble();
    }
    if (kind == "byte" && payload.isNotEmpty) {
      return payload[0].toDouble();
    }
    if (kind == "voltage" && payload.length >= 2) {
      return (payload[0] * 256 + payload[1]) / 1000;
    }
    if (kind == "trim" && payload.isNotEmpty) {
      return (payload[0] - 128) * 100 / 128;
    }
    if (kind == "throttle" && payload.isNotEmpty) {
      return payload[0] * 100 / 255;
    }
    if (kind == "maf" && payload.length >= 2) {
      return (payload[0] * 256 + payload[1]) / 100;
    }
    // --- расширенные параметры ---
    if (kind == "pct" && payload.isNotEmpty) {
      return payload[0] * 100 / 255;
    }
    if (kind == "timing" && payload.isNotEmpty) {
      return payload[0] / 2 - 64;
    }
    if (kind == "two" && payload.length >= 2) {
      return (payload[0] * 256 + payload[1]).toDouble();
    }
    if (kind == "cat" && payload.length >= 2) {
      return (payload[0] * 256 + payload[1]) / 10 - 40;
    }
    if (kind == "fuelpress" && payload.isNotEmpty) {
      return payload[0] * 3;
    }
    if (kind == "rail" && payload.length >= 2) {
      return (payload[0] * 256 + payload[1]) * 0.079;
    }
    if (kind == "fuelrate" && payload.length >= 2) {
      return (payload[0] * 256 + payload[1]) / 20;
    }
    if (kind == "o2" && payload.isNotEmpty) {
      return payload[0] / 200;
    }
    return null;
  }

  // ----------------------------------------------------------
  //  Чтение параметров
  // ----------------------------------------------------------
  Future<void> _readPids() async {
    final live = <String, double?>{};
    for (final entry in pidCommands.entries) {
      final pid = entry.value[0];
      final kind = entry.value[1];
      final answer =
          await _command(pid, timeout: const Duration(seconds: 2));
      if (entry.key == "rpm") {
        _cmdDebug = "010C => '$answer'";
      }

      final expectedPid = int.parse(pid.substring(2), radix: 16);
      for (final line in answer.split("\n")) {
        final raw = _parseLine(line);
        if (raw != null &&
            raw.length >= 3 &&
            raw[0] == 0x41 &&
            raw[1] == expectedPid) {
          live[entry.key] = _parsePidValue(kind, raw.sublist(2));
        }
      }
    }

    if (mounted) {
      setState(() {
        _live = live;
      });
    }
  }

  // ----------------------------------------------------------
  //  Чтение кодов ошибок
  // ----------------------------------------------------------
  Future<void> _readDtc() async {
    setState(() => _status = "Читаю ошибки…");
    final answer = await _command("03", timeout: const Duration(seconds: 4));
    final codes = <String>[];

    for (final line in answer.split("\n")) {
      final raw = _parseLine(line);
      if (raw != null && raw.isNotEmpty && raw[0] == 0x43) {
        final data = raw.sublist(1);
        for (var i = 0; i + 1 < data.length; i += 2) {
          final code = _decodeDtc(data[i], data[i + 1]);
          if (code.isNotEmpty) codes.add(code);
        }
      }
    }

    setState(() {
      _dtcCodes = codes.toSet().toList();
      _status = "Подключено";
    });
  }

  /// Стирает коды ошибок из блоков управления (режим 04).
  Future<void> _clearDtc() async {
    setState(() => _status = "Стираю ошибки…");
    final answer = await _command("04", timeout: const Duration(seconds: 6));
    final text = answer.replaceAll(RegExp(r"\s"), "").toUpperCase();
    final ok = text.contains("44") || text.startsWith("OK");

    setState(() {
      _status = ok ? "Ошибки стёрты" : "Не удалось стереть ошибки";
      if (ok) _dtcCodes = [];
    });

    if (ok) {
      await _readPids();
    }
  }

  /// Читает расширенный набор параметров.
  Future<void> _readExtended() async {
    setState(() => _extStatus = "Читаю все датчики…");
    final values = <String, double?>{};

    for (final param in extendedParams) {
      final key = param[0];
      final pid = param[1];
      final kind = param[2];
      final answer = await _command(pid, timeout: const Duration(seconds: 2));

      final expectedPid = int.parse(pid.substring(2), radix: 16);
      for (final line in answer.split("\n")) {
        final raw = _parseLine(line);
        if (raw != null &&
            raw.length >= 3 &&
            raw[0] == 0x41 &&
            raw[1] == expectedPid) {
          values[key] = _parsePidValue(kind, raw.sublist(2));
        }
      }
    }

    setState(() {
      _extended = values;
      _extStatus = "Готово";
    });
  }

  String _decodeDtc(int first, int second) {
    if (first == 0 && second == 0) return "";
    const letters = ["P", "C", "B", "U"];
    final letter = letters[(first >> 6) & 0x03];
    final d1 = (first >> 4) & 0x03;
    final d2 = first & 0x0F;
    final d3 = (second >> 4) & 0x0F;
    final d4 = second & 0x0F;
    return "$letter$d1$d2$d3$d4";
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_connected && _rx != null) {
        _readPids();
      }
    });
  }

  // ----------------------------------------------------------
  //  Интерфейс
  // ----------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("OBD-Диагност"),
        backgroundColor: const Color(0xFF172029),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _connected ? _readPids : _startScan,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _statusCard(),
            const SizedBox(height: 16),
            _liveTiles(),
            const SizedBox(height: 16),
            _dtcSection(),
            const SizedBox(height: 16),
            _extendedSection(),
            const SizedBox(height: 16),
            _scanSection(),
          ],
        ),
      ),
    );
  }

  Widget _statusCard() {
    final color = _connected ? const Color(0xFF35C28F) : Colors.orangeAccent;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172029),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF26333F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                _connected ? "Подключено" : "Не подключено",
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text("Адаптер: $_adapterName",
              style: const TextStyle(color: Colors.grey)),
          if (_detectedMake.isNotEmpty)
            Text("Автомобиль: $_detectedMake",
                style: const TextStyle(
                    color: Color(0xFF35C28F), fontWeight: FontWeight.w600)),
          if (_vin.isNotEmpty)
            Text("VIN: $_vin", style: const TextStyle(color: Colors.grey)),
          if (_protocolName.isNotEmpty)
            Text("Протокол: $_protocolName",
                style: const TextStyle(color: Colors.grey)),
          Text(_status, style: const TextStyle(color: Colors.grey)),
          if (_debug.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_debug,
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 11)),
            ),
          if (_cmdDebug.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_cmdDebug,
                  style: const TextStyle(
                      color: Colors.yellowAccent, fontSize: 11)),
            ),
        ],
      ),
    );
  }

  Widget _liveTiles() {
    final entries = pidCommands.keys.toList();
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: entries.map((key) {
        final value = _live[key];
        return Container(
          width: 150,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF1F2A35),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF26333F)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tileLabels[key]!,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 4),
              Text(
                value == null ? "—" : _format(value),
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              Text(tileUnits[key]!,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        );
      }).toList(),
    );
  }

  String _format(double value) {
    if (value == value.roundToDouble()) {
      return value.round().toString();
    }
    return value.toStringAsFixed(1);
  }

  Widget _dtcSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172029),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF26333F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Ошибки",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Row(
            children: [
              ElevatedButton(
                onPressed: _connected ? _readDtc : null,
                child: const Text("Чтение ошибок"),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _connected ? _confirmClear : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0x33E5484D),
                  foregroundColor: const Color(0xFFFF9A9C),
                ),
                child: const Text("Стереть"),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_dtcCodes.isEmpty)
            const Text("Ошибок не найдено", style: TextStyle(color: Colors.grey))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _dtcCodes
                  .map((code) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0x29E5484D),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(code,
                            style: const TextStyle(
                                color: Color(0xFFFF9A9C),
                                fontWeight: FontWeight.bold)),
                      ))
                  .toList(),
            ),
        ],
      ),
    );
  }

  /// Спрашивает подтверждение и стирает ошибки.
  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text("Стереть ошибки?"),
        content: const Text(
          "Погаснет лампа Check Engine. Если неисправность не устранена, "
          "ошибка появится снова. Также сбросится готовность к техосмотру.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text("Отмена"),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text("Стереть"),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _clearDtc();
    }
  }

  Widget _extendedSection() {
    // Группируем параметры по системам автомобиля
    final groups = <String, List<List<String>>>{};
    for (final param in extendedParams) {
      groups.putIfAbsent(param[4], () => []).add(param);
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172029),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF26333F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Все параметры",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text("Полный набор датчиков: чтение занимает несколько секунд.",
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 10),
          Row(
            children: [
              ElevatedButton(
                onPressed: _connected ? _readExtended : null,
                child: const Text("Прочитать все"),
              ),
              const SizedBox(width: 10),
              Text(_extStatus, style: const TextStyle(color: Colors.grey)),
            ],
          ),
          const SizedBox(height: 12),
          ...groups.entries.map((entry) {
            final rows = entry.value
                .where((param) => _extended[param[0]] != null)
                .toList();
            if (rows.isEmpty) {
              return const SizedBox.shrink();
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entry.key,
                    style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: rows.map((param) {
                    final value = _extended[param[0]]!;
                    return Container(
                      width: 150,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2A35),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF26333F)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(param[3],
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                          const SizedBox(height: 2),
                          Text("${_format(value)} ${param[4]}",
                              style: const TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
              ],
            );
          }),
        ],
      ),
    );
  }

  Widget _scanSection() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF172029),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF26333F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Подключение к адаптеру",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: _scanning ? null : _startScan,
            child: Text(_scanning ? "Поиск…" : "Найти адаптер"),
          ),
          const SizedBox(height: 10),
          if (_scanResults.isEmpty && !_scanning)
            const Text("Нажмите кнопку, чтобы найти BLE-адаптер",
                style: TextStyle(color: Colors.grey)),
          ..._scanResults.map((name) => ListTile(
                leading:
                    const Icon(Icons.bluetooth, color: Color(0xFF35C28F)),
                title: Text(name),
                onTap: () => _connectByName(name),
              )),
        ],
      ),
    );
  }
}
