"""Чтение данных с Wi-Fi-адаптера ELM327.

Wi-Fi-адаптеры ELM327 создают свою сеть и принимают команды по TCP.
Стандартные адрес и порт: 192.168.0.10:35000 (у некоторых моделей
192.168.1.5 или 192.168.4.1). Протокол обмена — те же текстовые
команды, что и по Bluetooth, только через сетевое соединение.
"""

from __future__ import annotations

import socket
import time

from obd_pids import (
    CORE_KEYS,
    FREEZE_PIDS,
    PID_CATALOG,
    parse_dtc_answer,
    parse_freeze_pid,
    parse_pid_answer,
    parse_readiness,
    parse_response_line,
    parse_uds_dtcs,
)

# Типичные адреса Wi-Fi-адаптеров
DEFAULT_HOSTS = ["192.168.0.10", "192.168.1.5", "192.168.4.1"]
DEFAULT_PORT = 35000


class WiFiOBD:
    """Подключение к Wi-Fi-адаптеру ELM327 и чтение параметров."""

    name = "wifi"

    def __init__(self, host: str = "", port: int = DEFAULT_PORT, timeout: float = 3.0):
        self.host = host
        self.port = port
        self.timeout = timeout
        self._sock: socket.socket | None = None
        self.protocol = ""
        self.vin = ""
        self.make = ""
        self._last_error = ""

    # ---------- Подключение ----------

    def _candidates(self) -> list[str]:
        """Адреса для попытки подключения."""
        if self.host:
            return [self.host]
        return list(DEFAULT_HOSTS)

    def connect(self) -> bool:
        for host in self._candidates():
            try:
                sock = socket.create_connection((host, self.port), timeout=self.timeout)
                sock.settimeout(self.timeout)
                self._sock = sock
                self.host = host
                # Проверяем связь простой AT-командой
                if self.command("ATI", 2):
                    return True
                self._sock = None
                sock.close()
            except OSError as error:
                self._last_error = (
                    f"Не удалось подключиться к {host}:{self.port}. "
                    "Проверьте, что компьютер подключён к Wi-Fi сети адаптера."
                )
                continue

        self._last_error = self._last_error or "Wi-Fi-адаптер не найден."
        return False

    # ---------- Обмен командами ----------

    def command(self, cmd: str, wait: float = 2.0) -> str:
        """Отправляет команду и возвращает текст ответа."""
        if self._sock is None:
            return ""

        try:
            self._sock.sendall(cmd.encode("ascii") + b"\r")
        except OSError:
            self._sock = None
            return ""

        # Читаем, пока не придёт символ готовности ">"
        chunks = []
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline:
            try:
                data = self._sock.recv(1024)
            except socket.timeout:
                break
            except OSError:
                self._sock = None
                break
            if not data:
                break
            chunks.append(data)
            if b">" in b"".join(chunks):
                break

        return b"".join(chunks).decode("ascii", "replace").strip()

    # ---------- Инициализация и протокол ----------

    def initialize(self) -> None:
        self.command("ATE0")
        self.command("ATL0")
        self.command("ATH0")
        time.sleep(0.2)
        self.detect_protocol()

    def detect_protocol(self) -> str:
        """Перебирает протоколы, пока ЭБУ не ответит на запрос 0100."""
        protocols = [
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

        for code, name in protocols:
            self.command(f"ATSP{code}")
            time.sleep(0.2)
            if "41" in self.command("0100", 3):
                self.protocol = name
                return name

        self.command("ATSP0")
        self.protocol = "не определён"
        return self.protocol

    # ---------- Чтение данных ----------

    def read_pid(self, pid: str) -> float | None:
        return parse_pid_answer(self.command(pid, 1.5), pid)

    def read_pids(self) -> dict:
        return {key: self.read_pid(PID_CATALOG[key]["pid"]) for key in CORE_KEYS}

    def read_pids_extended(self) -> dict:
        return {key: self.read_pid(info["pid"]) for key, info in PID_CATALOG.items()}

    def read_params(self, keys: list[str]) -> dict:
        """Читает только указанные параметры (для графиков)."""
        return {
            key: self.read_pid(PID_CATALOG[key]["pid"])
            for key in keys
            if key in PID_CATALOG
        }

    def read_dtcs(self) -> list[str]:
        return parse_dtc_answer(self.command("03", 3))

    def clear_dtcs(self) -> bool:
        text = "".join(self.command("04", 5).split()).upper()
        return "44" in text or text.startswith("OK")

    def read_vin(self) -> str:
        """Читает VIN из ЭБУ (режим 09, PID 02)."""
        from obd_pids import parse_response_line

        answer = self.command("0902", 5)
        chars: list[int] = []
        for line in answer.splitlines():
            raw = parse_response_line(line)
            if not raw or len(raw) < 3:
                continue
            if raw[0] == 0x49 and raw[1] == 0x02:
                for byte in raw[3:]:
                    if 0x20 <= byte <= 0x7E:
                        chars.append(byte)

        vin = "".join(chr(c) for c in chars).strip()
        if len(vin) > 17:
            vin = vin[-17:]
        return vin if len(vin) == 17 else ""

    def read_vehicle_info(self) -> dict:
        from ble_obd import vin_to_make

        if not self.vin:
            self.vin = self.read_vin()
            self.make = vin_to_make(self.vin)
        return {"vin": self.vin, "make": self.make, "protocol": self.protocol}

    def read_readiness(self) -> dict:
        """Готовность систем к техосмотру (режим 01, PID 01)."""
        answer = self.command("0101", 3)
        for line in answer.splitlines():
            raw = parse_response_line(line)
            if raw and len(raw) >= 5 and raw[0] == 0x41 and raw[1] == 0x01:
                return parse_readiness(raw[2:])
        return {"mil_on": False, "dtc_count": 0, "items": [], "ready": False}

    def read_freeze_frame(self) -> dict:
        """Стоп-кадр: параметры в момент появления ошибки (режим 02)."""
        result = {}
        for pid, (key, label, unit) in FREEZE_PIDS.items():
            answer = self.command(f"02{pid}", 2)
            expected = int(pid, 16)
            for line in answer.splitlines():
                raw = parse_response_line(line)
                if raw and len(raw) >= 4 and raw[0] == 0x42 and raw[1] == expected:
                    value = parse_freeze_pid(raw[2:], pid)
                    if value not in (None, ""):
                        result[key] = {"label": label, "unit": unit, "value": value}
                    break
        return result

    def read_module_dtcs(self, request_id: str, response_id: str,
                         protocol: str = "uds") -> list[str]:
        """Коды ошибок из отдельного блока по CAN-адресу."""
        self.command(f"ATSH{request_id}", 1)
        self.command(f"ATCRA{response_id}", 1)
        self.command("ATCAF1", 1)
        self.command(f"ATFCSH{request_id}", 1)
        self.command("ATFCSD300000", 1)
        self.command("ATFCSM1", 1)

        codes: list[str] = []
        try:
            if protocol == "kwp":
                codes = parse_uds_dtcs(self.command("1802FF00", 4))
                if not codes:
                    codes = parse_dtc_answer(self.command("03", 3))
            else:
                codes = parse_uds_dtcs(self.command("1902FF", 4))
                if not codes:
                    codes = parse_dtc_answer(self.command("03", 3))
        finally:
            self.command("ATFCSM0", 1)
            self.command("ATCRA", 1)
            self.command("ATSH7DF", 1)
            self.command("ATCAF1", 1)

        return codes

    def scan_modules(self, modules: list[dict]) -> list[dict]:
        """Перебирает блоки профиля и возвращает ответившие."""
        results = []
        for module in modules:
            request_id = module.get("request", "")
            response_id = module.get("response", "")
            if not request_id or not response_id:
                continue
            try:
                codes = self.read_module_dtcs(
                    request_id, response_id, module.get("protocol", "uds")
                )
            except Exception:
                continue
            results.append(
                {
                    "name": module.get("name", f"Блок {request_id}"),
                    "request": request_id,
                    "response": response_id,
                    "codes": codes,
                    "answered": True,
                }
            )
        return results

    def read_all(self) -> tuple[list[str], dict]:
        return self.read_dtcs(), self.read_pids()

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None
