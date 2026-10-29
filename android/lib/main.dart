import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'package:speech_to_text/speech_to_text.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api_client.dart';
import 'wifi_obd.dart';

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

/// Быстрый выбор частых жалоб
const List<String> symptomChoices = [
  "троит двигатель",
  "дёргается при разгоне",
  "не заводится",
  "перегревается",
  "горит Check Engine",
  "потеря мощности",
  "повышенный расход топлива",
  "стук или шум из двигателя",
  "запах бензина",
  "вибрация на холостых оборотах",
  "дым из выхлопной трубы",
  "нестабильные холостые обороты",
];

/// Типовые блоки управления: [название, адрес запроса, адрес ответа]
const List<List<String>> defaultModules = [
  ["Двигатель (ECM)", "7E0", "7E8"],
  ["Коробка передач (TCM)", "7E1", "7E9"],
  ["Блок 3", "7E2", "7EA"],
  ["Блок 4", "7E3", "7EB"],
  ["Блок 5", "7E4", "7EC"],
  ["Блок 6", "7E5", "7ED"],
  ["Блок 7", "7E6", "7EE"],
  ["Блок 8", "7E7", "7EF"],
];

/// Сколько точек храним в истории графиков (около 5 минут)
const int chartMaxPoints = 120;

/// Точка графика: время и значение параметра
class ChartPoint {
  ChartPoint(this.time, this.value);

  final DateTime time;
  final double value;
}

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
  List<String> _chartKeys = []; // параметры, для которых строятся графики
  final Map<String, List<ChartPoint>> _chartData = {}; // истории значений для графиков
  String _chartChoice = "rpm"; // выбранный в списке параметр

  // --- Облако: аккаунт, советы ИИ, история ---
  ApiClient? _api;
  bool _cloudBusy = false;
  String _cloudStatus = "";
  String _adviceText = "";
  String _advicePart = "";
  String _adviceCost = "";
  String _adviceStatus = "";

  // --- Блоки управления ---
  List<Map<String, dynamic>> _modules = [];
  String _moduleStatus = "";
  bool _moduleBusy = false;

  // --- Симптомы и голосовой ввод ---
  final Set<String> _symptoms = {};
  String _symptomText = "";
  String _symptomStatus = "";
  String _symptomResult = "";
  List<Map<String, dynamic>> _symptomParts = [];
  bool _symptomBusy = false;
  final SpeechToText _speech = SpeechToText();
  bool _speechReady = false;
  bool _listening = false;

  // --- Тип подключения: Bluetooth LE или Wi-Fi адаптер ---
  WifiObd? _wifi;
  String _transport = "ble"; // "ble" или "wifi"
  final TextEditingController _wifiHostController =
      TextEditingController(text: "192.168.0.10");
  final TextEditingController _modelController = TextEditingController();
  final TextEditingController _yearController = TextEditingController();
  String _dataWarning = ""; // предупреждение, если ЭБУ не отдаёт данные

  // --- Журнал работы (для поиска причин сбоев) ---
  final List<String> _logs = [];
  static const int _logLimit = 500;

  final StringBuffer _replyBuffer = StringBuffer();
  Completer<String>? _replyCompleter;
  Timer? _pollTimer;
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    _restoreCloudSession();
    _initSpeech();
  }

  /// Восстанавливает вход в аккаунт, если он был сохранён.
  Future<void> _restoreCloudSession() async {
    final client = await ApiClient.restore();
    if (mounted) {
      setState(() {
        _api = client;
        _cloudStatus = client.isLoggedIn
            ? "Вы вошли как ${client.email}"
            : "Вход не выполнен — история и ИИ недоступны";
      });
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _device?.disconnect();
    _wifi?.disconnect();
    _wifiHostController.dispose();
    _modelController.dispose();
    _yearController.dispose();
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

    if (!await FlutterBluePlus.isSupported) {
      setState(() {
        _status = "Этот телефон не поддерживает Bluetooth LE. "
            "Используйте Wi-Fi адаптер (переключите тип подключения).";
        _scanning = false;
      });
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      setState(() {
        _status = adapterState == BluetoothAdapterState.off
            ? "Bluetooth выключен. Включите его в шторке телефона и повторите поиск."
            : "Bluetooth сейчас недоступен ($adapterState). "
                "Проверьте настройки или перезагрузите телефон.";
        _scanning = false;
      });
      return;
    }

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 12));
    } on PlatformException catch (error) {
      final message = (error.message ?? "").toLowerCase();
      setState(() {
        _status = message.contains("permission")
            ? "Нет разрешения на Bluetooth. Разрешите доступ в настройках приложения."
            : "Bluetooth не смог начать поиск: ${error.message ?? error.code}";
        _scanning = false;
      });
      return;
    } catch (error) {
      setState(() {
        _status = "Ошибка поиска адаптера: $error";
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
    _log("Подключение к ${device.platformName}");
    _device = device;
    _device!.connectionState.listen((state) {
      if (state == BluetoothConnectionState.disconnected && mounted) {
        _log("Соединение потеряно");
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
    await _pickChannels(services);

    if (_rx == null || _tx == null) {
      _log("Ошибка: не найдены каналы обмена");
      setState(() => _status = "Адаптер не похож на ELM327: не найдены каналы "
          "обмена. Попробуйте другой адаптер или подключение по Wi-Fi.");
      return;
    }
    _log("Каналы: ${_tx!.uuid} (ответы), ${_rx!.uuid} (команды)");

    _transport = "ble";
    await _tx!.setNotifyValue(true);
    _tx!.lastValueStream.listen(_onData);

    final ready = await _initialize();
    if (!ready) {
      return;
    }
    setState(() => _status = "Подключено");
    _startPolling();
  }

  /// Ищет каналы обмена: разные клоны ELM327 используют разные сервисы.
  Future<void> _pickChannels(List<BluetoothService> services) async {
    BluetoothCharacteristic? fallbackNotify;
    BluetoothCharacteristic? fallbackWrite;

    for (final service in services) {
      final serviceId = service.uuid.toString().toUpperCase();
      for (final characteristic in service.characteristics) {
        final id = characteristic.uuid.toString().toUpperCase();

        // Классический ELM327: FFF0, ответы в FFF1, команды в FFF2
        if (serviceId.contains("FFF0")) {
          if (id.contains("FFF1")) _tx = characteristic;
          if (id.contains("FFF2")) _rx = characteristic;
        }

        // HM-10 и подобные: FFE0, всё через FFE1
        if (serviceId.contains("FFE0") && id.contains("FFE1")) {
          _tx = characteristic;
          _rx = characteristic;
        }

        // Nordic UART: 6E400001, запись в 6E400002, ответы из 6E400003
        if (serviceId.contains("6E400001")) {
          if (id.contains("6E400002")) _rx = characteristic;
          if (id.contains("6E400003")) _tx = characteristic;
        }

        // Запасной вариант: берём любые подходящие характеристики
        if (fallbackNotify == null && characteristic.properties.notify) {
          fallbackNotify = characteristic;
        }
        if (fallbackWrite == null &&
            (characteristic.properties.write ||
                characteristic.properties.writeWithoutResponse)) {
          fallbackWrite = characteristic;
        }
      }
    }

    _tx ??= fallbackNotify;
    _rx ??= fallbackWrite;
  }

  /// Подключение к Wi-Fi адаптеру (ELM327 по TCP).
  Future<void> _connectWifi() async {
    final host = _wifiHostController.text.trim();
    if (host.isEmpty) {
      setState(() => _status = "Введите IP-адрес адаптера, например 192.168.0.10");
      return;
    }

    setState(() {
      _status = "Подключаюсь к $host…";
      _scanning = false;
    });

    try {
      await _wifi?.disconnect();
      final wifi = WifiObd(onDisconnected: () {
        if (!mounted) {
          return;
        }
        setState(() {
          _connected = false;
          _status = "Связь с Wi-Fi адаптером потеряна";
        });
      });

      await wifi.connect(host);
      _wifi = wifi;
      _transport = "wifi";
      _adapterName = "Wi-Fi $host";

      setState(() {
        _connected = true;
        _status = "Подключено. Инициализирую…";
      });

      final ready = await _initialize();
      if (!ready) {
        return;
      }
      setState(() => _status = "Подключено");
      _startPolling();
    } on SocketException catch (error) {
      _log("Wi-Fi: $error");
      setState(() => _status = "Не удалось подключиться к $host. "
          "Проверьте, что телефон подключён к Wi-Fi сети адаптера "
          "(обычно WiFi_OBDII) и адрес верный.");
    } catch (error) {
      _log("Wi-Fi: $error");
      setState(() => _status = "Ошибка подключения по Wi-Fi: $error");
    }
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
    if (_transport == "wifi") {
      final wifi = _wifi;
      if (wifi == null || !wifi.isConnected) {
        _log("→ $cmd: нет соединения с Wi-Fi адаптером");
        return "";
      }
      final answer = await wifi.command(cmd, timeout: timeout);
      _log("→ $cmd  ← ${_shorten(answer)}");
      return answer;
    }

    if (_rx == null) {
      _log("→ $cmd: канал записи не найден");
      return "";
    }
    _replyBuffer.clear();
    _replyCompleter = Completer<String>();

    final bytes = Uint8List.fromList(ascii.encode("$cmd\r"));

    // Выбираем тип записи по свойствам характеристики адаптера:
    // на Mac он требует "с ответом", на Android бывает "без ответа"
    final withoutResponse = _rx!.properties.writeWithoutResponse;
    await _rx!.write(bytes, withoutResponse: withoutResponse);

    try {
      final answer = await _replyCompleter!.future.timeout(timeout);
      _log("→ $cmd  ← ${_shorten(answer)}");
      return answer;
    } on TimeoutException {
      final partial = _replyBuffer.toString();
      _log("→ $cmd  ← таймаут, получено: ${_shorten(partial)}");
      return partial;
    }
  }

  /// Сокращает длинный ответ для журнала.
  String _shorten(String text, {int limit = 120}) {
    final oneLine = text.replaceAll("\r", "").replaceAll("\n", " ").trim();
    if (oneLine.length <= limit) {
      return oneLine.isEmpty ? "(пусто)" : oneLine;
    }
    return "${oneLine.substring(0, limit)}…";
  }

  /// Готовит адаптер к работе. Возвращает false, если ЭБУ не отвечает.
  Future<bool> _initialize() async {
    // Без ATZ: сброс рвёт BLE-соединение у многих адаптеров
    await _command("ATE0");
    await _command("ATL0");
    await _command("ATH0");
    await Future.delayed(const Duration(milliseconds: 200));

    // Автоподбор протокола: автоопределение работает не на всех машинах
    await _command("ATSP0");
    await Future.delayed(const Duration(milliseconds: 250));

    var protocolFound = false;
    for (final protocol in _protocols) {
      await _command("ATSP${protocol[0]}");
      await Future.delayed(const Duration(milliseconds: 250));
      final answer =
          await _command("0100", timeout: const Duration(seconds: 4));
      if (answer.contains("41")) {
        _log("Протокол: ${protocol[1]}");
        setState(() {
          _protocolName = protocol[1];
          _dataWarning = "";
        });
        protocolFound = true;
        break;
      }
    }

    if (!protocolFound) {
      _log("Протокол не определён: машина не отвечает");
      setState(() {
        _protocolName = "";
        _status = "Адаптер подключён, но машина не отвечает. "
            "Проверьте: зажигание включено? Адаптер вставлен в разъём OBD-II "
            "до щелчка? Машина поддерживает OBD-II (после 2001 года)?";
      });
      return false;
    }

    // Определяем марку по VIN из ЭБУ
    await _readVehicleInfo();
    return true;
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

    _log("VIN: ${vin.isEmpty ? "не прочитан" : vin}, марка: ${make.isEmpty ? "?" : make}");

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

    // Читаем параметры, для которых построены графики (если их нет среди основных)
    final chartValues = <String, double?>{};
    for (final key in _chartKeys) {
      if (live.containsKey(key) && live[key] != null) {
        chartValues[key] = live[key];
        continue;
      }
      final param = _paramByKey(key);
      if (param == null) {
        continue;
      }
      final answer = await _command(param[1], timeout: const Duration(seconds: 2));
      final expectedPid = int.parse(param[1].substring(2), radix: 16);
      for (final line in answer.split("\n")) {
        final raw = _parseLine(line);
        if (raw != null &&
            raw.length >= 3 &&
            raw[0] == 0x41 &&
            raw[1] == expectedPid) {
          chartValues[key] = _parsePidValue(param[2], raw.sublist(2));
        }
      }
    }

    final hasData = live.values.any((value) => value != null);
    if (mounted) {
      setState(() {
        _dataWarning = hasData
            ? ""
            : "Машина не отдаёт параметры. Проверьте, что зажигание включено "
                "и двигатель заведён.";
        _live = live;
        // Добавляем значения в историю графиков
        chartValues.forEach((key, value) {
          if (value == null) {
            return;
          }
          final history = _chartData.putIfAbsent(key, () => []);
          history.add(ChartPoint(DateTime.now(), value));
          if (history.length > chartMaxPoints) {
            history.removeAt(0);
          }
        });
      });
    }
  }

  /// Находит описание параметра по ключу: [key, pid, kind, label, unit]
  List<String>? _paramByKey(String key) {
    if (pidCommands.containsKey(key)) {
      final info = pidCommands[key]!;
      return [key, info[0], info[1], tileLabels[key] ?? key, tileUnits[key] ?? ""];
    }
    for (final param in extendedParams) {
      if (param[0] == key) {
        return param;
      }
    }
    return null;
  }

  /// Полный список параметров для выбора графика
  List<List<String>> get _allParams {
    final list = <List<String>>[];
    pidCommands.forEach((key, info) {
      list.add([
        key, info[0], info[1],
        tileLabels[key] ?? key, tileUnits[key] ?? "",
      ]);
    });
    list.addAll(extendedParams);
    return list;
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

    _log("Коды ошибок: ${codes.isEmpty ? "нет" : codes.toSet().join(", ")}");

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
    _log(ok ? "Ошибки стёрты" : "Не удалось стереть ошибки: ${_shorten(answer)}");

    setState(() {
      _status = ok ? "Ошибки стёрты" : "Не удалось стереть ошибки";
      if (ok) _dtcCodes = [];
    });

    if (ok) {
      await _readPids();
    }
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
  //  Облако: вход в аккаунт
  // ----------------------------------------------------------
  Future<void> _showAuthDialog() async {
    final emailController = TextEditingController(text: _api?.email ?? "");
    final passwordController = TextEditingController();
    String dialogStatus = "";
    bool busy = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> submit(bool isRegister) async {
              final email = emailController.text.trim();
              final password = passwordController.text;

              if (email.isEmpty || password.isEmpty) {
                setDialogState(() => dialogStatus = "Введите email и пароль.");
                return;
              }

              setDialogState(() {
                busy = true;
                dialogStatus = isRegister ? "Создаю аккаунт…" : "Вхожу…";
              });

              final client = _api ?? ApiClient();
              final error = isRegister
                  ? await client.register(email, password)
                  : await client.login(email, password);

              if (!dialogContext.mounted) {
                return;
              }

              if (error != null) {
                setDialogState(() {
                  busy = false;
                  dialogStatus = error;
                });
                return;
              }

              setState(() {
                _api = client;
                _cloudStatus = "Вы вошли как ${client.email}";
              });
              Navigator.pop(dialogContext);
            }

            return AlertDialog(
              backgroundColor: const Color(0xFF172029),
              title: const Text("Аккаунт"),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: "Email"),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: "Пароль (от 6 символов)",
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (dialogStatus.isNotEmpty)
                    Text(dialogStatus,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.orangeAccent)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => submit(false),
                  child: const Text("Войти"),
                ),
                TextButton(
                  onPressed: busy ? null : () => submit(true),
                  child: const Text("Зарегистрироваться"),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _logout() async {
    await _api?.logout();
    setState(() {
      _api = null;
      _cloudStatus = "Вход не выполнен — история и ИИ недоступны";
      _adviceText = "";
      _advicePart = "";
      _adviceCost = "";
    });
  }

  // ----------------------------------------------------------
  //  Облако: совет ИИ по текущим данным
  // ----------------------------------------------------------
  Future<void> _askAdvice() async {
    final client = _api;
    if (client == null || !client.isLoggedIn) {
      setState(() => _adviceStatus = "Сначала войдите в аккаунт.");
      return;
    }

    setState(() {
      _cloudBusy = true;
      _adviceStatus = "Думаю…";
      _adviceText = "";
      _advicePart = "";
      _adviceCost = "";
    });

    _log("Запрос ИИ: коды=${_dtcCodes.isEmpty ? "нет" : _dtcCodes.join(",")}");

    try {
      final data = await client.askAdvice(
        codes: _dtcCodes,
        live: _live,
        make: _detectedMake,
        model: _modelController.text.trim(),
        year: _yearController.text.trim(),
      );

      setState(() {
        if (data["error"] != null) {
          _log("Ошибка ИИ: ${data["error"]}");
          _adviceStatus = data["error"].toString();
        } else {
          _adviceText = (data["advice"] ?? "").toString();
          _advicePart = (data["part"] ?? "").toString();
          _adviceCost = (data["cost"] ?? "").toString();
          _adviceStatus = "";
        }
      });
    } catch (error) {
      _log("Нет связи с облаком: $error");
      setState(() => _adviceStatus = "Нет связи с сервером: $error");
    } finally {
      if (mounted) {
        setState(() => _cloudBusy = false);
      }
    }
  }

  // ----------------------------------------------------------
  //  Облако: история диагностик
  // ----------------------------------------------------------
  Future<void> _openHistory() async {
    final client = _api;
    if (client == null || !client.isLoggedIn) {
      setState(() => _cloudStatus = "Сначала войдите в аккаунт.");
      return;
    }

    List<Map<String, dynamic>> items = [];
    String error = "";

    try {
      items = await client.history();
    } catch (exception) {
      error = exception.toString();
    }

    if (!mounted) {
      return;
    }

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: const Text("История диагностик"),
            backgroundColor: const Color(0xFF172029),
          ),
          backgroundColor: const Color(0xFF0E141A),
          body: error.isNotEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text("Не удалось загрузить историю: $error",
                        style: const TextStyle(color: Colors.grey)),
                  ),
                )
              : items.isEmpty
                  ? const Center(
                      child: Text("Записей пока нет",
                          style: TextStyle(color: Colors.grey)),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final item = items[index];
                        final codes = (item["codes"] as List?)?.join(", ") ?? "";
                        return Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF172029),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0xFF26333F)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                (item["created_at"] ?? "").toString(),
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.grey),
                              ),
                              if (codes.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text("Коды: $codes",
                                      style: const TextStyle(
                                          color: Color(0xFFFF9A9C),
                                          fontWeight: FontWeight.bold)),
                                ),
                              const SizedBox(height: 6),
                              Text(
                                (item["advice"] ?? "").toString(),
                                style: const TextStyle(fontSize: 13),
                              ),
                              if ((item["part"] ?? "").toString().isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    "Запчасть: ${item["part"]}",
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF35C28F)),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
        ),
      ),
    );
  }

  // ----------------------------------------------------------
  //  Блоки управления: чтение кодов по CAN-адресам
  // ----------------------------------------------------------
  /// Читает коды из одного блока по адресам запроса и ответа.
  Future<List<String>> _readModuleCodes(String requestId, String responseId) async {
    await _command("ATSH$requestId");
    await _command("ATCRA$responseId");
    await _command("ATCAF1");
    await _command("ATFCSH$requestId");
    await _command("ATFCSD300000");
    await _command("ATFCSM1");

    final codes = <String>[];
    try {
      final answer = await _command("1902FF", timeout: const Duration(seconds: 4));
      codes.addAll(_parseUdsCodes(answer));
      if (codes.isEmpty) {
        final fallback = await _command("03", timeout: const Duration(seconds: 3));
        codes.addAll(_parseMode03Codes(fallback));
      }
    } finally {
      await _command("ATFCSM0");
      await _command("ATCRA");
      await _command("ATSH7DF");
      await _command("ATCAF1");
    }
    return codes.toSet().toList();
  }

  /// Разбирает ответ UDS (сервис 19, подфункция 02).
  List<String> _parseUdsCodes(String answer) {
    final codes = <String>[];
    for (final line in answer.split("\n")) {
      var cleaned = line.replaceAll(">", "").replaceAll(" ", "").replaceAll("\r", "").toUpperCase();
      if (cleaned.isEmpty) continue;

      final marker = cleaned.indexOf("5902");
      if (marker < 0) continue;

      cleaned = cleaned.substring(marker + 4);
      if (cleaned.length < 8) continue;
      cleaned = cleaned.substring(2); // маска статусов

      for (var i = 0; i + 5 < cleaned.length; i += 6) {
        final chunk = cleaned.substring(i, i + 6);
        try {
          final first = int.parse(chunk.substring(0, 2), radix: 16);
          final second = int.parse(chunk.substring(2, 4), radix: 16);
          final code = _decodeDtc(first, second);
          if (code.isNotEmpty) codes.add(code);
        } catch (error) {
          // пропускаем некорректный фрагмент
        }
      }
    }
    return codes;
  }

  /// Разбирает ответ режима 03 (обычные OBD-коды).
  List<String> _parseMode03Codes(String answer) {
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
    return codes;
  }

  /// Перебирает типовые блоки и собирает коды.
  Future<void> _scanModules() async {
    if (!_connected) {
      setState(() => _moduleStatus = "Сначала подключитесь к адаптеру.");
      return;
    }

    setState(() {
      _moduleBusy = true;
      _moduleStatus = "Сканирую блоки…";
      _modules = [];
    });
    _log("Сканирование блоков: ${defaultModules.length} адресов");

    final found = <Map<String, dynamic>>[];
    for (final module in defaultModules) {
      final name = module[0];
      final requestId = module[1];
      final responseId = module[2];

      try {
        final codes = await _readModuleCodes(requestId, responseId);
        _log("Блок $name ($requestId): ${codes.isEmpty ? "нет кодов" : codes.join(", ")}");
        found.add({
          "name": name,
          "request": requestId,
          "response": responseId,
          "codes": codes,
        });
      } catch (error) {
        _log("Блок $name ($requestId): ошибка $error");
      }
    }

    setState(() {
      _modules = found;
      _moduleBusy = false;
      _moduleStatus = found.isEmpty
          ? "Ни один блок не ответил"
          : "Ответили блоков: ${found.length}";
    });
  }

  // ----------------------------------------------------------
  //  Симптомы: голосовой ввод и разбор ИИ
  // ----------------------------------------------------------
  Future<void> _initSpeech() async {
    try {
      final available = await _speech.initialize(
        onStatus: (status) {
          if (mounted && (status == "done" || status == "notListening")) {
            setState(() => _listening = false);
          }
        },
        onError: (error) => _log("Ошибка распознавания: ${error.errorMsg}"),
      );
      if (mounted) {
        setState(() => _speechReady = available);
      }
      _log(available
          ? "Распознавание речи доступно"
          : "Распознавание речи недоступно на устройстве");
    } catch (error) {
      _log("Распознавание речи не запустилось: $error");
    }
  }

  Future<void> _toggleListening() async {
    if (!_speechReady) {
      setState(() => _symptomStatus =
          "Распознавание речи недоступно. Введите жалобу текстом.");
      return;
    }

    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }

    setState(() {
      _listening = true;
      _symptomStatus = "Слушаю…";
    });

    // Если русского распознавания нет, слушаем на языке системы
    final locales = await _speech.locales();
    final hasRussian = locales
        .any((locale) => locale.localeId.toLowerCase().startsWith("ru"));
    String? localeId = "ru_RU";
    if (!hasRussian) {
      final systemLocale = await _speech.systemLocale();
      localeId = systemLocale?.localeId;
      _log("Русское распознавание недоступно, используем язык системы");
      setState(() => _symptomStatus =
          "Русское распознавание не установлено — попробуйте говорить проще "
          "или введите жалобу текстом.");
    }

    await _speech.listen(
      listenOptions: SpeechListenOptions(localeId: localeId),
      onResult: (result) {
        final text = result.recognizedWords;
        setState(() {
          _symptomText = text;
          _symptomStatus = result.finalResult ? "" : "Слушаю…";
        });
        if (result.finalResult) {
          _guessSymptoms(text);
        }
      },
    );
  }

  /// Пробует отметить знакомые жалобы по распознанному тексту.
  void _guessSymptoms(String text) {
    final lower = text.toLowerCase();
    setState(() {
      for (final choice in symptomChoices) {
        final keyword = choice.split(" ").first;
        if (lower.contains(keyword)) {
          _symptoms.add(choice);
        }
      }
    });
  }

  /// Собирает короткий отчёт о диагностике в текст и копирует в буфер.
  Future<void> _copyReport() async {
    final lines = <String>[
      "OBD-Диагност — отчёт",
      "Дата: ${DateTime.now().toString().substring(0, 16)}",
      "Адаптер: $_adapterName",
      if (_protocolName.isNotEmpty) "Протокол: $_protocolName",
      if (_vin.isNotEmpty) "VIN: $_vin",
      if (_detectedMake.isNotEmpty) "Марка: $_detectedMake",
      if (_modelController.text.trim().isNotEmpty)
        "Модель: ${_modelController.text.trim()}",
      if (_yearController.text.trim().isNotEmpty)
        "Год: ${_yearController.text.trim()}",
      "Коды ошибок: ${_dtcCodes.isEmpty ? "нет" : _dtcCodes.join(", ")}",
      "Параметры:",
    ];

    _live.forEach((key, value) {
      final label = tileLabels[key] ?? key;
      final unit = tileUnits[key] ?? "";
      lines.add(
          "  $label: ${value == null ? "нет данных" : value.toStringAsFixed(1)} $unit");
    });

    for (final module in _modules) {
      final codes = (module["codes"] as List).cast<String>();
      lines.add(
          "Блок ${module["name"]}: ${codes.isEmpty ? "ошибок нет" : codes.join(", ")}");
    }

    await Clipboard.setData(ClipboardData(text: lines.join("\n")));
    setState(() =>
        _adviceStatus = "Отчёт скопирован — можно вставить в сообщение.");
    _log("Отчёт скопирован в буфер обмена");
  }

  Future<void> _askSymptoms() async {
    final client = _api;
    if (client == null || !client.isLoggedIn) {
      setState(() => _symptomStatus = "Сначала войдите в аккаунт.");
      return;
    }

    final complaints = <String>[..._symptoms];
    if (_symptomText.trim().isNotEmpty) {
      complaints.add(_symptomText.trim());
    }
    if (complaints.isEmpty) {
      setState(() => _symptomStatus = "Отметьте жалобы или скажите их голосом.");
      return;
    }

    setState(() {
      _symptomBusy = true;
      _symptomStatus = "Анализирую…";
      _symptomResult = "";
      _symptomParts = [];
    });
    _log("Симптомы: ${complaints.join(", ")}");

    try {
      final data = await client.askSymptoms(
        symptoms: complaints,
        make: _detectedMake,
      );

      setState(() {
        if (data["error"] != null) {
          _symptomStatus = data["error"].toString();
        } else {
          _symptomResult = (data["diagnosis"] ?? "").toString();
          final parts = data["parts"];
          _symptomParts = parts is List
              ? parts
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList()
              : [];
          _symptomStatus = "";
        }
      });
    } catch (error) {
      _log("Ошибка ИИ по симптомам: $error");
      setState(() => _symptomStatus = "Нет связи с сервером: $error");
    } finally {
      if (mounted) {
        setState(() => _symptomBusy = false);
      }
    }
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      return;
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      _log("Не удалось открыть ссылку: $url");
    }
  }

  // ----------------------------------------------------------
  //  Журнал работы
  // ----------------------------------------------------------
  /// Добавляет запись в журнал с отметкой времени.
  void _log(String message) {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, "0");
    final stamp =
        "${two(now.hour)}:${two(now.minute)}:${two(now.second)}";
    _logs.add("[$stamp] $message");
    if (_logs.length > _logLimit) {
      _logs.removeAt(0);
    }
  }

  /// Открывает экран журнала: можно прочитать, скопировать или очистить.
  Future<void> _openLogs() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Dialog(
              backgroundColor: const Color(0xFF172029),
              insetPadding: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text("Журнал работы",
                              style: TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.bold)),
                        ),
                        TextButton(
                          onPressed: () async {
                            final messenger = ScaffoldMessenger.of(context);
                            await Clipboard.setData(
                                ClipboardData(text: _logs.join("\n")));
                            messenger.showSnackBar(
                              const SnackBar(
                                  content: Text("Журнал скопирован")),
                            );
                          },
                          child: const Text("Копировать"),
                        ),
                        TextButton(
                          onPressed: () => setDialogState(_logs.clear),
                          child: const Text("Очистить"),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      width: double.infinity,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0E141A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF26333F)),
                        ),
                        child: _logs.isEmpty
                            ? const Text("Журнал пуст",
                                style: TextStyle(
                                    fontSize: 12, color: Colors.grey))
                            : SingleChildScrollView(
                                reverse: true,
                                child: SelectableText(
                                  _logs.join("\n"),
                                  style: const TextStyle(
                                      fontSize: 11,
                                      height: 1.4,
                                      fontFamily: "monospace"),
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text("Закрыть"),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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
            icon: const Icon(Icons.receipt_long),
            tooltip: "Журнал работы",
            onPressed: _openLogs,
          ),
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
            _modulesSection(),
            const SizedBox(height: 16),
            _chartsSection(),
            const SizedBox(height: 16),
            _cloudSection(),
            const SizedBox(height: 16),
            _symptomsSection(),
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
          if (_dataWarning.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_dataWarning,
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 12)),
            ),
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

  /// Панель графиков: пользователь сам выбирает, что отслеживать.
  Widget _chartsSection() {
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
          const Text("Графики",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text("Выберите параметр — график появится и будет обновляться.",
              style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: _chartChoice,
                  dropdownColor: const Color(0xFF1F2A35),
                  items: _allParams
                      .map((param) => DropdownMenuItem(
                            value: param[0],
                            child: Text("${param[3]} (${param[4]})",
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _chartChoice = value);
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton(
                onPressed: _addChart,
                child: const Text("Добавить"),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_chartKeys.isEmpty)
            const Text("Графики не выбраны.",
                style: TextStyle(color: Colors.grey))
          else
            ..._chartKeys.map((key) => _chartCard(key)),
        ],
      ),
    );
  }

  void _addChart() {
    if (_chartKeys.contains(_chartChoice)) {
      return;
    }
    setState(() {
      _chartKeys = [..._chartKeys, _chartChoice];
      _chartData[_chartChoice] = [];
    });
  }

  Widget _chartCard(String key) {
    final param = _paramByKey(key);
    final label = param == null ? key : "${param[3]}, ${param[4]}";
    final values = _chartData[key] ?? [];
    final last = values.isEmpty ? null : values.last.value;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2A35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF26333F)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(label,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ),
              Text(
                last == null ? "—" : "${_format(last)} ${param?[4] ?? ""}",
                style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF35C28F)),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => _openChartDialog(key),
                child: const Icon(Icons.open_in_full, size: 18, color: Colors.grey),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _chartKeys = _chartKeys.where((item) => item != key).toList();
                    _chartData.remove(key);
                  });
                },
                child: const Icon(Icons.close, size: 18, color: Colors.grey),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 170,
            width: double.infinity,
            child: CustomPaint(
              painter: LineChartPainter(values),
            ),
          ),
        ],
      ),
    );
  }

  /// Открывает график на весь экран с управлением масштабом.
  void _openChartDialog(String key) {
    final param = _paramByKey(key);
    final label = param == null ? key : "${param[3]}, ${param[4]}";
    var zoom = chartMaxPoints;

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final all = _chartData[key] ?? [];
            final visibleCount = zoom < all.length ? zoom : all.length;
            final points = all.sublist(all.length - visibleCount);
            final last = points.isEmpty ? null : points.last.value;

            return Dialog(
              backgroundColor: const Color(0xFF172029),
              insetPadding: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(label,
                              style: const TextStyle(
                                  fontSize: 15, fontWeight: FontWeight.bold)),
                        ),
                        Text(
                          last == null ? "—" : "${_format(last)} ${param?[4] ?? ""}",
                          style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF35C28F)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IconButton(
                          onPressed: () => setDialogState(() {
                            zoom = (zoom - 10) < 10 ? 10 : zoom - 10;
                          }),
                          icon: const Icon(Icons.remove),
                          tooltip: "Крупнее",
                        ),
                        IconButton(
                          onPressed: () => setDialogState(() {
                            zoom = (zoom + 10) > chartMaxPoints ? chartMaxPoints : zoom + 10;
                          }),
                          icon: const Icon(Icons.add),
                          tooltip: "Больше точек",
                        ),
                        TextButton(
                          onPressed: () => setDialogState(() => zoom = chartMaxPoints),
                          child: const Text("Вся история"),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text("Закрыть"),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.5,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: LineChartPainter(points),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      "По оси X — время, по оси Y — значение параметра. "
                      "Кнопки − и + меняют масштаб.",
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Панель облака: аккаунт, советы ИИ и история.
  /// Панель блоков управления: коды не только из двигателя.
  Widget _modulesSection() {
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
          const Text("Блоки управления",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text(
            "Читает ошибки из коробки и других блоков. "
            "Адреса блоков зависят от модели и года — часть может не ответить.",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ElevatedButton(
                onPressed: _moduleBusy ? null : _scanModules,
                child: Text(_moduleBusy ? "Сканирую…" : "Сканировать блоки"),
              ),
              if (_moduleStatus.isNotEmpty)
                Center(
                  child: Text(_moduleStatus,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
            ],
          ),
          ..._modules.map((module) {
            final codes = (module["codes"] as List).cast<String>();
            return Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1F2A35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF26333F)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "${module["name"]} (${module["request"]} → ${module["response"]})",
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  if (codes.isEmpty)
                    const Text("Ошибок нет",
                        style: TextStyle(fontSize: 12, color: Colors.grey))
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: codes
                          .map((code) => Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0x29E5484D),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Text(code,
                                    style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFFFF9A9C),
                                        fontWeight: FontWeight.bold)),
                              ))
                          .toList(),
                    ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  /// Панель диагностики по симптомам с голосовым вводом.
  Widget _symptomsSection() {
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
          const Text("Диагностика по симптомам",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          const Text(
            "Отметьте жалобы или скажите голосом — ИИ предположит причины. "
            "Адаптер не нужен.",
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: symptomChoices.map((choice) {
              final selected = _symptoms.contains(choice);
              return FilterChip(
                label: Text(choice, style: const TextStyle(fontSize: 12)),
                selected: selected,
                onSelected: (value) {
                  setState(() {
                    if (value) {
                      _symptoms.add(choice);
                    } else {
                      _symptoms.remove(choice);
                    }
                  });
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: TextEditingController(text: _symptomText)
              ..selection = TextSelection.collapsed(offset: _symptomText.length),
            onChanged: (value) => _symptomText = value,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: "Опишите проблему своими словами",
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              ElevatedButton.icon(
                onPressed: _toggleListening,
                icon: Icon(_listening ? Icons.stop : Icons.mic),
                label: Text(_listening ? "Остановить" : "Сказать"),
              ),
              ElevatedButton(
                onPressed: _symptomBusy ? null : _askSymptoms,
                child: Text(_symptomBusy ? "Анализирую…" : "Определить причину"),
              ),
            ],
          ),
          if (_symptomStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_symptomStatus,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.orangeAccent)),
            ),
          if (_symptomResult.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1F2A35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF26333F)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_symptomResult, style: const TextStyle(fontSize: 13)),
                  ..._symptomParts.map((part) {
                    final links = part["links"];
                    return Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("• ${part["name"]}",
                              style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF35C28F))),
                          if (links is List)
                            Wrap(
                              spacing: 6,
                              children: links.map((link) {
                                final entry = Map<String, dynamic>.from(link as Map);
                                return TextButton(
                                  onPressed: () => _openLink(entry["url"].toString()),
                                  child: Text(
                                    entry["label"].toString(),
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                );
                              }).toList(),
                            ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cloudSection() {
    final client = _api;
    final loggedIn = client != null && client.isLoggedIn;

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
          const Text("Облако и ИИ",
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            _cloudStatus.isEmpty ? "Проверяю вход…" : _cloudStatus,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _modelController,
                  decoration: const InputDecoration(
                    labelText: "Модель (необязательно)",
                    hintText: "X-Trail",
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: _yearController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "Год",
                    hintText: "2013",
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (!loggedIn)
                ElevatedButton(
                  onPressed: _showAuthDialog,
                  child: const Text("Войти / Регистрация"),
                )
              else ...[
                ElevatedButton(
                  onPressed: _cloudBusy ? null : _askAdvice,
                  child: Text(_cloudBusy ? "Думаю…" : "Спросить ИИ"),
                ),
                OutlinedButton(
                  onPressed: _openHistory,
                  child: const Text("История"),
                ),
                OutlinedButton(
                  onPressed: _copyReport,
                  child: const Text("Скопировать отчёт"),
                ),
                TextButton(
                  onPressed: _logout,
                  child: const Text("Выйти"),
                ),
              ],
            ],
          ),
          if (_adviceStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(_adviceStatus,
                  style: const TextStyle(
                      fontSize: 12, color: Colors.orangeAccent)),
            ),
          if (_adviceText.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1F2A35),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF26333F)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_adviceText, style: const TextStyle(fontSize: 13)),
                  if (_advicePart.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text("Вероятная запчасть: $_advicePart",
                          style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF35C28F),
                              fontWeight: FontWeight.w600)),
                    ),
                  if (_adviceCost.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text("Примерная стоимость: $_adviceCost",
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ),
                ],
              ),
            ),
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
          SegmentedButton<String>(
            segments: const [
              ButtonSegment<String>(
                value: "ble",
                label: Text("Bluetooth"),
                icon: Icon(Icons.bluetooth),
              ),
              ButtonSegment<String>(
                value: "wifi",
                label: Text("Wi-Fi"),
                icon: Icon(Icons.wifi),
              ),
            ],
            selected: {_transport},
            onSelectionChanged: (selection) {
              setState(() {
                _transport = selection.first;
                _scanResults = [];
                _status = _transport == "wifi"
                    ? "Подключите телефон к Wi-Fi сети адаптера и нажмите «Подключиться»"
                    : "Нажмите «Найти адаптер»";
              });
            },
          ),
          const SizedBox(height: 10),
          if (_transport == "ble") ...[
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
          ] else ...[
            const Text(
              "Адаптер Wi-Fi создаёт свою сеть (обычно WiFi_OBDII). "
              "Подключите телефон к ней, адрес оставьте как есть.",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _wifiHostController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "IP-адрес адаптера",
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _connectWifi,
              child: const Text("Подключиться по Wi-Fi"),
            ),
          ],
        ],
      ),
    );
  }
}

/// Рисует график с осями координат: время по X, значение по Y.
class LineChartPainter extends CustomPainter {
  LineChartPainter(this.points);

  final List<ChartPoint> points;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xFF172029);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, size.height),
        const Radius.circular(10),
      ),
      background,
    );

    // Отступы под подписи осей
    const padLeft = 56.0;
    const padRight = 12.0;
    const padTop = 10.0;
    const padBottom = 26.0;

    final plotWidth = size.width - padLeft - padRight;
    final plotHeight = size.height - padTop - padBottom;
    if (plotWidth <= 0 || plotHeight <= 0) {
      return;
    }

    final axisPaint = Paint()
      ..color = const Color(0xFF2B3A47)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // Оси
    canvas.drawLine(Offset(padLeft, padTop), Offset(padLeft, padTop + plotHeight), axisPaint);
    canvas.drawLine(
      Offset(padLeft, padTop + plotHeight),
      Offset(padLeft + plotWidth, padTop + plotHeight),
      axisPaint,
    );

    if (points.length < 2) {
      _drawText(canvas, "Ждём данные…", Offset(padLeft + 8, padTop + plotHeight / 2),
          const Color(0xFF92A5B7), 12);
      return;
    }

    final values = points.map((point) => point.value).toList();
    var min = values.reduce((a, b) => a < b ? a : b);
    var max = values.reduce((a, b) => a > b ? a : b);
    if (min == max) {
      min -= 1;
      max += 1;
    }
    final span = max - min;

    final startMs = points.first.time.millisecondsSinceEpoch;
    final endMs = points.last.time.millisecondsSinceEpoch;
    final timeSpan = (endMs - startMs) == 0 ? 1 : (endMs - startMs);

    // Точность подписи по оси Y зависит от разброса
    final digits = span >= 100
        ? 0
        : span >= 10
            ? 1
            : span >= 1
                ? 2
                : span >= 0.1
                    ? 3
                    : 4;

    // Горизонтальная сетка и подписи значений
    const gridLines = 4;
    for (var i = 0; i <= gridLines; i++) {
      final fraction = i / gridLines;
      final y = padTop + plotHeight * fraction;
      final value = max - span * fraction;

      if (i > 0) {
        canvas.drawLine(
          Offset(padLeft, y),
          Offset(padLeft + plotWidth, y),
          Paint()
            ..color = const Color(0xFF1F2A35)
            ..strokeWidth = 1,
        );
      }

      _drawText(
        canvas,
        value.toStringAsFixed(digits),
        Offset(padLeft - 6, y),
        const Color(0xFF92A5B7),
        11,
        alignRight: true,
        centerVertically: true,
      );
    }

    // Вертикальная сетка и подписи времени
    final timeLines = plotWidth < 420 ? 2 : 4;
    for (var i = 0; i <= timeLines; i++) {
      final fraction = i / timeLines;
      final x = padLeft + plotWidth * fraction;
      final timeMs = startMs + (timeSpan * fraction).round();

      if (i > 0 && i < timeLines) {
        canvas.drawLine(
          Offset(x, padTop),
          Offset(x, padTop + plotHeight),
          Paint()
            ..color = const Color(0xFF1F2A35)
            ..strokeWidth = 1,
        );
      }

      final time = DateTime.fromMillisecondsSinceEpoch(timeMs);
      _drawText(
        canvas,
        _formatClock(time),
        Offset(x, padTop + plotHeight + 6),
        const Color(0xFF92A5B7),
        11,
        alignCenter: i > 0 && i < timeLines,
        alignRight: i == timeLines,
      );
    }

    // Линия графика
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final point = points[i];
      final x = padLeft +
          plotWidth * (point.time.millisecondsSinceEpoch - startMs) / timeSpan;
      final y = padTop + plotHeight - plotHeight * (point.value - min) / span;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF35C28F)
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round,
    );

    // Точка на последнем значении
    final lastPoint = points.last;
    final lastX =
        padLeft + plotWidth * (lastPoint.time.millisecondsSinceEpoch - startMs) / timeSpan;
    final lastY = padTop + plotHeight - plotHeight * (lastPoint.value - min) / span;
    canvas.drawCircle(Offset(lastX, lastY), 3.5, Paint()..color = const Color(0xFF35C28F));
  }

  String _formatClock(DateTime time) {
    String two(int value) => value.toString().padLeft(2, "0");
    return "${two(time.hour)}:${two(time.minute)}:${two(time.second)}";
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset position,
    Color color,
    double fontSize, {
    bool alignRight = false,
    bool alignCenter = false,
    bool centerVertically = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    var dx = position.dx;
    if (alignRight) {
      dx -= painter.width;
    } else if (alignCenter) {
      dx -= painter.width / 2;
    }

    final dy = centerVertically ? position.dy - painter.height / 2 : position.dy;
    painter.paint(canvas, Offset(dx, dy));
  }

  @override
  bool shouldRepaint(LineChartPainter oldDelegate) => true;
}
