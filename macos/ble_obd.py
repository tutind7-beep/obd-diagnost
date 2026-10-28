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

# Протоколы ELM327 в порядке проверки: сначала авто, потом самые частые.
# Код -> (команда, человекочитаемое название)
PROTOCOLS = [
    ("0", "Автоопределение"),
    ("6", "CAN 11-бит, 500 кбод (ISO 15765-4)"),
    ("7", "CAN 29-бит, 500 кбод (ISO 15765-4)"),
    ("8", "CAN 11-бит, 250 кбод (ISO 15765-4)"),
    ("9", "CAN 29-бит, 250 кбод (ISO 15765-4)"),
    ("3", "ISO 9141-2"),
    ("5", "ISO 14230-4 KWP (быстрая инициализация)"),
    ("4", "ISO 14230-4 KWP (5 baud)"),
    ("1", "SAE J1850 PWM"),
    ("2", "SAE J1850 VPW"),
    ("A", "SAE J1939 CAN"),
]

# Марка по первым трём знакам VIN (WMI — код производителя).
# Список покрывает самые распространённые марки; если кода нет — марка не определится.
VIN_MAKES = {
    # Япония
    "JTD": "Toyota", "JTE": "Toyota", "JTF": "Toyota", "JTG": "Toyota",
    "JTH": "Toyota", "JTJ": "Toyota", "JTK": "Toyota", "JTL": "Toyota",
    "JTM": "Toyota", "JTN": "Toyota", "JTP": "Toyota", "JT2": "Toyota",
    "JT3": "Toyota", "JT4": "Toyota", "JT5": "Toyota", "JT6": "Toyota",
    "JT8": "Toyota", "JZX": "Toyota",
    "JN1": "Nissan", "JN3": "Nissan", "JN6": "Nissan", "JN8": "Nissan",
    "JNK": "Infiniti", "JNR": "Infiniti", "VSK": "Nissan", "SJN": "Nissan",
    "JHM": "Honda", "JHL": "Honda", "JHG": "Honda",
    "1HG": "Honda", "2HG": "Honda", "3HG": "Honda", "5FN": "Honda",
    "JM1": "Mazda", "JM3": "Mazda", "JMZ": "Mazda",
    "JF1": "Subaru", "JF2": "Subaru", "4S3": "Subaru", "4S4": "Subaru",
    "JA3": "Mitsubishi", "JA4": "Mitsubishi", "4A3": "Mitsubishi",
    "JS1": "Suzuki", "JS2": "Suzuki", "JS3": "Suzuki", "TSM": "Suzuki",
    "JMB": "Mitsubishi", "JMY": "Mitsubishi",
    "JT1": "Toyota",
    # Корея
    "KMH": "Hyundai", "KM8": "Hyundai", "KMU": "Hyundai", "5NP": "Hyundai",
    "KNA": "Kia", "KND": "Kia", "KNM": "Kia", "U5Y": "Kia",
    "KL4": "Daewoo", "KLA": "Daewoo",
    # Европа
    "WBA": "BMW", "WBS": "BMW", "WBU": "BMW", "WBX": "BMW", "WBY": "BMW",
    "WDB": "Mercedes-Benz", "WDC": "Mercedes-Benz", "WDD": "Mercedes-Benz",
    "WDF": "Mercedes-Benz", "W1K": "Mercedes-Benz", "W1N": "Mercedes-Benz",
    "WAU": "Audi", "WA1": "Audi", "TRU": "Audi", "WUA": "Audi",
    "WVW": "Volkswagen", "WV1": "Volkswagen", "WV2": "Volkswagen",
    "3VW": "Volkswagen", "1VW": "Volkswagen", "WVG": "Volkswagen",
    "TMB": "Skoda", "TMP": "Skoda", "TMT": "Skoda",
    "VF1": "Renault", "VF2": "Renault", "VF3": "Peugeot", "VF7": "Citroen",
    "VFS": "Renault", "VF6": "Renault",
    "YV1": "Volvo", "YV4": "Volvo", "YV2": "Volvo",
    "SAJ": "Jaguar", "SAL": "Land Rover", "SAD": "Land Rover",
    "ZFA": "Fiat", "ZFF": "Ferrari", "ZAR": "Alfa Romeo",
    "VSS": "SEAT", "VWV": "Volkswagen",
    # США
    "1FA": "Ford", "1FB": "Ford", "1FC": "Ford", "1FD": "Ford",
    "2FA": "Ford", "3FA": "Ford", "WF0": "Ford", "MAJ": "Ford",
    "1G1": "Chevrolet", "1GC": "Chevrolet", "2G1": "Chevrolet",
    "1GT": "GMC", "3GT": "GMC",
    "1C3": "Chrysler", "1C4": "Jeep", "1J4": "Jeep", "1J8": "Jeep",
    "1B3": "Dodge", "2B3": "Dodge",
    "5YJ": "Tesla", "7SA": "Tesla",
    # Россия / Китай
    "XTA": "Lada", "XTT": "Lada", "XTU": "Lada", "X9F": "Lada",
    "XW8": "Volkswagen", "X4X": "BMW",
    "LVV": "Chery", "LVT": "Chery",
    "LB3": "Geely", "L6T": "Geely",
    "LGW": "Haval", "LVS": "Changan", "LSV": "Chery",
    "Z8T": "Mitsubishi",
}


def vin_to_make(vin: str) -> str:
    """Определяет марку автомобиля по первым трём знакам VIN."""
    vin = vin.strip().upper()
    if len(vin) < 3:
        return ""
    return VIN_MAKES.get(vin[:3], "")


def _parse_response_line(line: str) -> bytes | None:
    """Превращает строку ответа ELM327 в байты (терпим к пробелам и без них)."""
    # Убираем пробелы, переводы строк и промпт ">" — они мешают разбору
    line = "".join(line.split()).replace(">", "").upper()
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

        # Результаты автоопределения
        self.protocol = ""
        self.protocol_code = ""
        self.vin = ""
        self.make = ""

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
        """Настройка ELM327 и автоподбор протокола связи с ЭБУ.

        Автоопределение (ATSP0) работает не на всех машинах: например,
        Nissan 2013 отвечает только при явно заданном CAN 11-бит (ATSP6).
        Поэтому перебираем протоколы, пока ЭБУ не ответит на запрос 0100.
        """
        self.command("ATE0", 2)
        self.command("ATL0", 2)
        self.command("ATH0", 2)
        time.sleep(0.3)
        self.detect_protocol()

    def detect_protocol(self) -> str:
        """Подбирает протокол, на котором ЭБУ отвечает. Возвращает название."""
        for code, name in PROTOCOLS:
            self.command(f"ATSP{code}", 2)
            time.sleep(0.25)
            # 0100 — запрос поддерживаемых PID; ответ начинается с 41
            answer = self.command("0100", 4)
            if "41" in answer:
                self.protocol = name
                self.protocol_code = code
                return name

        # Ничего не ответило — оставляем автоопределение
        self.command("ATSP0", 2)
        self.protocol = "не определён"
        self.protocol_code = "0"
        return self.protocol

    def read_vin(self) -> str:
        """Читает VIN из ЭБУ (режим 09, PID 02)."""
        answer = self.command("0902", 6)
        chars = []

        for line in answer.splitlines():
            raw = _parse_response_line(line)
            if not raw or len(raw) < 3:
                continue
            # Ответ: 49 02 <номер кадра> <данные...>
            if raw[0] == 0x49 and raw[1] == 0x02:
                for byte in raw[3:]:
                    # Печатаемые ASCII-символы — это символы VIN
                    if 0x20 <= byte <= 0x7E:
                        chars.append(chr(byte))

        vin = "".join(chars).strip()
        # Иногда перед VIN идут нули-заполнители
        vin = vin.lstrip("\x00").strip()
        if len(vin) >= 17:
            vin = vin[-17:] if len(vin) > 17 else vin
        return vin if len(vin) == 17 else ""

    def read_vehicle_info(self) -> dict:
        """Читает VIN из ЭБУ и определяет марку автомобиля."""
        if not self.vin:
            self.vin = self.read_vin()
            self.make = vin_to_make(self.vin)
        return {
            "vin": self.vin,
            "make": self.make,
            "protocol": self.protocol,
        }

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
