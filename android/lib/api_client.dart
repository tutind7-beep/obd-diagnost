import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Клиент облачного сервера OBD-Диагност.
///
/// Отвечает за вход в аккаунт, сохранение истории диагностики и запрос
/// советов ИИ. Токен входа хранится на телефоне, чтобы не вводить
/// пароль каждый раз.
class ApiClient {
  ApiClient({this.baseUrl = defaultBaseUrl});

  /// Адрес облачного сервера на Render
  static const String defaultBaseUrl = "https://obd-cloud-n53x.onrender.com";

  final String baseUrl;

  String? _token;
  String? _email;

  String? get email => _email;
  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  // ---------- Сохранение сессии ----------

  static const String _tokenKey = "cloud-token";
  static const String _emailKey = "cloud-email";
  static const String _urlKey = "cloud-url";

  /// Восстанавливает сохранённый вход при запуске приложения.
  static Future<ApiClient> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_urlKey) ?? defaultBaseUrl;
    final client = ApiClient(baseUrl: url);
    client._token = prefs.getString(_tokenKey);
    client._email = prefs.getString(_emailKey);
    return client;
  }

  Future<void> _saveSession() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, _token ?? "");
    await prefs.setString(_emailKey, _email ?? "");
    await prefs.setString(_urlKey, baseUrl);
  }

  /// Выход из аккаунта: забываем токен.
  Future<void> logout() async {
    _token = null;
    _email = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_emailKey);
  }

  // ---------- Служебные запросы ----------

  Map<String, String> _headers() {
    final headers = {"Content-Type": "application/json"};
    if (_token != null && _token!.isNotEmpty) {
      headers["Authorization"] = "Bearer $_token";
    }
    return headers;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final response = await http
        .post(
          Uri.parse("$baseUrl$path"),
          headers: _headers(),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 30));

    return _decode(response);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final response = await http
        .get(Uri.parse("$baseUrl$path"), headers: _headers())
        .timeout(const Duration(seconds: 30));

    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> data;
    try {
      data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    } catch (error) {
      return {"error": "Сервер вернул неожиданный ответ (код ${response.statusCode})."};
    }

    if (response.statusCode >= 400 && data["error"] == null) {
      data["error"] = "Ошибка сервера (код ${response.statusCode}).";
    }
    return data;
  }

  // ---------- Аккаунт ----------

  Future<String?> register(String email, String password) async {
    final data = await _post("/api/register", {"email": email, "password": password});
    if (data["error"] != null) {
      return data["error"].toString();
    }
    _token = data["token"]?.toString();
    _email = email;
    await _saveSession();
    return null;
  }

  Future<String?> login(String email, String password) async {
    final data = await _post("/api/login", {"email": email, "password": password});
    if (data["error"] != null) {
      return data["error"].toString();
    }
    _token = data["token"]?.toString();
    _email = email;
    await _saveSession();
    return null;
  }

  // ---------- Советы ИИ ----------

  /// Отправляет реальные данные с адаптера и получает совет.
  Future<Map<String, dynamic>> askAdvice({
    required List<String> codes,
    required Map<String, double?> live,
    String make = "",
    String model = "",
    String year = "",
  }) async {
    final cleanLive = <String, dynamic>{};
    live.forEach((key, value) {
      if (value != null) {
        cleanLive[key] = value;
      }
    });

    return _post("/api/advice", {
      "codes": codes,
      "live": cleanLive,
      "make": make,
      "model": model,
      "year": year,
    });
  }

  /// Диагностика по симптомам (работает и без адаптера).
  Future<Map<String, dynamic>> askSymptoms({
    required List<String> symptoms,
    String make = "",
    String model = "",
    String year = "",
  }) async {
    return _post("/api/symptoms", {
      "symptoms": symptoms,
      "make": make,
      "model": model,
      "year": year,
    });
  }

  // ---------- История ----------

  Future<List<Map<String, dynamic>>> history() async {
    final data = await _get("/api/history");
    if (data["error"] != null) {
      throw Exception(data["error"].toString());
    }
    final list = data["history"];
    if (list is! List) {
      return [];
    }
    return list.map((item) => Map<String, dynamic>.from(item as Map)).toList();
  }
}
