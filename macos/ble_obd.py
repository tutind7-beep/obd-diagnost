"""Чтение данных с BLE-адаптера ELM327 (например, BROM S10) на macOS.

Адаптер работает как классический ELM327, но через Bluetooth Low Energy:
  * сервис FFF0
  * команды пишем в характеристику FFF2
  * ответы приходят уведомлениями из FFF1

Модуль сам подключается, инициализирует ELM327 и читает параметры.
"""

from __future__ import annotations

import threading
import time

import CoreBluetooth
import objc
from Foundation import NSData
from libdispatch import dispatch_queue_create

# UUID сервисов/характеристик стандартного BLE-ELM327
SERVICE_FFF0 = "FFF0"
CHAR_RX = "FFF2"  # сюда пишем AT-команды
CHAR_TX = "FFF1"  # отсюда приходят ответы

# PID-команды: ключ -> (команда, способ разбора)
PID_COMMANDS = {
    "rpm": ("010C", "rpm"),
    "coolant": ("0105", "temp"),
    "speed": ("010D", "byte"),
    "voltage": ("0142", "voltage"),
    "fuel_trim_short": ("0106", "trim"),
    "fuel_trim_long": ("0107", "trim"),
    "throttle": ("0111", "throttle"),
    "maf": ("0110", "maf"),
    "intake_temp": ("010F", "temp"),
}


HEX_CHARS = set("0123456789ABCDEF")


def _parse_response_line(line: str) -> bytes | None:
    """Превращает строку ответа ELM327 в байты (терпим к пробелам и без них)."""
    line = line.replace(">", "").strip().upper()
    if not line or any(ch not in HEX_CHARS for ch in line):
        return None
    if len(line) % 2 != 0:
        line = line[:-1]
    try:
        return bytes(int(line[i:i + 2], 16) for i in range(0, len(line), 2))
    except ValueError:
        return None


def _parse_pid(kind: str, payload: bytes) -> float | None:
    """Разбирает байты ответа на PID-запрос в число."""
    if kind == "rpm":
        if len(payload) >= 2:
            return round((payload[0] * 256 + payload[1]) / 4, 1)
    elif kind == "temp":
        if len(payload) >= 1:
            return round(payload[0] - 40, 1)
    elif kind == "byte":
        if len(payload) >= 1:
            return round(payload[0], 1)
    elif kind == "voltage":
        if len(payload) >= 2:
            return round((payload[0] * 256 + payload[1]) / 1000, 2)
    elif kind == "trim":
        if len(payload) >= 1:
            return round((payload[0] - 128) * 100 / 128, 1)
    elif kind == "throttle":
        if len(payload) >= 1:
            return round(payload[0] * 100 / 255, 1)
    elif kind == "maf":
        if len(payload) >= 2:
            return round((payload[0] * 256 + payload[1]) / 100, 2)
    return None


# Названия блоков управления по стандартным CAN-адресам
ECU_NAMES = {
    "7E8": "Двигатель (ECM)",
    "7E9": "Трансмиссия (TCM)",
    "7EA": "Блок 7EA",
    "7EB": "Блок 7EB",
}


class BLEOBD:
    """Подключение к BLE-адаптеру ELM327 и чтение данных."""

    def __init__(self, target_name: str = "BROM S10", timeout: float = 8.0):
        self.target_name = target_name
        self.timeout = timeout

        self._queue = dispatch_queue_create(b"obd.ble", None)
        self._manager = None
        self._peripheral = None
        self._rx = None  # FFF2 — запись команд
        self._tx = None  # FFF1 — ответы

        self._lock = threading.Lock()
        self._reply = bytearray()
        self._reply_event = threading.Event()
        self._connected_event = threading.Event()
        self._ready_event = threading.Event()
        self._last_error = ""

    # ---------- Внутренняя механика ----------

    def _start_manager(self):
        self._manager = CoreBluetooth.CBCentralManager.alloc().initWithDelegate_queue_options_(
            self, self._queue, None
        )

    # Делегат CBCentralManager
    def centralManagerDidUpdateState_(self, manager):
        if manager.state() == 5:  # poweredOn
            manager.scanForPeripheralsWithServices_options_(None, None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(
        self, manager, peripheral, ad_data, rssi
    ):
        if self._peripheral is not None:
            return
        name = peripheral.name() or ""
        if self.target_name.lower() in name.lower():
            self._peripheral = peripheral
            manager.stopScan()
            manager.connectPeripheral_options_(peripheral, None)

    def centralManager_didConnectPeripheral_(self, manager, peripheral):
        peripheral.setDelegate_(self)
        peripheral.discoverServices_(None)

    def centralManager_didFailToConnectPeripheral_error_(self, manager, peripheral, error):
        self._last_error = "Не удалось подключиться к адаптеру."
        self._connected_event.set()

    def centralManager_didDisconnectPeripheral_error_(self, manager, peripheral, error):
        self._peripheral = None

    # Делегат CBPeripheral
    def peripheral_didDiscoverServices_(self, peripheral, error):
        for service in peripheral.services() or []:
            if service.UUID().UUIDString().upper() == SERVICE_FFF0:
                peripheral.discoverCharacteristics_forService_(None, service)

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
        if service.UUID().UUIDString().upper() != SERVICE_FFF0:
            return
        for ch in service.characteristics() or []:
            uid = ch.UUID().UUIDString().upper()
            if uid == CHAR_RX:
                self._rx = ch
            elif uid == CHAR_TX:
                self._tx = ch
                peripheral.setNotifyValue_forCharacteristic_(True, ch)

        if self._rx is not None and self._tx is not None:
            self._ready_event.set()
            self._connected_event.set()

    def peripheral_didUpdateValueForCharacteristic_error_(self, peripheral, ch, error):
        data = ch.value()
        if data is None:
            return
        with self._lock:
            self._reply.extend(bytes(data))
            if self._reply.endswith(b">"):
                self._reply_event.set()

    # ---------- Публичные методы ----------

    def connect(self, wait: float = 20.0) -> bool:
        self._start_manager()
        if not self._connected_event.wait(wait):
            self._last_error = self._last_error or "Адаптер не найден. Проверьте Bluetooth и зажигание."
            return False
        return self._rx is not None and self._tx is not None

    def command(self, cmd: str, wait: float | None = None) -> str:
        """Отправляет AT/PID-команду и возвращает текст ответа."""
        if self._rx is None or self._peripheral is None:
            return ""

        with self._lock:
            self._reply = bytearray()
            self._reply_event.clear()

        payload = NSData.dataWithBytes_length_(cmd.encode("ascii") + b"\r", len(cmd) + 1)
        self._peripheral.writeValue_forCharacteristic_type_(payload, self._rx, 0)

        timeout = wait if wait is not None else self.timeout
        if not self._reply_event.wait(timeout):
            return ""

        with self._lock:
            raw = bytes(self._reply)

        # Оставляем только текстовую часть (до промпта ">")
        text = raw.decode("ascii", "replace")
        text = text.replace("\r", "\n").replace("\xfc", "")
        return text.strip()

    def initialize(self) -> None:
        """Настройка ELM327. Без ATZ (сброс рвёт BLE) и без ATS0 (нужны пробелы).

        Автоопределение протокола работает не на всех машинах (например,
        Nissan 2013 требует CAN 11-бит), поэтому пробуем авто, затем
        принудительно CAN 11-бит (ATSP6) и CAN 29-бит (ATSP7).
        """
        self.command("ATE0", 2)
        self.command("ATL0", 2)
        self.command("ATH0", 2)
        self.command("ATSP0", 2)  # автоматический поиск протокола
        time.sleep(0.4)

        # Проверяем, отвечает ли ЭБУ при автоопределении
        probe = self.command("0100", 4)
        if "41" not in probe:
            self.command("ATSP6", 2)  # CAN 11 бит (ISO 15765-4)
            time.sleep(0.2)
            probe = self.command("0100", 4)
        if "41" not in probe:
            self.command("ATSP7", 2)  # CAN 29 бит
            time.sleep(0.2)

    def read_pid(self, pid: str, kind: str) -> float | None:
        answer = self.command(pid, 1.2)
        expected_pid = int(pid[-2:], 16)
        for line in answer.splitlines():
            raw = _parse_response_line(line)
            if raw and len(raw) >= 3 and raw[0] == 0x41 and raw[1] == expected_pid:
                return _parse_pid(kind, raw[2:])
        return None

    def read_pids(self) -> dict:
        """Читает только параметры (без кодов ошибок) — быстрый цикл."""
        live = {}
        for key, (pid, kind) in PID_COMMANDS.items():
            live[key] = self.read_pid(pid, kind)
        return live

    def read_dtcs(self) -> list[str]:
        answer = self.command("03", 2)
        codes = []
        for line in answer.splitlines():
            raw = _parse_response_line(line)
            if raw and raw[0] == 0x43:
                data = raw[1:]
                for i in range(0, len(data) - 1, 2):
                    code = self._decode_dtc(data[i], data[i + 1])
                    if code:
                        codes.append(code)
        return codes

    def read_dtcs_detailed(self) -> dict:
        """Читает коды ошибок, группируя их по блокам управления (ECU).

        Включаем заголовки (ATH1), чтобы видеть, какой блок прислал ответ.
        Возвращает словарь: название блока -> список кодов.
        """
        self.command("ATH1", 1)
        answer = self.command("03", 3)
        self.command("ATH0", 1)

        blocks: dict[str, list[str]] = {}

        for line in answer.splitlines():
            line = line.replace(">", "").strip()
            if not line:
                continue

            tokens = line.split()
            if not tokens:
                continue

            # Ищем маркер ответа "43" (режим 03 + 0x40)
            marker = None
            for index, token in enumerate(tokens):
                if token.upper() == "43":
                    marker = index
                    break
            if marker is None:
                continue

            # Заголовок ECU — это всё, что до маркера "43"
            if marker > 0:
                ecu_key = " ".join(tokens[:marker])
            else:
                ecu_key = "ECM"

            raw = bytes(int(t, 16) for t in tokens[marker + 1:])
            codes = []
            for i in range(0, len(raw) - 1, 2):
                code = self._decode_dtc(raw[i], raw[i + 1])
                if code:
                    codes.append(code)

            block_name = ECU_NAMES.get(ecu_key.upper(), f"Блок {ecu_key}")
            blocks.setdefault(block_name, [])
            for code in codes:
                if code not in blocks[block_name]:
                    blocks[block_name].append(code)

        return blocks

    @staticmethod
    def _decode_dtc(first: int, second: int) -> str:
        if first == 0 and second == 0:
            return ""
        letters = ["P", "C", "B", "U"]
        letter = letters[(first >> 6) & 0b11]
        d1 = str((first >> 4) & 0b11)
        d2 = str(first & 0x0F)
        d3 = str((second >> 4) & 0x0F)
        d4 = str(second & 0x0F)
        return letter + d1 + d2 + d3 + d4

    def read_all(self) -> tuple[list[str], dict]:
        codes = self.read_dtcs()
        live = {}
        for key, (pid, kind) in PID_COMMANDS.items():
            live[key] = self.read_pid(pid, kind)
        return codes, live

    def close(self):
        if self._peripheral is not None and self._manager is not None:
            self._manager.cancelPeripheralConnection_(self._peripheral)
        self._peripheral = None
