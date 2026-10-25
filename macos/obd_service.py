"""Источники данных OBD-II: демо-режим и реальный адаптер."""

from __future__ import annotations

import random
import threading
import time

# Какие параметры читаем с адаптера: имя в отчёте -> команда python-OBD
COMMANDS = [
    ("rpm", "RPM"),
    ("coolant", "COOLANT_TEMP"),
    ("speed", "SPEED"),
    ("voltage", "CONTROL_MODULE_VOLTAGE"),
    ("fuel_trim_short", "SHORT_FUEL_TRIM_1"),
    ("fuel_trim_long", "LONG_FUEL_TRIM_1"),
    ("throttle", "THROTTLE_POS"),
    ("maf", "MAF"),
    ("intake_temp", "INTAKE_TEMP"),
]

# Насколько сильно «дрожат» демо-значения, чтобы графики выглядели живыми
NOISE = {
    "rpm": 25.0,
    "coolant": 0.4,
    "speed": 1.0,
    "voltage": 0.03,
    "fuel_trim_short": 0.4,
    "fuel_trim_long": 0.4,
    "throttle": 0.5,
    "maf": 0.2,
    "intake_temp": 0.3,
}

# Нижние границы, чтобы «дрожание» не давало бессмысленных значений
MINIMUM = {
    "rpm": 0.0,
    "coolant": -40.0,
    "speed": 0.0,
    "voltage": 0.0,
    "throttle": 0.0,
    "maf": 0.0,
}


class DemoSource:
    """Генерирует правдоподобные данные без машины и адаптера."""

    name = "demo"

    SCENARIOS = {
        "lean": {
            "codes": ["P0171"],
            "live": {
                "rpm": 780,
                "coolant": 88,
                "speed": 0,
                "voltage": 14.1,
                "fuel_trim_short": 12.5,
                "fuel_trim_long": 9.0,
                "throttle": 3.5,
                "maf": 3.2,
                "intake_temp": 32,
            },
        },
        "overheat": {
            "codes": [],
            "live": {
                "rpm": 2100,
                "coolant": 108,
                "speed": 60,
                "voltage": 13.9,
                "fuel_trim_short": 2.0,
                "fuel_trim_long": 1.5,
                "throttle": 18.0,
                "maf": 12.5,
                "intake_temp": 35,
            },
        },
        "voltage": {
            "codes": [],
            "live": {
                "rpm": 0,
                "coolant": 25,
                "speed": 0,
                "voltage": 11.5,
                "fuel_trim_short": None,
                "fuel_trim_long": None,
                "throttle": 0.0,
                "maf": 0.0,
                "intake_temp": 22,
            },
        },
        "misfire": {
            "codes": ["P0302"],
            "live": {
                "rpm": 820,
                "coolant": 92,
                "speed": 0,
                "voltage": 14.0,
                "fuel_trim_short": 4.5,
                "fuel_trim_long": 6.0,
                "throttle": 4.0,
                "maf": 3.6,
                "intake_temp": 38,
            },
        },
        "ok": {
            "codes": [],
            "live": {
                "rpm": 750,
                "coolant": 90,
                "speed": 0,
                "voltage": 14.2,
                "fuel_trim_short": 1.5,
                "fuel_trim_long": 0.8,
                "throttle": 3.0,
                "maf": 3.1,
                "intake_temp": 30,
            },
        },
    }

    def __init__(self, scenario: str = "lean"):
        if scenario not in self.SCENARIOS:
            raise ValueError(f"Неизвестный сценарий: {scenario}")
        self.scenario = scenario

    def read(self) -> tuple[list[str], dict]:
        scenario = self.SCENARIOS[self.scenario]
        live = {}

        for key, value in scenario["live"].items():
            if value is None:
                live[key] = None
                continue
            spread = NOISE.get(key, 0.0)
            noisy_value = value + random.uniform(-spread, spread)
            live[key] = round(max(noisy_value, MINIMUM.get(key, noisy_value)), 1)

        return list(scenario["codes"]), live

    def close(self) -> None:
        pass


class RealSource:
    """Читает данные с настоящего адаптера ELM327 через python-OBD."""

    name = "real"

    def __init__(self, portstr: str | None = None):
        self._portstr = portstr
        self._connection = None
        self._lock = threading.Lock()
        self._retry_at = 0.0
        self._last_error = "Адаптер не найден. Проверь Bluetooth и зажигание."

    def _connect(self):
        import obd

        if self._portstr:
            connection = obd.OBD(portstr=self._portstr)
        else:
            connection = obd.OBD()

        if not connection.is_connected():
            ports = ", ".join(obd.utils.scan_serial()) or "порты не найдены"
            raise RuntimeError(
                f"Адаптер не найден. Проверь Bluetooth и зажигание. "
                f"Найденные порты: {ports}"
            )
        return connection

    def read(self) -> tuple[list[str], dict]:
        with self._lock:
            if self._connection is None:
                # Не ищем адаптер на каждый запрос: поиск занимает несколько секунд
                if time.monotonic() < self._retry_at:
                    raise RuntimeError(self._last_error)

                try:
                    self._connection = self._connect()
                except Exception as error:
                    self._last_error = str(error) or "Адаптер не найден."
                    self._retry_at = time.monotonic() + 10.0
                    raise

            import obd

            connection = self._connection
            if not connection.is_connected():
                self._connection = None
                self._last_error = "Связь с адаптером потеряна. Проверь кабель."
                self._retry_at = time.monotonic() + 2.0
                raise RuntimeError(self._last_error)

            try:
                dtc_response = connection.query(obd.commands.GET_DTC)
                codes = [code for code, _ in (dtc_response.value or [])]

                live = {}
                for key, command_name in COMMANDS:
                    command = getattr(obd.commands, command_name)
                    live[key] = _read_value(connection.query(command))
            except Exception:
                # Сбрасываем соединение, чтобы следующий запрос попробовал заново
                self._connection = None
                raise

        return codes, live

    def close(self) -> None:
        with self._lock:
            if self._connection is not None:
                self._connection.close()
                self._connection = None


def _read_value(response):
    """Достаёт число из ответа python-OBD (там бывают объекты с единицами)."""
    if response is None or response.is_null():
        return None
    value = response.value
    return getattr(value, "magnitude", value)
