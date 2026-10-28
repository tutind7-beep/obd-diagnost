"""Каталог параметров OBD-II и разбор ответов ELM327.

Здесь собрано всё, что не зависит от способа подключения адаптера:
  * список параметров (PID) с формулами расчёта;
  * разбор шестнадцатеричных ответов адаптера;
  * декодирование кодов ошибок.

Файл используется и для Bluetooth-адаптеров, и для Wi-Fi.
"""

from __future__ import annotations

HEX_CHARS = set("0123456789ABCDEF")


# ---------------------------------------------------------------------------
#  Формулы расчёта значений
#  Каждая функция получает список байтов данных и возвращает число.
# ---------------------------------------------------------------------------

def _pct_255(b: bytes) -> float | None:
    """Процент от 0 до 100 по формуле A*100/255."""
    if len(b) < 1:
        return None
    return b[0] * 100 / 255


def _temp(b: bytes) -> float | None:
    """Температура: A минус 40 градусов."""
    if len(b) < 1:
        return None
    return b[0] - 40


def _rpm(b: bytes) -> float | None:
    if len(b) < 2:
        return None
    return (b[0] * 256 + b[1]) / 4


def _byte(b: bytes) -> float | None:
    if len(b) < 1:
        return None
    return float(b[0])


def _two_bytes(b: bytes) -> float | None:
    if len(b) < 2:
        return None
    return float(b[0] * 256 + b[1])


def _trim(b: bytes) -> float | None:
    """Топливная коррекция: (A-128)*100/128 процентов."""
    if len(b) < 1:
        return None
    return (b[0] - 128) * 100 / 128


def _voltage(b: bytes) -> float | None:
    if len(b) < 2:
        return None
    return (b[0] * 256 + b[1]) / 1000


def _maf(b: bytes) -> float | None:
    if len(b) < 2:
        return None
    return (b[0] * 256 + b[1]) / 100


def _timing(b: bytes) -> float | None:
    """Угол опережения зажигания: A/2 - 64 градуса."""
    if len(b) < 1:
        return None
    return b[0] / 2 - 64


def _fuel_pressure(b: bytes) -> float | None:
    if len(b) < 1:
        return None
    return b[0] * 3


def _map_kpa(b: bytes) -> float | None:
    if len(b) < 1:
        return None
    return float(b[0])


def _evap(b: bytes) -> float | None:
    """Давление паров топлива: знаковое значение со смещением."""
    if len(b) < 2:
        return None
    raw = b[0] * 256 + b[1]
    if raw > 32767:
        raw -= 65536
    return raw / 4


def _rail_pressure(b: bytes) -> float | None:
    """Давление в топливной рампе, кПа."""
    if len(b) < 2:
        return None
    return (b[0] * 256 + b[1]) * 0.079


def _rail_gauge(b: bytes) -> float | None:
    if len(b) < 2:
        return None
    return (b[0] * 256 + b[1]) * 10


def _o2_voltage(b: bytes) -> float | None:
    if len(b) < 1:
        return None
    return b[0] / 200


def _catalyst_temp(b: bytes) -> float | None:
    if len(b) < 2:
        return None
    return (b[0] * 256 + b[1]) / 10 - 40


def _runtime(b: bytes) -> float | None:
    """Время работы двигателя, секунды."""
    if len(b) < 2:
        return None
    return float(b[0] * 256 + b[1])


def _fuel_rate(b: bytes) -> float | None:
    """Расход топлива, литров в час."""
    if len(b) < 2:
        return None
    return (b[0] * 256 + b[1]) / 20


def _afr(b: bytes) -> float | None:
    """Соотношение воздух/топливо."""
    if len(b) < 2:
        return None
    return (b[0] * 256 + b[1]) / 32768 * 14.7


# ---------------------------------------------------------------------------
#  Каталог параметров
#  ключ -> описание
# ---------------------------------------------------------------------------

PID_CATALOG = {
    # Двигатель
    "rpm": {
        "pid": "010C", "name": "Обороты", "unit": "об/мин",
        "group": "Двигатель", "calc": _rpm, "digits": 0,
    },
    "speed": {
        "pid": "010D", "name": "Скорость", "unit": "км/ч",
        "group": "Двигатель", "calc": _byte, "digits": 0,
    },
    "engine_load": {
        "pid": "0104", "name": "Нагрузка двигателя", "unit": "%",
        "group": "Двигатель", "calc": _pct_255, "digits": 1,
    },
    "throttle": {
        "pid": "0111", "name": "Дроссель", "unit": "%",
        "group": "Двигатель", "calc": _pct_255, "digits": 1,
    },
    "throttle_rel": {
        "pid": "0145", "name": "Дроссель (относит.)", "unit": "%",
        "group": "Двигатель", "calc": _pct_255, "digits": 1,
    },
    "timing": {
        "pid": "010E", "name": "Угол зажигания", "unit": "°",
        "group": "Двигатель", "calc": _timing, "digits": 1,
    },
    "runtime": {
        "pid": "011F", "name": "Время работы", "unit": "с",
        "group": "Двигатель", "calc": _runtime, "digits": 0,
    },

    # Температуры
    "coolant": {
        "pid": "0105", "name": "Температура ОЖ", "unit": "°C",
        "group": "Температуры", "calc": _temp, "digits": 0,
    },
    "intake_temp": {
        "pid": "010F", "name": "Темп. воздуха", "unit": "°C",
        "group": "Температуры", "calc": _temp, "digits": 0,
    },
    "ambient_temp": {
        "pid": "0146", "name": "Темп. снаружи", "unit": "°C",
        "group": "Температуры", "calc": _temp, "digits": 0,
    },
    "catalyst_temp": {
        "pid": "013C", "name": "Темп. катализатора", "unit": "°C",
        "group": "Температуры", "calc": _catalyst_temp, "digits": 0,
    },

    # Топливо
    "fuel_trim_short": {
        "pid": "0106", "name": "Коррекция кратк.", "unit": "%",
        "group": "Топливо", "calc": _trim, "digits": 1,
    },
    "fuel_trim_long": {
        "pid": "0107", "name": "Коррекция долг.", "unit": "%",
        "group": "Топливо", "calc": _trim, "digits": 1,
    },
    "fuel_trim_short_2": {
        "pid": "0108", "name": "Коррекция кратк. 2", "unit": "%",
        "group": "Топливо", "calc": _trim, "digits": 1,
    },
    "fuel_trim_long_2": {
        "pid": "0109", "name": "Коррекция долг. 2", "unit": "%",
        "group": "Топливо", "calc": _trim, "digits": 1,
    },
    "fuel_pressure": {
        "pid": "010A", "name": "Давление топлива", "unit": "кПа",
        "group": "Топливо", "calc": _fuel_pressure, "digits": 0,
    },
    "rail_pressure": {
        "pid": "0122", "name": "Давление в рампе", "unit": "кПа",
        "group": "Топливо", "calc": _rail_pressure, "digits": 1,
    },
    "rail_gauge": {
        "pid": "0123", "name": "Давление в рампе (манометр)", "unit": "кПа",
        "group": "Топливо", "calc": _rail_gauge, "digits": 0,
    },
    "fuel_level": {
        "pid": "012F", "name": "Уровень топлива", "unit": "%",
        "group": "Топливо", "calc": _pct_255, "digits": 1,
    },
    "fuel_rate": {
        "pid": "015E", "name": "Расход топлива", "unit": "л/ч",
        "group": "Топливо", "calc": _fuel_rate, "digits": 2,
    },

    # Воздух
    "maf": {
        "pid": "0110", "name": "Расход воздуха", "unit": "г/с",
        "group": "Воздух", "calc": _maf, "digits": 2,
    },
    "map": {
        "pid": "010B", "name": "Давление во впуске", "unit": "кПа",
        "group": "Воздух", "calc": _map_kpa, "digits": 0,
    },
    "baro": {
        "pid": "0133", "name": "Атмосферное давление", "unit": "кПа",
        "group": "Воздух", "calc": _map_kpa, "digits": 0,
    },
    "afr": {
        "pid": "0144", "name": "Состав смеси", "unit": ":1",
        "group": "Воздух", "calc": _afr, "digits": 1,
    },

    # Электрика
    "voltage": {
        "pid": "0142", "name": "Напряжение", "unit": "В",
        "group": "Электрика", "calc": _voltage, "digits": 2,
    },

    # Датчики кислорода
    "o2_b1s1": {
        "pid": "0114", "name": "Лямбда B1S1", "unit": "В",
        "group": "Датчики кислорода", "calc": _o2_voltage, "digits": 2,
    },
    "o2_b1s2": {
        "pid": "0115", "name": "Лямбда B1S2", "unit": "В",
        "group": "Датчики кислорода", "calc": _o2_voltage, "digits": 2,
    },
    "o2_b1s3": {
        "pid": "0116", "name": "Лямбда B1S3", "unit": "В",
        "group": "Датчики кислорода", "calc": _o2_voltage, "digits": 2,
    },
    "o2_b1s4": {
        "pid": "0117", "name": "Лямбда B1S4", "unit": "В",
        "group": "Датчики кислорода", "calc": _o2_voltage, "digits": 2,
    },

    # Пробег и поездки
    "dist_mil": {
        "pid": "0121", "name": "Пробег с ошибкой", "unit": "км",
        "group": "Пробег", "calc": _two_bytes, "digits": 0,
    },
    "dist_cleared": {
        "pid": "0131", "name": "Пробег после сброса", "unit": "км",
        "group": "Пробег", "calc": _two_bytes, "digits": 0,
    },
    "time_mil": {
        "pid": "014D", "name": "Время с ошибкой", "unit": "мин",
        "group": "Пробег", "calc": _two_bytes, "digits": 0,
    },
}

# Параметры, которые читаются всегда (основные плитки)
CORE_KEYS = [
    "rpm", "coolant", "speed", "voltage",
    "fuel_trim_short", "fuel_trim_long",
    "throttle", "maf", "intake_temp",
]

# Порядок групп для интерфейса
GROUP_ORDER = [
    "Двигатель", "Температуры", "Топливо",
    "Воздух", "Электрика", "Датчики кислорода", "Пробег",
]


# ---------------------------------------------------------------------------
#  Разбор ответов адаптера
# ---------------------------------------------------------------------------

def parse_response_line(line: str) -> bytes | None:
    """Превращает строку ответа ELM327 в байты.

    Ответы бывают с пробелами («41 0C 1A F8») и без («410C1AF8»),
    поэтому пробелы и служебные символы убираем.
    """
    cleaned = "".join(line.split()).replace(">", "").upper()
    if not cleaned or any(ch not in HEX_CHARS for ch in cleaned):
        return None
    if len(cleaned) % 2 != 0:
        cleaned = cleaned[:-1]
    if not cleaned:
        return None
    try:
        return bytes(int(cleaned[i:i + 2], 16) for i in range(0, len(cleaned), 2))
    except ValueError:
        return None


def parse_pid_answer(answer: str, pid: str) -> float | None:
    """Достаёт значение параметра из ответа адаптера.

    answer — полный текст ответа, pid — например «010C».
    """
    info = PID_CATALOG.get(_key_by_pid(pid))
    if info is None:
        return None

    expected = int(pid[-2:], 16)
    for line in answer.splitlines():
        raw = parse_response_line(line)
        # Ответ режима 01: 41 <PID> <данные...>
        if raw and len(raw) >= 3 and raw[0] == 0x41 and raw[1] == expected:
            try:
                return info["calc"](raw[2:])
            except (IndexError, TypeError, ZeroDivisionError):
                return None
    return None


def _key_by_pid(pid: str) -> str:
    """Находит ключ параметра по строке PID."""
    for key, info in PID_CATALOG.items():
        if info["pid"].upper() == pid.upper():
            return key
    return ""


def decode_dtc(first: int, second: int) -> str:
    """Превращает два байта в код ошибки, например P0171."""
    if first == 0 and second == 0:
        return ""
    letters = ["P", "C", "B", "U"]
    letter = letters[(first >> 6) & 0b11]
    d1 = (first >> 4) & 0b11
    d2 = first & 0x0F
    d3 = (second >> 4) & 0x0F
    d4 = second & 0x0F
    return f"{letter}{d1}{d2}{d3}{d4}"


def parse_dtc_answer(answer: str) -> list[str]:
    """Достаёт коды ошибок из ответа на команду 03."""
    codes: list[str] = []
    for line in answer.splitlines():
        raw = parse_response_line(line)
        if raw and raw and raw[0] == 0x43:
            data = raw[1:]
            for i in range(0, len(data) - 1, 2):
                code = decode_dtc(data[i], data[i + 1])
                if code:
                    codes.append(code)
    # Убираем повторы, сохраняя порядок
    unique: list[str] = []
    for code in codes:
        if code not in unique:
            unique.append(code)
    return unique


def format_value(key: str, value: float | None) -> str:
    """Форматирует значение для показа на странице."""
    if value is None:
        return "—"
    digits = PID_CATALOG.get(key, {}).get("digits", 1)
    if digits == 0:
        return str(int(round(value)))
    return f"{value:.{digits}f}"
