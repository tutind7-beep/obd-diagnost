"""Источник данных: BLE-адаптер ELM327 (BROM S10 и похожие)."""

from __future__ import annotations

import threading
import time

from ble_obd import BLEOBD


class BLESource:
    """Читает данные с BLE-адаптера и кэширует их, чтобы не перегружать адаптер.

    Приложение опрашивает данные каждые 2,5 секунды, а полный цикл чтения
    по BLE занимает несколько секунд — поэтому отдаём свежие данные из кэша,
    а обновляем их не чаще раза в 10 секунд.
    """

    name = "ble"

    def __init__(self, target_name: str = "BROM S10", cache_seconds: float = 3.0):
        self._obd = BLEOBD(target_name=target_name)
        self._connected = False
        self._cache_seconds = cache_seconds
        self._cache = (None, None)
        self._last_read = 0.0
        self._codes = None
        self._codes_time = 0.0
        self._lock = threading.Lock()
        self._last_error = ""

    def _ensure_connected(self) -> None:
        if not self._connected or self._obd._peripheral is None:
            if not self._obd.connect(wait=12):
                raise RuntimeError(
                    self._obd._last_error
                    or "BLE-адаптер не найден. Проверьте Bluetooth и зажигание."
                )
            self._obd.initialize()
            self._connected = True
            # Сразу после подключения читаем VIN и определяем марку
            try:
                self._obd.read_vehicle_info()
            except Exception:
                # VIN читается не на всех машинах — это не критично
                pass

    def vehicle_info(self) -> dict:
        """Возвращает определённые марку, VIN и протокол связи."""
        return {
            "vin": self._obd.vin,
            "make": self._obd.make,
            "protocol": self._obd.protocol,
        }

    def read(self) -> tuple[list[str], dict]:
        with self._lock:
            now = time.monotonic()

            # Отдаём кэш, если данные свежие
            if self._cache[0] is not None and now - self._last_read < self._cache_seconds:
                return self._cache

            self._ensure_connected()

            try:
                # Коды ошибок меняются редко — читаем раз в 30 секунд
                if self._codes is None or now - self._codes_time > 30:
                    self._codes = self._obd.read_dtcs()
                    self._codes_time = now

                live = self._obd.read_pids()
            except Exception as error:
                self._connected = False
                self._last_error = str(error)
                raise

            self._cache = (self._codes, live)
            self._last_read = now
            return self._codes, live

    def clear_dtcs(self) -> bool:
        """Стирает коды ошибок из блоков управления (режим 04)."""
        with self._lock:
            self._ensure_connected()
            try:
                return self._obd.clear_dtcs()
            except Exception as error:
                self._connected = False
                self._last_error = str(error)
                raise

    def read_extended(self) -> dict:
        """Читает все параметры каталога (для расширенного экрана)."""
        with self._lock:
            self._ensure_connected()
            try:
                return self._obd.read_pids_extended()
            except Exception as error:
                self._connected = False
                self._last_error = str(error)
                raise

    def read_dtcs_detailed(self) -> dict:
        """Читает коды ошибок по блокам управления (по требованию кнопки)."""
        with self._lock:
            self._ensure_connected()
            try:
                return self._obd.read_dtcs_detailed()
            except Exception as error:
                self._connected = False
                self._last_error = str(error)
                raise

    def close(self) -> None:
        self._obd.close()
