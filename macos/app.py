"""Веб-приложение для диагностики OBD-II.

Запуск в демо-режиме:   python app.py --demo lean
Запуск с адаптером:     python app.py --real
"""

from __future__ import annotations

import argparse
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from io import BytesIO

from flask import Flask, jsonify, render_template, request, send_file

from diagnostics import build_hints, normalize_codes
from ecu_profiles import list_brands, profile_for
from ble_source import BLESource
from obd_pids import GROUP_ORDER, PID_CATALOG
from obd_service import DemoSource, RealSource
from wifi_obd import WiFiOBD

app = Flask(__name__)

# Источник данных создаётся в main() перед запуском сервера
source = None


def current_source():
    if source is None:
        raise RuntimeError("Источник данных не инициализирован")
    return source


DEEPSEEK_BASE_URL = os.environ.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com")
DEEPSEEK_MODEL = os.environ.get("DEEPSEEK_MODEL", "deepseek-chat")

TELEGRAM_TOKEN_FILE = os.path.expanduser("~/TGBOOT/token.txt")

# Настройки Telegram-уведомлений. chat_id хранится в памяти сервера,
# а браузер присылает его при запуске страницы (или кнопкой «Подключить»).
_telegram_state = {"chat_id": None, "last_sent": 0.0}
_telegram_lock = threading.Lock()

# Русские названия параметров для сводки, которую видит нейросеть
PARAM_LABELS = {
    "rpm": "обороты (об/мин)",
    "coolant": "температура охлаждающей жидкости (°C)",
    "speed": "скорость (км/ч)",
    "voltage": "напряжение (В)",
    "fuel_trim_short": "краткосрочная коррекция топлива (%)",
    "fuel_trim_long": "долгосрочная коррекция топлива (%)",
    "throttle": "положение дросселя (%)",
    "maf": "расход воздуха (г/с)",
    "intake_temp": "температура впускного воздуха (°C)",
}


def _load_api_key() -> str | None:
    """Берёт ключ DeepSeek из переменной окружения или из файла Джарвиса."""
    from_env = os.environ.get("DEEPSEEK_API_KEY")
    if from_env:
        return from_env.strip()

    key_file = os.path.expanduser("~/.jarvis/api_key")
    if os.path.isfile(key_file):
        try:
            with open(key_file, encoding="utf-8") as handle:
                return handle.read().strip() or None
        except OSError:
            return None
    return None


def _ask_deepseek(messages: list[dict]) -> tuple[str | None, str | None]:
    """Отправляет переписку в DeepSeek. Возвращает (ответ, ошибка)."""
    payload = {
        "model": DEEPSEEK_MODEL,
        "messages": messages,
        "temperature": 0.4,
        "stream": False,
    }
    request = urllib.request.Request(
        f"{DEEPSEEK_BASE_URL.rstrip('/')}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {_load_api_key()}",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        return None, f"Ошибка нейросети (HTTP {error.code}). Проверьте ключ DeepSeek."
    except urllib.error.URLError as error:
        return None, f"Нет связи с нейросетью: {error.reason}. Проверьте интернет."
    except TimeoutError:
        return None, "Нейросеть не ответила за 90 секунд. Попробуйте ещё раз."

    try:
        data = json.loads(raw)
        answer = data["choices"][0]["message"]["content"].strip()
    except (json.JSONDecodeError, KeyError, IndexError, TypeError, AttributeError):
        return None, f"Неожиданный ответ нейросети: {raw[:300]}"

    if not answer:
        return None, "Нейросеть вернула пустой ответ."
    return answer, None


def _make_summary(codes: list[str], live: dict, vehicle: dict, symptoms: str) -> str:
    """Собирает короткую текстовую сводку показаний, авто и описания проблемы."""
    parts = []
    for key, label in PARAM_LABELS.items():
        value = live.get(key)
        if value is None:
            continue
        parts.append(f"{label}: {value}")

    if not parts:
        parts.append("живые параметры пока недоступны")

    vehicle_text = ", ".join(
        value for value in (vehicle.get("make"), vehicle.get("model"), vehicle.get("year"))
        if value
    ) or "марка и модель не указаны"

    codes_text = ", ".join(codes) if codes else "ошибок нет"
    summary = (
        f"Автомобиль: {vehicle_text}. "
        "Показания: " + "; ".join(parts) + ". "
        f"Коды ошибок: {codes_text}."
    )
    if symptoms:
        summary += f" Жалоба водителя: {symptoms}."
    return summary


VIN_URL = "https://vpic.nhtsa.dot.gov/api/vehicles/DecodeVin/{vin}?format=json"


def _decode_vin(vin: str) -> dict:
    """Определяет марку, модель и год по VIN через бесплатный сервис NHTSA."""
    vin = vin.strip().upper()
    if len(vin) != 17:
        raise ValueError("VIN должен состоять из 17 символов.")
    if any(ch in "IOQ" for ch in vin):
        raise ValueError("VIN не может содержать буквы I, O, Q.")

    request = urllib.request.Request(VIN_URL.format(vin=vin))
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.URLError as error:
        raise RuntimeError(f"Нет связи с сервисом расшифровки VIN: {error.reason}.")
    except TimeoutError:
        raise RuntimeError("Сервис расшифровки VIN не ответил за 20 секунд.")

    try:
        data = json.loads(raw)
        results = data["Results"]
    except (json.JSONDecodeError, KeyError, TypeError):
        raise RuntimeError("Сервис расшифровки VIN вернул неожиданный ответ.")

    # Ответ NHTSA — список {Variable, Value}. Собираем в удобный словарь.
    fields = {}
    for item in results:
        if isinstance(item, dict):
            name = item.get("Variable")
            if name:
                fields[name] = (item.get("Value") or "").strip()

    make = fields.get("Make", "")
    model = fields.get("Model", "")
    year = fields.get("Model Year", "")

    if not make:
        raise RuntimeError(
            "По этому VIN ничего не найдено. Возможно, машина не продавалась "
            "в Северной Америке — тогда введите марку, модель и год вручную."
        )

    return {"make": make, "model": model, "year": year}


def _build_part_links(part: str, vehicle: dict) -> list[dict]:
    """Собирает ссылки на поиск запчасти в российских магазинах."""
    query_parts = [part] + [
        vehicle.get("make"),
        vehicle.get("model"),
        vehicle.get("year"),
    ]
    query = " ".join(value for value in query_parts if value).strip()
    if not query:
        return []

    encoded = urllib.parse.quote(query)
    return [
        {"label": "Autodoc", "url": f"https://www.autodoc.ru/search?text={encoded}"},
        {"label": "Emex", "url": f"https://emex.ru/products/search?query={encoded}"},
        {"label": "Ozon", "url": f"https://www.ozon.ru/search/?text={encoded}"},
        {"label": "Яндекс.Маркет", "url": f"https://market.yandex.ru/search?text={encoded}"},
        {"label": "Avito", "url": f"https://www.avito.ru/all?q={encoded}"},
        {"label": "Google", "url": f"https://www.google.com/search?q={encoded}"},
    ]


def _parse_advice_answer(answer: str) -> dict:
    """Достаёт совет, запчасть и стоимость из ответа нейросети."""
    text = answer.strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:].strip()

    try:
        data = json.loads(text)
        advice = str(data.get("advice") or "").strip()
        part = str(data.get("part") or "").strip()
        cost = str(data.get("cost") or "").strip()
    except (json.JSONDecodeError, TypeError, AttributeError):
        advice = text
        part = ""
        cost = ""

    if not advice:
        advice = text
    return {"advice": advice or "Пустой ответ нейросети.", "part": part, "cost": cost}


def _parse_symptoms_answer(answer: str) -> dict:
    """Достаёт диагноз и список запчастей из ответа нейросети."""
    text = answer.strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:].strip()

    try:
        data = json.loads(text)
        diagnosis = str(data.get("diagnosis") or "").strip()
        parts = data.get("parts") or []
        if not isinstance(parts, list):
            parts = []
        parts = [str(part).strip() for part in parts if str(part).strip()]
    except (json.JSONDecodeError, TypeError, AttributeError):
        diagnosis = text
        parts = []

    return {"diagnosis": diagnosis or "Пустой ответ нейросети.", "parts": parts}


def _health_score(hints) -> dict:
    """Считает общую оценку состояния автомобиля (0–100)."""
    score = 100
    for hint in hints:
        severity = hint.severity
        if severity == "СТОП":
            score -= 25
        elif severity == "СКОРО В СЕРВИС":
            score -= 15
        else:
            score -= 8

    score = max(0, min(100, score))

    if score >= 90:
        label = "Отлично"
    elif score >= 70:
        label = "Хорошо"
    elif score >= 50:
        label = "Есть замечания"
    else:
        label = "Нужен сервис"

    return {"score": score, "label": label}


SYMPTOM_CHOICES = [
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
]


def _telegram_token() -> str | None:
    """Читает токен бота из файла TGBOOT/token.txt."""
    if os.path.isfile(TELEGRAM_TOKEN_FILE):
        try:
            with open(TELEGRAM_TOKEN_FILE, encoding="utf-8") as handle:
                token = handle.read().strip()
            if token and ":" in token:
                return token
        except OSError:
            return None
    return None


def _send_telegram(text: str, chat_id: str) -> tuple[bool, str]:
    """Отправляет сообщение в Telegram. Возвращает (успех, ошибка)."""
    token = _telegram_token()
    if not token:
        return False, "Токен бота не найден. Проверьте ~/TGBOOT/token.txt"

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = json.dumps({"chat_id": chat_id, "text": text}).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8", "replace")
        return False, f"Telegram вернул ошибку {error.code}: {body[:200]}"
    except urllib.error.URLError as error:
        return False, f"Нет связи с Telegram: {error.reason}."

    if not data.get("ok"):
        return False, f"Telegram не принял сообщение: {data.get('description', '?')}"
    return True, ""


def _notify_telegram(text: str) -> None:
    """Шлёт уведомление, но не чаще одного раза в 5 минут."""
    chat_id = _telegram_state["chat_id"]
    if not chat_id:
        return

    with _telegram_lock:
        if time.monotonic() - _telegram_state["last_sent"] < 300:
            return  # недавно уже отправляли — не спамим
        ok, _ = _send_telegram(text, chat_id)
        if ok:
            _telegram_state["last_sent"] = time.monotonic()


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/api/live")
def api_live():
    active = current_source()

    try:
        codes, live = active.read()
    except Exception as error:
        # Сервер продолжает работать, а интерфейс показывает причину
        return jsonify(
            {
                "source": active.name,
                "connected": False,
                "error": str(error),
                "codes": [],
                "live": {},
                "hints": [],
                "stopped": False,
                "health": {"score": None, "label": "Нет данных"},
                "scenario": getattr(active, "scenario", None),
                "updated_at": datetime.now().strftime("%H:%M:%S"),
            }
        )

    codes = normalize_codes(codes)
    hints = build_hints(codes, live)
    stopped = any(hint.severity == "СТОП" for hint in hints)

    # Данные автомобиля, определённые адаптером (марка, VIN, протокол)
    vehicle_info = {}
    if hasattr(active, "vehicle_info"):
        try:
            vehicle_info = active.vehicle_info()
        except Exception:
            vehicle_info = {}

    if stopped:
        stop_titles = [hint.title for hint in hints if hint.severity == "СТОП"]
        _notify_telegram(
            "🚨 OBD-Диагност: критическая проблема — "
            + "; ".join(stop_titles)
            + ". Остановитесь и проверьте автомобиль."
        )

    return jsonify(
        {
            "source": active.name,
            "connected": True,
            "error": None,
            "codes": codes,
            "live": live,
            "hints": [hint.to_dict() for hint in hints],
            "stopped": stopped,
            "health": _health_score(hints),
            "vehicle_info": vehicle_info,
            "scenario": getattr(active, "scenario", None),
            "updated_at": datetime.now().strftime("%H:%M:%S"),
        }
    )


@app.post("/api/demo/<scenario>")
def api_set_demo(scenario: str):
    active = current_source()

    if not isinstance(active, DemoSource):
        return jsonify({"error": "Сценарии доступны только в демо-режиме"}), 400

    if scenario not in active.SCENARIOS:
        return jsonify({"error": "Неизвестный сценарий"}), 404

    active.scenario = scenario
    return jsonify({"scenario": scenario})


@app.get("/api/dtc/read")
def api_dtc_read():
    """Читает коды ошибок по блокам управления (по нажатию кнопки)."""
    active = current_source()

    if isinstance(active, BLESource):
        try:
            blocks = active.read_dtcs_detailed()
        except Exception as error:
            return jsonify({"error": str(error)}), 503
        return jsonify({"blocks": blocks, "error": None})

    # Для демо/классического адаптера — обычные коды одним блоком
    try:
        codes, _ = active.read()
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    codes = normalize_codes(codes)
    blocks = {"Двигатель (ECM)": codes} if codes else {}
    return jsonify({"blocks": blocks, "error": None})


@app.post("/api/dtc/clear")
def api_dtc_clear():
    """Стирает коды ошибок из блоков управления (режим 04)."""
    active = current_source()

    if isinstance(active, DemoSource):
        return jsonify({"error": "В демо-режиме стирание недоступно."}), 400

    if not hasattr(active, "clear_dtcs"):
        return jsonify({"error": "Источник данных не поддерживает стирание ошибок."}), 400

    try:
        ok = active.clear_dtcs()
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    if not ok:
        return jsonify({"error": "Адаптер не подтвердил стирание. Попробуйте ещё раз."}), 502

    # После стирания кэш кодов устарел — обнуляем
    if hasattr(active, "_codes"):
        active._codes = None

    return jsonify({"ok": True, "error": None})


@app.get("/api/params/catalog")
def api_params_catalog():
    """Список всех параметров, которые умеет читать приложение."""
    groups = {name: [] for name in GROUP_ORDER}
    for key, info in PID_CATALOG.items():
        groups.setdefault(info["group"], []).append(
            {
                "key": key,
                "name": info["name"],
                "unit": info["unit"],
                "digits": info["digits"],
            }
        )
    return jsonify(
        {
            "groups": [
                {"name": name, "params": groups.get(name, [])}
                for name in GROUP_ORDER
                if groups.get(name)
            ]
        }
    )


@app.post("/api/params/values")
def api_params_values():
    """Читает значения только выбранных параметров (для графиков)."""
    data = request.get_json(silent=True) or {}
    keys = [key for key in (data.get("keys") or []) if key in PID_CATALOG]
    if not keys:
        return jsonify({"values": {}, "error": "Выберите хотя бы один параметр."}), 400

    active = current_source()

    if hasattr(active, "read_params"):
        try:
            values = active.read_params(keys)
        except Exception as error:
            return jsonify({"values": {}, "error": str(error)}), 503
        return jsonify({"values": values, "error": None})

    return jsonify(
        {"values": {}, "error": "Источник данных не поддерживает выбор параметров."}
    ), 400


@app.get("/api/params/extended")
def api_params_extended():
    """Читает все параметры каталога (занимает несколько секунд)."""
    active = current_source()

    if not hasattr(active, "read_extended"):
        return jsonify({"values": {}, "error": "Источник данных не поддерживает расширенные параметры."}), 400

    try:
        values = active.read_extended()
    except Exception as error:
        return jsonify({"values": {}, "error": str(error)}), 503

    return jsonify({"values": values, "error": None})


@app.get("/api/adapters")
def api_adapters():
    """Список доступных способов подключения и найденных адаптеров."""
    from ble_obd import list_serial_ports, scan_ble_devices

    ble_devices = []
    try:
        ble_devices = scan_ble_devices(6.0)
    except Exception:
        ble_devices = []

    return jsonify(
        {
            "current": {
                "type": getattr(source, "name", "demo"),
                "detail": getattr(source, "_ble_name", "") or getattr(source, "host", ""),
            },
            "ble": ble_devices,
            "serial": list_serial_ports(),
            "wifi": ["192.168.0.10", "192.168.1.5", "192.168.4.1"],
        }
    )


@app.post("/api/connect")
def api_connect():
    """Переключает приложение на выбранный адаптер."""
    global source

    data = request.get_json(silent=True) or {}
    kind = (data.get("type") or "").strip().lower()
    value = (data.get("value") or "").strip()

    try:
        if kind == "ble":
            if not value:
                return jsonify({"error": "Укажите имя BLE-адаптера."}), 400
            source = BLESource(value)
        elif kind == "wifi":
            host = value or ""
            wifi = WiFiOBD(host)
            if not wifi.connect():
                return jsonify({"error": wifi._last_error or "Wi-Fi-адаптер не найден."}), 503
            wifi.initialize()
            source = wifi
        elif kind == "serial":
            from obd_service import RealSource

            if not value:
                return jsonify({"error": "Укажите последовательный порт."}), 400
            source = RealSource(value)
        elif kind == "demo":
            source = DemoSource(value or "lean")
        else:
            return jsonify({"error": "Неизвестный тип подключения."}), 400
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    return jsonify({"ok": True, "type": source.name, "error": None})


@app.get("/api/ecu/profiles")
def api_ecu_profiles():
    """Список марок, для которых есть профили блоков."""
    return jsonify({"brands": list_brands()})


@app.post("/api/ecu/scan")
def api_ecu_scan():
    """Сканирует блоки управления по профилю марки."""
    data = request.get_json(silent=True) or {}
    make = (data.get("make") or "").strip()

    modules = profile_for(make)
    active = current_source()

    if not hasattr(active, "scan_modules"):
        return jsonify({"error": "Источник данных не поддерживает сканирование блоков."}), 400

    try:
        results = active.scan_modules(modules)
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    return jsonify(
        {
            "make": make or "типовой профиль",
            "modules": results,
            "checked": len(modules),
            "error": None,
        }
    )


@app.get("/api/readiness")
def api_readiness():
    """Готовность систем к техосмотру."""
    active = current_source()
    if not hasattr(active, "read_readiness"):
        return jsonify({"error": "Источник данных не поддерживает готовность систем."}), 400

    try:
        data = active.read_readiness()
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    return jsonify({"readiness": data, "error": None})


@app.get("/api/freeze")
def api_freeze():
    """Стоп-кадр: параметры в момент появления ошибки."""
    active = current_source()
    if not hasattr(active, "read_freeze_frame"):
        return jsonify({"error": "Источник данных не поддерживает стоп-кадр."}), 400

    try:
        data = active.read_freeze_frame()
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    return jsonify({"freeze": data, "error": None})


@app.get("/api/adapter/test")
def api_adapter_test():
    """Проверка качества адаптера: версия, протокол, поддерживаемые PID, скорость."""
    active = current_source()

    result = {
        "source": getattr(active, "name", "demo"),
        "protocol": getattr(active, "protocol", ""),
        "vin": getattr(active, "vin", ""),
        "make": getattr(active, "make", ""),
        "response_ms": None,
        "supported_pids": [],
        "version": "",
    }

    obd_device = getattr(active, "_obd", None)
    if obd_device is None or not hasattr(obd_device, "command"):
        result["note"] = "Демо-режим: адаптер не опрашивается."
        return jsonify({"test": result, "error": None})

    try:
        started = time.monotonic()
        version = obd_device.command("ATI", 3)
        result["response_ms"] = int((time.monotonic() - started) * 1000)
        result["version"] = " ".join(version.split())
        result["protocol"] = getattr(obd_device, "protocol", result["protocol"])

        # Собираем список поддерживаемых PID из ответов 0100/0120/0140
        supported = []
        for base in (0x00, 0x20, 0x40):
            answer = obd_device.command(f"01{base:02X}", 3)
            for line in answer.splitlines():
                cleaned = "".join(line.split()).replace(">", "").upper()
                if len(cleaned) < 12 or not cleaned.startswith("41"):
                    continue
                try:
                    data = bytes.fromhex(cleaned[4:])
                except ValueError:
                    continue
                for index in range(32):
                    byte_index = index // 8
                    if byte_index >= len(data):
                        break
                    if data[byte_index] & (1 << (7 - index % 8)):
                        supported.append(base + index + 1)
        result["supported_pids"] = supported
        result["pid_count"] = len(supported)
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    return jsonify({"test": result, "error": None})


@app.get("/api/report.csv")
def api_report_csv():
    """Отчёт в CSV — удобно открыть в Excel или отправить в сервис."""
    active = current_source()

    try:
        codes, live = active.read()
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    codes = normalize_codes(codes)
    hints = build_hints(codes, live)
    health = _health_score(hints)
    vehicle = getattr(active, "make", "") or ""

    lines = [
        "Раздел;Параметр;Значение;Единица",
        f"Сводка;Марка;{vehicle};",
        f"Сводка;Состояние;{health.get('score')};из 100",
        f"Сводка;Оценка;{health.get('label')};",
        f"Сводка;Время;{datetime.now().strftime('%d.%m.%Y %H:%M')};",
    ]

    for key, label in PARAM_LABELS.items():
        value = live.get(key)
        if value is not None:
            lines.append(f"Параметры;{label};{value};")

    for code in codes:
        lines.append(f"Ошибки;{code};;")

    for hint in hints:
        lines.append(f"Подсказка;{hint.title};;")

    payload = "\n".join(lines).encode("utf-8-sig")
    filename = f"obd_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.csv"

    return send_file(
        BytesIO(payload),
        mimetype="text/csv",
        as_attachment=True,
        download_name=filename,
    )


@app.get("/api/report.pdf")
def api_report_pdf():
    """Отчёт в PDF — печатный документ для автосервиса."""
    from reportlab.lib.pagesizes import A4
    from reportlab.lib.units import mm
    from reportlab.pdfgen import canvas as pdf_canvas

    active = current_source()

    try:
        codes, live = active.read()
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    codes = normalize_codes(codes)
    hints = build_hints(codes, live)
    health = _health_score(hints)

    buffer = BytesIO()
    pdf = pdf_canvas.Canvas(buffer, pagesize=A4)
    page_width, page_height = A4
    left = 20 * mm
    y = page_height - 20 * mm

    def line(text, size=10, gap=6, bold=False):
        nonlocal y
        if y < 25 * mm:
            pdf.showPage()
            y = page_height - 20 * mm
        pdf.setFont("Helvetica-Bold" if bold else "Helvetica", size)
        pdf.drawString(left, y, text)
        y -= gap * mm

    line("OBD-Диагност — отчёт о диагностике", 16, 10, bold=True)
    line(f"Дата: {datetime.now().strftime('%d.%m.%Y %H:%M')}", 10, 8)

    vehicle = getattr(active, "make", "") or "не определено"
    line(f"Автомобиль: {vehicle}", 10, 8)
    vin = getattr(active, "vin", "")
    if vin:
        line(f"VIN: {vin}", 10, 8)
    protocol = getattr(active, "protocol", "")
    if protocol:
        line(f"Протокол связи: {protocol}", 10, 10)

    line(f"Состояние: {health.get('score')}/100 ({health.get('label')})", 11, 10, bold=True)

    line("Коды ошибок:", 11, 7, bold=True)
    if codes:
        for code in codes:
            line(f"  • {code}", 10, 6)
    else:
        line("  Ошибок не найдено", 10, 6)

    y -= 4
    line("Показания датчиков:", 11, 7, bold=True)
    for key, label in PARAM_LABELS.items():
        value = live.get(key)
        if value is not None:
            line(f"  {label}: {value}", 9, 5)

    if hints:
        y -= 4
        line("Что рекомендуем проверить:", 11, 7, bold=True)
        for hint in hints[:8]:
            line(f"  [{hint.severity}] {hint.title}", 9, 5)
            for action in hint.actions[:3]:
                line(f"      - {action}", 8, 4.5)

    y -= 4
    line("Отчёт носит рекомендательный характер и не заменяет осмотр в сервисе.", 8, 5)

    pdf.showPage()
    pdf.save()
    buffer.seek(0)

    filename = f"obd_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.pdf"
    return send_file(
        buffer,
        mimetype="application/pdf",
        as_attachment=True,
        download_name=filename,
    )


@app.get("/api/report")
def api_report():
    active = current_source()

    try:
        codes, live = active.read()
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    codes = normalize_codes(codes)
    hints = build_hints(codes, live)

    report = {
        "created_at": datetime.now().isoformat(timespec="seconds"),
        "source": active.name,
        "codes": codes,
        "live": live,
        "hints": [hint.to_dict() for hint in hints],
        "health": _health_score(hints),
    }

    payload = json.dumps(report, ensure_ascii=False, indent=2).encode("utf-8")
    filename = f"obd_report_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"

    return send_file(
        BytesIO(payload),
        mimetype="application/json",
        as_attachment=True,
        download_name=filename,
    )


@app.post("/api/advice")
def api_advice():
    active = current_source()

    api_key = _load_api_key()
    if not api_key:
        return jsonify({"error": "Ключ DeepSeek не найден. Укажите DEEPSEEK_API_KEY."}), 500

    payload = request.get_json(silent=True) or {}
    vehicle = {
        "make": (payload.get("make") or "").strip(),
        "model": (payload.get("model") or "").strip(),
        "year": str(payload.get("year") or "").strip(),
    }
    symptoms = (payload.get("symptoms") or "").strip()

    try:
        codes, live = active.read()
    except Exception as error:
        return jsonify({"error": str(error)}), 503

    codes = normalize_codes(codes)
    summary = _make_summary(codes, live, vehicle, symptoms)

    messages = [
        {
            "role": "system",
            "content": (
                "Ты — опытный автомеханик. Пользователь передаёт данные "
                "автомобиля, показания OBD-II адаптера, коды ошибок и жалобу "
                "водителя. Ответь строго в формате JSON без пояснений: "
                '{"advice": "рекомендация на русском языке, 3–6 предложений: '
                'что означает ошибка, можно ли ехать, что проверить", '
                '"part": "название запчасти, которая скорее всего вышла из '
                'строя, или пустая строка, если всё в норме", '
                '"cost": "примерная стоимость ремонта в рублях, например '
                '\'3000–7000 ₽\', или пустая строка, если всё в норме"}.'
            ),
        },
        {"role": "user", "content": summary},
    ]

    answer, error = _ask_deepseek(messages)
    if error:
        return jsonify({"error": error}), 502

    result = _parse_advice_answer(answer)
    links = _build_part_links(result["part"], vehicle)

    return jsonify(
        {
            "advice": result["advice"],
            "part": result["part"],
            "cost": result["cost"],
            "links": links,
            "error": None,
            "updated_at": datetime.now().strftime("%H:%M:%S"),
        }
    )


@app.post("/api/symptoms")
def api_symptoms():
    api_key = _load_api_key()
    if not api_key:
        return jsonify({"error": "Ключ DeepSeek не найден. Укажите DEEPSEEK_API_KEY."}), 500

    payload = request.get_json(silent=True) or {}
    selected = [
        symptom for symptom in (payload.get("symptoms") or [])
        if isinstance(symptom, str) and symptom.strip()
    ]
    if not selected:
        return jsonify({"error": "Выберите хотя бы один симптом."}), 400

    vehicle = {
        "make": (payload.get("make") or "").strip(),
        "model": (payload.get("model") or "").strip(),
        "year": str(payload.get("year") or "").strip(),
    }
    vehicle_text = ", ".join(
        value for value in (vehicle.get("make"), vehicle.get("model"), vehicle.get("year"))
        if value
    ) or "марка и модель не указаны"

    summary = f"Автомобиль: {vehicle_text}. Симптомы: {', '.join(selected)}."

    messages = [
        {
            "role": "system",
            "content": (
                "Ты — опытный диагност. По списку симптомов и данным автомобиля "
                "предположи вероятные причины. Ответь строго в формате JSON без "
                "пояснений: "
                '{"diagnosis": "разбор на русском: 3–5 вероятных причин с '
                'пояснением, что проверить в первую очередь", '
                '"parts": ["название запчасти 1", "название запчасти 2"]}.'
            ),
        },
        {"role": "user", "content": summary},
    ]

    answer, error = _ask_deepseek(messages)
    if error:
        return jsonify({"error": error}), 502

    result = _parse_symptoms_answer(answer)
    parts = [
        {"name": part, "links": _build_part_links(part, vehicle)}
        for part in result["parts"]
    ]

    return jsonify(
        {
            "diagnosis": result["diagnosis"],
            "parts": parts,
            "error": None,
            "updated_at": datetime.now().strftime("%H:%M:%S"),
        }
    )


@app.get("/api/vin/<vin>")
def api_vin(vin: str):
    try:
        vehicle = _decode_vin(vin)
    except ValueError as error:
        return jsonify({"vehicle": None, "error": str(error)}), 400
    except RuntimeError as error:
        return jsonify({"vehicle": None, "error": str(error)}), 404

    return jsonify({"vehicle": vehicle, "error": None})


@app.post("/api/telegram")
def api_telegram():
    payload = request.get_json(silent=True) or {}
    chat_id = str(payload.get("chat_id") or "").strip()
    if not chat_id:
        return jsonify({"error": "Введите chat_id."}), 400

    _telegram_state["chat_id"] = chat_id

    # silent=True — просто запомнить chat_id без тестового сообщения
    if payload.get("silent"):
        return jsonify({"ok": True})

    ok, error = _send_telegram(
        "✅ OBD-Диагност подключён. Буду присылать уведомления о критических ошибках.",
        chat_id,
    )
    if not ok:
        return jsonify({"error": error}), 400

    with _telegram_lock:
        _telegram_state["last_sent"] = time.monotonic()
    return jsonify({"ok": True})


@app.get("/api/telegram/lookup")
def api_telegram_lookup():
    token = _telegram_token()
    if not token:
        return jsonify({"error": "Токен бота не найден. Проверьте ~/TGBOOT/token.txt"}), 500

    url = f"https://api.telegram.org/bot{token}/getUpdates"
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.URLError as error:
        return jsonify({"error": f"Нет связи с Telegram: {error.reason}."}), 502

    results = data.get("result", [])
    if not results:
        return jsonify(
            {"error": "Пока нет сообщений. Напишите своему боту /start и повторите."}
        ), 404

    last = results[-1]
    message = last.get("message") or last.get("callback_query", {}).get("message") or {}
    chat_id = message.get("chat", {}).get("id")
    if not chat_id:
        return jsonify({"error": "Не удалось найти chat_id."}), 404

    return jsonify({"chat_id": str(chat_id)})


def main() -> None:
    global source

    parser = argparse.ArgumentParser(description="Веб-диагностика OBD-II")
    parser.add_argument("--real", action="store_true", help="подключиться к реальному адаптеру")
    parser.add_argument(
        "--ble",
        action="store_true",
        help="подключиться к BLE-адаптеру (например, BROM S10)",
    )
    parser.add_argument(
        "--ble-name",
        default="BROM S10",
        help="имя BLE-адаптера (по умолчанию BROM S10)",
    )
    parser.add_argument(
        "--device",
        default=None,
        help="последовательный порт адаптера, например /dev/tty.ELM327-1 (по умолчанию — автопоиск)",
    )
    parser.add_argument(
        "--demo",
        default="lean",
        choices=sorted(DemoSource.SCENARIOS),
        help="демо-сценарий, если адаптера нет",
    )
    parser.add_argument(
        "--wifi",
        nargs="?",
        const="",
        default=None,
        help="подключиться к Wi-Fi-адаптеру (можно указать IP, по умолчанию автопоиск)",
    )
    parser.add_argument("--host", default="127.0.0.1", help="адрес сервера")
    parser.add_argument("--port", type=int, default=8000, help="порт сервера")
    parser.add_argument(
        "--https",
        action="store_true",
        help="включить HTTPS (самоподписанный сертификат) — нужно для установки PWA на телефон",
    )
    args = parser.parse_args()

    if args.ble:
        source = BLESource(args.ble_name)
    elif args.wifi is not None:
        wifi = WiFiOBD(args.wifi)
        if not wifi.connect():
            print(f"Не удалось подключиться по Wi-Fi: {wifi._last_error}")
            print("Запускаю демо-режим.")
            source = DemoSource(args.demo)
        else:
            wifi.initialize()
            print(f"Wi-Fi-адаптер: {wifi.host}:{wifi.port}")
            print(f"Протокол: {wifi.protocol}")
            source = wifi
    elif args.real:
        source = RealSource(args.device)
    else:
        source = DemoSource(args.demo)

    print(f"Режим: {source.name}")
    print(f"Открой в браузере: http://{args.host}:{args.port}")
    if args.host == "127.0.0.1":
        print("Доступ с телефона: запусти с --host 0.0.0.0 и открой адрес компьютера в сети.")

    try:
        app.run(
            host=args.host,
            port=args.port,
            threaded=True,
            debug=False,
            ssl_context="adhoc" if args.https else None,
        )
    except OSError as error:
        if "Address already in use" in str(error) or getattr(error, "errno", None) == 48:
            print()
            print(f"Порт {args.port} уже занят — скорее всего, приложение уже запущено.")
            print(f"Открой в браузере: http://127.0.0.1:{args.port}/")
            print("Если это не оно, закрой старый процесс или запусти с другим портом:")
            print(f"  python app.py --port {args.port + 1}")
        else:
            print(f"Не удалось запустить сервер: {error}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
