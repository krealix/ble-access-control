"""Gateway-логика для ble_app.py.

Эквивалент вкладки «Шлюз» в Flutter-приложении, только на Windows.

- BLE-сканирование (через bleak в воркер-потоке)
- Парсит iBeacon (Apple Manufacturer ID 0x004C)
- Фильтрует по UUID + whitelist (имя + Major + опц. Minor + опц. MAC)
- Решение о доступе одним из двух методов (decision_mode):
    * "trajectory" — анализ траектории RSSI (Калман+дистанция+тренд+FSM), ядро ВКР;
    * "threshold"  — простой порог RSSI + N замеров (базовый метод для сравнения).
- При разрешении доступа — POST на HA webhook
- Cooldown per-vehicle чтобы не дёргать ворота повторно
"""
from __future__ import annotations

import asyncio
import json
import re
import threading
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from queue import Queue
from typing import Callable, Optional

import customtkinter as ctk
import requests

from bleak import BleakScanner

# Переиспользуем палитру и парсер из ble_app/scanner.
from ble_scanner import BeaconKind, parse as parse_beacon
# Научное ядро ВКР: анализ траектории изменения RSSI.
from trajectory import Access, TrajectoryAnalyzer, TX_POWER_1M, PATH_LOSS_N

BG = "#0B1426"
SURFACE = "#142136"
SURFACE_HI = "#1B2A44"
PRIMARY = "#2D8CFF"
PRIMARY_HOVER = "#1565DD"
DANGER = "#E74C5C"
DANGER_HOVER = "#C73947"
SUCCESS = "#22C55E"
WARNING = "#FFB74D"
ON_SURFACE = "#E7ECF4"
MUTED = "#8FA0BA"
DIVIDER = "#243450"

CONFIG_PATH = Path(__file__).parent / "gateway_config.json"


# --------------------------------------------------------------------------- #
# Data
# --------------------------------------------------------------------------- #


_MAC_RE = re.compile(r"^([0-9A-F]{2}:){5}[0-9A-F]{2}$")


def normalize_mac(s: Optional[str]) -> Optional[str]:
    """Приводит MAC к виду 'AA:BB:CC:DD:EE:FF'. Возвращает None, если строка пустая
    или формат некорректен."""
    if not s:
        return None
    cleaned = s.strip().upper().replace("-", ":").replace(" ", "")
    if not _MAC_RE.fullmatch(cleaned):
        return None
    return cleaned


@dataclass
class AuthorizedVehicle:
    name: str
    major: Optional[int] = None
    minor: Optional[int] = None
    mac: Optional[str] = None

    def matches(self, major: int, minor: int, mac: str) -> bool:
        # Должен быть задан хотя бы один идентифицирующий признак,
        # иначе матчер сработает на любую метку и потеряет смысл.
        if self.major is None and self.minor is None and self.mac is None:
            return False
        if self.major is not None and self.major != major:
            return False
        if self.minor is not None and self.minor != minor:
            return False
        if self.mac is not None and self.mac.upper() != (mac or "").upper():
            return False
        return True


@dataclass
class GatewayConfig:
    ha_url: str = "http://localhost:8123"
    webhook_id: str = "gate_open"
    beacon_uuid: str = ""
    rssi_threshold: int = -65
    cooldown_seconds: int = 10
    samples_required: int = 2
    whitelist: list[AuthorizedVehicle] = field(default_factory=list)

    # --- Режим принятия решения о доступе ---
    # "trajectory" — по анализу траектории (Калман+дистанция+тренд+FSM), ядро ВКР;
    # "threshold"  — по простому порогу RSSI + N замеров (для сравнения в главе 2.3).
    decision_mode: str = "trajectory"

    # Параметры анализатора траектории (используются при decision_mode="trajectory")
    grant_distance: float = 2.0   # радиус зоны доступа, м
    approach_samples: int = 4     # сколько подряд «приближается» нужно для доступа
    trend_window: int = 5         # окно (замеров) для оценки тренда
    trend_eps: float = 0.2        # порог наклона RSSI, dBm/с
    tx_power_1m: float = TX_POWER_1M   # калиброванный RSSI на 1 м
    path_loss_n: float = PATH_LOSS_N   # показатель затухания среды

    @property
    def webhook_url(self) -> str:
        base = self.ha_url.rstrip("/")
        return f"{base}/api/webhook/{self.webhook_id}"

    def to_json(self) -> dict:
        d = asdict(self)
        return d

    @classmethod
    def from_json(cls, data: dict) -> "GatewayConfig":
        whitelist = [
            AuthorizedVehicle(**v) for v in data.get("whitelist", [])
        ]
        return cls(
            ha_url=data.get("ha_url", "http://localhost:8123"),
            webhook_id=data.get("webhook_id", "gate_open"),
            beacon_uuid=data.get("beacon_uuid", ""),
            rssi_threshold=int(data.get("rssi_threshold", -65)),
            cooldown_seconds=int(data.get("cooldown_seconds", 10)),
            samples_required=int(data.get("samples_required", 2)),
            whitelist=whitelist,
            decision_mode=data.get("decision_mode", "trajectory"),
            grant_distance=float(data.get("grant_distance", 2.0)),
            approach_samples=int(data.get("approach_samples", 4)),
            trend_window=int(data.get("trend_window", 5)),
            trend_eps=float(data.get("trend_eps", 0.2)),
            tx_power_1m=float(data.get("tx_power_1m", TX_POWER_1M)),
            path_loss_n=float(data.get("path_loss_n", PATH_LOSS_N)),
        )


def load_config() -> GatewayConfig:
    if not CONFIG_PATH.exists():
        return GatewayConfig()
    try:
        with CONFIG_PATH.open("r", encoding="utf-8") as f:
            return GatewayConfig.from_json(json.load(f))
    except Exception:
        return GatewayConfig()


def save_config(cfg: GatewayConfig) -> None:
    with CONFIG_PATH.open("w", encoding="utf-8") as f:
        json.dump(cfg.to_json(), f, indent=2, ensure_ascii=False)


# --------------------------------------------------------------------------- #
# Monitor (worker thread + bleak)
# --------------------------------------------------------------------------- #


@dataclass
class GatewayEvent:
    ts: datetime
    level: str  # info / success / warning / error
    text: str


class GatewayMonitor:
    """Воркер-поток: bleak-скан, матчинг, HTTP POST."""

    def __init__(self, config: GatewayConfig, event_queue: Queue[GatewayEvent]):
        self.config = config
        self._events = event_queue
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._scanner: Optional[BleakScanner] = None
        self._thread: Optional[threading.Thread] = None
        self._stop = threading.Event()
        self._hits: dict[str, list[float]] = {}
        self._cooldown: dict[str, float] = {}
        # Анализаторы траектории per-vehicle (для decision_mode="trajectory")
        self._analyzers: dict[str, TrajectoryAnalyzer] = {}
        # Последнее объявленное состояние траектории — чтобы не спамить журнал
        self._last_state: dict[str, Access] = {}

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self) -> None:
        if self.running:
            return
        self._stop.clear()
        self._hits.clear()
        self._cooldown.clear()
        self._analyzers.clear()
        self._last_state.clear()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=3)

    def update_config(self, cfg: GatewayConfig) -> None:
        self.config = cfg
        self._hits.clear()
        self._analyzers.clear()
        self._last_state.clear()

    def _emit(self, level: str, text: str) -> None:
        self._events.put(GatewayEvent(datetime.now(), level, text))

    def _run(self) -> None:
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._main())
        except Exception as e:
            self._emit("error", f"Worker crashed: {e}")
        finally:
            self._loop.close()

    async def _main(self) -> None:
        try:
            self._scanner = BleakScanner(detection_callback=self._on_adv)
            await self._scanner.start()
        except Exception as e:
            msg = str(e).lower()
            if "powered" in msg or "not available" in msg:
                self._emit("error", "Bluetooth выключен")
            else:
                self._emit("error", f"Не удалось стартовать сканер: {e}")
            return

        self._emit("info", "Мониторинг запущен")
        try:
            while not self._stop.is_set():
                await asyncio.sleep(0.25)
        finally:
            try:
                await self._scanner.stop()
            except Exception:
                pass
            self._emit("info", "Мониторинг остановлен")

    def _on_adv(self, device, adv) -> None:
        apple = adv.manufacturer_data.get(0x004C)
        if not apple or len(apple) < 23:
            return
        if apple[0] != 0x02 or apple[1] != 0x15:
            return

        uuid_bytes = bytes(apple[2:18])
        uuid_hex = uuid_bytes.hex().upper()
        uuid_formatted = (
            f"{uuid_hex[0:8]}-{uuid_hex[8:12]}-{uuid_hex[12:16]}-"
            f"{uuid_hex[16:20]}-{uuid_hex[20:32]}"
        )
        wanted = self.config.beacon_uuid.strip().upper().replace(" ", "")
        if not wanted:
            return
        # Сравниваем без учёта дефисов (на случай если ввели слитно)
        if uuid_formatted.replace("-", "") != wanted.replace("-", ""):
            return

        major = (apple[18] << 8) | apple[19]
        minor = (apple[20] << 8) | apple[21]
        rssi = adv.rssi if adv.rssi is not None else (
            device.rssi if hasattr(device, "rssi") else -100
        )

        mac = (device.address or "").upper()
        vehicle = self._find_vehicle(major, minor, mac)
        if vehicle is None:
            return

        key = (
            f"{vehicle.name}|"
            f"{vehicle.major if vehicle.major is not None else '*'}|"
            f"{vehicle.minor if vehicle.minor is not None else '*'}|"
            f"{vehicle.mac or '*'}"
        )
        now = time.time()

        # Cooldown — общий для обоих режимов
        last = self._cooldown.get(key)
        if last and (now - last) < self.config.cooldown_seconds:
            return

        # Решение о доступе: траектория (ядро ВКР) или простой порог.
        if self.config.decision_mode == "trajectory":
            self._decide_trajectory(vehicle, key, now, major, minor, rssi)
        else:
            self._decide_threshold(vehicle, key, now, major, minor, rssi)

    def _decide_threshold(
        self, vehicle, key: str, now: float, major: int, minor: int, rssi: int
    ) -> None:
        """Базовый подход для сравнения: порог RSSI + N замеров в окне 5 с."""
        if rssi < self.config.rssi_threshold:
            return
        window = self._hits.setdefault(key, [])
        window[:] = [t for t in window if (now - t) <= 5.0]
        window.append(now)
        if len(window) >= self.config.samples_required:
            self._cooldown[key] = now
            window.clear()
            self._fire(vehicle, major, minor, rssi)
        else:
            self._emit(
                "info",
                f"Кандидат: {vehicle.name} "
                f"({len(window)}/{self.config.samples_required}, RSSI={rssi})",
            )

    def _decide_trajectory(
        self, vehicle, key: str, now: float, major: int, minor: int, rssi: int
    ) -> None:
        """Ядро ВКР: решение по траектории (Калман + дистанция + тренд + FSM).

        Порог RSSI здесь НЕ применяется как фильтр — анализатору нужен полный
        поток (включая слабые/далёкие замеры) для корректной оценки тренда.
        """
        analyzer = self._analyzers.get(key)
        if analyzer is None:
            analyzer = TrajectoryAnalyzer(
                grant_distance=self.config.grant_distance,
                approach_samples=self.config.approach_samples,
                window=self.config.trend_window,
                trend_eps=self.config.trend_eps,
                tx_power=self.config.tx_power_1m,
                n=self.config.path_loss_n,
            )
            self._analyzers[key] = analyzer

        sample = analyzer.push(now, float(rssi))

        # Журналируем только смену состояния — чтобы не спамить.
        if self._last_state.get(key) != sample.state:
            self._last_state[key] = sample.state
            self._emit(
                "info",
                f"{vehicle.name}: {sample.state.value} "
                f"(d≈{sample.distance:.1f} м, тренд={sample.trend:+.2f} dBm/с)",
            )

        if sample.state == Access.GRANTED:
            self._cooldown[key] = now
            # Сброс анализатора: после cooldown снова потребуется устойчивый подход.
            self._analyzers.pop(key, None)
            self._last_state.pop(key, None)
            self._fire(vehicle, major, minor, rssi)

    def _find_vehicle(
        self, major: int, minor: int, mac: str
    ) -> Optional[AuthorizedVehicle]:
        for v in self.config.whitelist:
            if v.matches(major, minor, mac):
                return v
        return None

    def _fire(self, vehicle, major: int, minor: int, rssi: int) -> None:
        self._emit(
            "success",
            f"Открытие: {vehicle.name} (Major={major} Minor={minor} RSSI={rssi})",
        )
        # HTTP запрос в отдельном потоке чтобы не блокировать asyncio loop
        threading.Thread(
            target=self._post_webhook,
            args=(vehicle.name, major, minor, rssi),
            daemon=True,
        ).start()

    def _post_webhook(self, vehicle: str, major: int, minor: int, rssi: int) -> None:
        try:
            response = requests.post(
                self.config.webhook_url,
                json={
                    "vehicle": vehicle,
                    "major": major,
                    "minor": minor,
                    "rssi": rssi,
                    "timestamp": datetime.now().isoformat(),
                },
                timeout=5,
            )
            if 200 <= response.status_code < 300:
                self._emit("success", f"HA: {response.status_code} OK")
            else:
                self._emit("error", f"HA: {response.status_code}")
        except requests.exceptions.Timeout:
            self._emit("error", "HA: таймаут (5 сек)")
        except requests.exceptions.ConnectionError as e:
            self._emit("error", f"HA: connection error — {str(e)[:60]}")
        except Exception as e:
            self._emit("error", f"HA: {e}")


# --------------------------------------------------------------------------- #
# UI panel
# --------------------------------------------------------------------------- #


class GatewayPanel(ctk.CTkFrame):
    def __init__(self, master):
        super().__init__(master, fg_color="transparent")
        self._config = load_config()
        self._events: Queue[GatewayEvent] = Queue()
        self._monitor = GatewayMonitor(self._config, self._events)
        self._log: list[GatewayEvent] = []
        self._running = False

        self._build_ui()
        self._poll_events()

    # ---- UI ----

    def _build_ui(self) -> None:
        # Status row
        status_row = ctk.CTkFrame(self, fg_color="transparent")
        status_row.pack(fill="x", padx=4, pady=(8, 12))
        self._status_dot = ctk.CTkFrame(
            status_row, width=12, height=12, corner_radius=6, fg_color=MUTED
        )
        self._status_dot.pack(side="left", padx=(0, 10))
        self._status_dot.pack_propagate(False)
        self._status_label = ctk.CTkLabel(
            status_row,
            text="Шлюз остановлен",
            text_color=ON_SURFACE,
            font=ctk.CTkFont(size=15, weight="bold"),
        )
        self._status_label.pack(side="left")

        # Scrollable content
        scroll = ctk.CTkScrollableFrame(self, fg_color=BG)
        scroll.pack(fill="both", expand=True, padx=0, pady=(0, 12))

        # Settings card
        settings = ctk.CTkFrame(scroll, fg_color=SURFACE, corner_radius=14)
        settings.pack(fill="x", padx=8, pady=6)
        self._build_settings(settings)

        # Whitelist card
        whitelist = ctk.CTkFrame(scroll, fg_color=SURFACE, corner_radius=14)
        whitelist.pack(fill="x", padx=8, pady=6)
        self._whitelist_frame = whitelist
        self._build_whitelist(whitelist)

        # Log card
        log = ctk.CTkFrame(scroll, fg_color=SURFACE, corner_radius=14)
        log.pack(fill="both", expand=True, padx=8, pady=6)
        self._build_log(log)

        # Action button
        self._action_btn = ctk.CTkButton(
            self,
            text="▶  Запустить мониторинг",
            height=50,
            corner_radius=12,
            fg_color=PRIMARY,
            hover_color=PRIMARY_HOVER,
            text_color="white",
            font=ctk.CTkFont(size=15, weight="bold"),
            command=self._toggle,
        )
        self._action_btn.pack(fill="x", padx=4, pady=(0, 4))

    def _build_settings(self, parent) -> None:
        ctk.CTkLabel(
            parent,
            text="НАСТРОЙКИ",
            text_color=MUTED,
            font=ctk.CTkFont(size=12, weight="bold"),
            anchor="w",
        ).pack(fill="x", padx=14, pady=(12, 4))

        # --- Режим принятия решения о доступе ---
        ctk.CTkLabel(
            parent, text="РЕЖИМ РЕШЕНИЯ", text_color=MUTED,
            font=ctk.CTkFont(size=10, weight="bold"), anchor="w",
        ).pack(fill="x", padx=14, pady=(4, 2))
        self._decision_mode = self._config.decision_mode
        mode_row = ctk.CTkFrame(parent, fg_color=BG, corner_radius=10)
        mode_row.pack(fill="x", padx=14, pady=(0, 2))
        self._mode_btns: dict[str, ctk.CTkButton] = {}
        for i, (val, label) in enumerate([
            ("trajectory", "Траектория"),
            ("threshold", "Порог RSSI"),
        ]):
            b = ctk.CTkButton(
                mode_row, text=label, height=32, corner_radius=8,
                font=ctk.CTkFont(size=12, weight="bold"),
                fg_color="transparent", hover_color=SURFACE_HI, text_color=MUTED,
                command=lambda v=val: self._set_decision_mode(v),
            )
            b.grid(row=0, column=i, sticky="ew", padx=2, pady=2)
            mode_row.grid_columnconfigure(i, weight=1)
            self._mode_btns[val] = b
        self._mode_hint = ctk.CTkLabel(
            parent, text="", text_color=MUTED,
            font=ctk.CTkFont(size=10), anchor="w",
            wraplength=440, justify="left",
        )
        self._mode_hint.pack(fill="x", padx=14, pady=(2, 6))
        self._set_decision_mode(self._decision_mode)

        self._entry_ha_url = self._labelled(
            parent, "Home Assistant URL",
            "http://192.168.0.10:8123", self._config.ha_url,
        )
        self._entry_webhook = self._labelled(
            parent, "Webhook ID",
            "имя webhook'а в HA (обычно gate_open)", self._config.webhook_id,
        )
        self._entry_uuid = self._labelled(
            parent, "Beacon UUID",
            "Общий UUID авторизованных машин", self._config.beacon_uuid,
        )

        row = ctk.CTkFrame(parent, fg_color="transparent")
        row.pack(fill="x", padx=14, pady=(0, 6))
        self._entry_rssi = self._labelled(
            row, "RSSI порог", "напр. -65",
            str(self._config.rssi_threshold), side="left",
        )
        self._entry_cooldown = self._labelled(
            row, "Cooldown сек", "напр. 10",
            str(self._config.cooldown_seconds), side="left",
        )
        self._entry_samples = self._labelled(
            row, "Samples", "напр. 2",
            str(self._config.samples_required), side="left",
        )

        # Save button
        ctk.CTkButton(
            parent,
            text="💾  Сохранить настройки",
            height=40,
            fg_color=SURFACE_HI,
            hover_color=DIVIDER,
            text_color=PRIMARY,
            border_width=1,
            border_color=DIVIDER,
            corner_radius=10,
            command=self._save,
        ).pack(fill="x", padx=14, pady=(8, 14))

    def _set_decision_mode(self, mode: str) -> None:
        self._decision_mode = mode
        for val, btn in self._mode_btns.items():
            if val == mode:
                btn.configure(fg_color=PRIMARY, hover_color=PRIMARY_HOVER,
                              text_color="white")
            else:
                btn.configure(fg_color="transparent", hover_color=SURFACE_HI,
                              text_color=MUTED)
        if mode == "trajectory":
            self._mode_hint.configure(
                text="Доступ — по устойчивому приближению метки "
                     "(Калман + дистанция + тренд). Порог RSSI игнорируется."
            )
        else:
            self._mode_hint.configure(
                text="Доступ — по простому порогу RSSI и N замерам "
                     "(базовый метод для сравнения)."
            )

    def _labelled(
        self,
        parent,
        label: str,
        hint: str,
        initial: str,
        side: Optional[str] = None,
    ) -> ctk.CTkEntry:
        container = ctk.CTkFrame(parent, fg_color="transparent")
        if side:
            container.pack(side=side, fill="both", expand=True, padx=4)
        else:
            container.pack(fill="x", padx=14, pady=(0, 6))
        ctk.CTkLabel(
            container,
            text=label,
            text_color=MUTED,
            font=ctk.CTkFont(size=10, weight="bold"),
            anchor="w",
        ).pack(fill="x", padx=2, pady=(0, 2))
        entry = ctk.CTkEntry(
            container,
            fg_color=BG,
            text_color=ON_SURFACE,
            border_color=DIVIDER,
            border_width=1,
            corner_radius=8,
            height=36,
            font=ctk.CTkFont(family="Consolas", size=12),
        )
        if initial:
            entry.insert(0, initial)
        entry.pack(fill="x")
        if hint:
            ctk.CTkLabel(
                container,
                text=hint,
                text_color=MUTED,
                font=ctk.CTkFont(size=10),
                anchor="w",
                wraplength=420,
                justify="left",
            ).pack(fill="x", padx=2, pady=(2, 0))
        return entry

    def _build_whitelist(self, parent) -> None:
        header = ctk.CTkFrame(parent, fg_color="transparent")
        header.pack(fill="x", padx=14, pady=(12, 4))
        ctk.CTkLabel(
            header,
            text="АВТОРИЗОВАННЫЕ ТС",
            text_color=MUTED,
            font=ctk.CTkFont(size=12, weight="bold"),
            anchor="w",
        ).pack(side="left")
        ctk.CTkButton(
            header,
            text="➕  Добавить",
            width=120,
            height=28,
            corner_radius=8,
            font=ctk.CTkFont(size=11, weight="bold"),
            fg_color=SURFACE_HI,
            text_color=PRIMARY,
            border_width=1,
            border_color=DIVIDER,
            command=self._add_vehicle,
        ).pack(side="right")

        self._whitelist_list = ctk.CTkFrame(parent, fg_color="transparent")
        self._whitelist_list.pack(fill="x", padx=14, pady=(0, 14))
        self._refresh_whitelist()

    def _refresh_whitelist(self) -> None:
        for child in self._whitelist_list.winfo_children():
            child.destroy()
        if not self._config.whitelist:
            ctk.CTkLabel(
                self._whitelist_list,
                text="Пусто — добавьте хотя бы одно ТС перед запуском",
                text_color=MUTED,
                font=ctk.CTkFont(size=12),
                anchor="w",
            ).pack(fill="x", pady=4)
            return
        for v in self._config.whitelist:
            row = ctk.CTkFrame(self._whitelist_list, fg_color=BG, corner_radius=8)
            row.pack(fill="x", pady=4)
            ctk.CTkLabel(
                row,
                text=v.name,
                text_color=ON_SURFACE,
                font=ctk.CTkFont(size=13, weight="bold"),
                anchor="w",
            ).pack(side="left", padx=(10, 6), pady=8)
            parts: list[str] = []
            if v.major is not None:
                parts.append(f"Major={v.major}")
            if v.minor is not None:
                parts.append(f"Minor={v.minor}")
            elif v.major is not None:
                parts.append("(любой Minor)")
            if v.mac:
                parts.append(f"MAC={v.mac}")
            if not parts:
                parts.append("(пустая запись)")
            ctk.CTkLabel(
                row,
                text="  ".join(parts),
                text_color=MUTED,
                font=ctk.CTkFont(family="Consolas", size=11),
                anchor="w",
            ).pack(side="left", padx=4, pady=8)
            ctk.CTkButton(
                row,
                text="✕",
                width=28,
                height=28,
                corner_radius=6,
                fg_color="transparent",
                hover_color=DANGER,
                text_color=DANGER,
                command=lambda vv=v: self._remove_vehicle(vv),
            ).pack(side="right", padx=8, pady=6)

    def _add_vehicle(self) -> None:
        if self._running:
            return
        dialog = _VehicleDialog(self)
        result = dialog.show()
        if result is not None:
            self._config.whitelist.append(result)
            save_config(self._config)
            self._refresh_whitelist()

    def _remove_vehicle(self, v: AuthorizedVehicle) -> None:
        if self._running:
            return
        self._config.whitelist = [x for x in self._config.whitelist if x is not v]
        save_config(self._config)
        self._refresh_whitelist()

    def _build_log(self, parent) -> None:
        ctk.CTkLabel(
            parent,
            text="ЖУРНАЛ СОБЫТИЙ",
            text_color=MUTED,
            font=ctk.CTkFont(size=12, weight="bold"),
            anchor="w",
        ).pack(fill="x", padx=14, pady=(12, 4))
        self._log_frame = ctk.CTkScrollableFrame(parent, fg_color=BG, height=240)
        self._log_frame.pack(fill="both", expand=True, padx=14, pady=(0, 14))
        self._empty_log = ctk.CTkLabel(
            self._log_frame,
            text="События появятся здесь после старта",
            text_color=MUTED,
            font=ctk.CTkFont(size=12),
        )
        self._empty_log.pack(pady=20)

    # ---- Behavior ----

    def _save(self) -> None:
        cfg = GatewayConfig(
            ha_url=self._entry_ha_url.get().strip(),
            webhook_id=self._entry_webhook.get().strip(),
            beacon_uuid=self._entry_uuid.get().strip(),
            rssi_threshold=self._safe_int(self._entry_rssi.get(), -65),
            cooldown_seconds=self._safe_int(self._entry_cooldown.get(), 10),
            samples_required=self._safe_int(self._entry_samples.get(), 2),
            whitelist=list(self._config.whitelist),
            # Режим решения из переключателя; параметры траектории — из текущего конфига.
            decision_mode=self._decision_mode,
            grant_distance=self._config.grant_distance,
            approach_samples=self._config.approach_samples,
            trend_window=self._config.trend_window,
            trend_eps=self._config.trend_eps,
            tx_power_1m=self._config.tx_power_1m,
            path_loss_n=self._config.path_loss_n,
        )
        save_config(cfg)
        self._config = cfg
        self._monitor.update_config(cfg)
        self._add_log(GatewayEvent(datetime.now(), "info", "Настройки сохранены"))

    def _safe_int(self, s: str, default: int) -> int:
        try:
            return int(s.strip())
        except (ValueError, AttributeError):
            return default

    def _toggle(self) -> None:
        if self._running:
            self._monitor.stop()
            self._set_running(False)
            return

        # Сначала сохраняем форму
        self._save()
        if not self._config.beacon_uuid:
            self._add_log(GatewayEvent(datetime.now(), "error", "Заполните Beacon UUID"))
            return
        if not self._config.ha_url:
            self._add_log(GatewayEvent(datetime.now(), "error", "Заполните Home Assistant URL"))
            return
        if not self._config.whitelist:
            self._add_log(GatewayEvent(datetime.now(), "error", "Добавьте хотя бы одно ТС"))
            return

        self._monitor.start()
        self._set_running(True)

    def _set_running(self, on: bool) -> None:
        self._running = on
        if on:
            self._status_dot.configure(fg_color=SUCCESS)
            self._status_label.configure(text="Мониторинг активен")
            self._action_btn.configure(
                text="■  Остановить мониторинг",
                fg_color=DANGER, hover_color=DANGER_HOVER,
            )
        else:
            self._status_dot.configure(fg_color=MUTED)
            self._status_label.configure(text="Шлюз остановлен")
            self._action_btn.configure(
                text="▶  Запустить мониторинг",
                fg_color=PRIMARY, hover_color=PRIMARY_HOVER,
            )

    def _poll_events(self) -> None:
        try:
            while True:
                ev = self._events.get_nowait()
                self._add_log(ev)
        except Exception:
            pass
        self.after(200, self._poll_events)

    def _add_log(self, ev: GatewayEvent) -> None:
        self._log.insert(0, ev)
        # Уберём placeholder при первой записи
        if hasattr(self, "_empty_log") and self._empty_log is not None:
            try:
                if self._empty_log.winfo_exists():
                    self._empty_log.destroy()
            except Exception:
                pass
            self._empty_log = None

        color = {
            "info": MUTED,
            "success": SUCCESS,
            "warning": WARNING,
            "error": DANGER,
        }.get(ev.level, ON_SURFACE)

        row = ctk.CTkFrame(self._log_frame, fg_color=BG, corner_radius=6)
        ctk.CTkLabel(
            row,
            text=ev.ts.strftime("%H:%M:%S"),
            text_color=MUTED,
            font=ctk.CTkFont(family="Consolas", size=11),
        ).pack(side="left", padx=(8, 6), pady=4)
        ctk.CTkLabel(
            row,
            text=ev.text,
            text_color=color,
            font=ctk.CTkFont(family="Consolas", size=11),
            anchor="w",
            justify="left",
        ).pack(side="left", padx=4, pady=4, fill="x", expand=True)
        # side="bottom" => первый прижимается к низу, второй ставится ВЫШЕ него,
        # и так далее — новейший автоматически оказывается на самом верху.
        row.pack(side="bottom", fill="x", pady=2)

        # Лимит — обрежем самые старые строки (они внизу при side="bottom").
        if not hasattr(self, "_log_rows"):
            self._log_rows: list = []
        self._log_rows.insert(0, row)
        while len(self._log_rows) > 100:
            old = self._log_rows.pop()
            try:
                old.destroy()
            except Exception:
                pass
        self._log = self._log[:100]

    def shutdown(self) -> None:
        try:
            self._monitor.stop()
        except Exception:
            pass


# --------------------------------------------------------------------------- #
# Vehicle dialog
# --------------------------------------------------------------------------- #


class _VehicleDialog:
    def __init__(self, master):
        self._master = master
        self._result: Optional[AuthorizedVehicle] = None
        self._win = ctk.CTkToplevel(master)
        self._win.title("Авторизованное ТС")
        self._win.geometry("440x500")
        self._win.configure(fg_color=BG)
        self._win.transient(master.winfo_toplevel())
        self._win.grab_set()

        ctk.CTkLabel(
            self._win,
            text="Новое ТС",
            text_color=ON_SURFACE,
            font=ctk.CTkFont(size=18, weight="bold"),
        ).pack(pady=(20, 4))

        ctk.CTkLabel(
            self._win,
            text="Задайте хотя бы один признак: Major или MAC",
            text_color=MUTED,
            font=ctk.CTkFont(size=11),
        ).pack(pady=(0, 10))

        self._name = self._field("Имя водителя / ТС", "")
        self._major = self._field("Major (0–65535, опц. если задан MAC)", "")
        self._minor = self._field("Minor (необязательно)", "")
        self._mac = self._field("MAC (AA:BB:CC:DD:EE:FF, опц.)", "")

        self._error = ctk.CTkLabel(
            self._win, text="", text_color=DANGER,
            font=ctk.CTkFont(size=11), anchor="w",
        )
        self._error.pack(fill="x", padx=20, pady=(4, 0))

        btns = ctk.CTkFrame(self._win, fg_color="transparent")
        btns.pack(side="bottom", fill="x", padx=20, pady=20)
        ctk.CTkButton(
            btns, text="Отмена", height=40, fg_color=SURFACE_HI,
            text_color=ON_SURFACE, hover_color=DIVIDER,
            command=self._cancel,
        ).pack(side="left", expand=True, fill="x", padx=(0, 6))
        ctk.CTkButton(
            btns, text="Сохранить", height=40, fg_color=PRIMARY,
            text_color="white", hover_color=PRIMARY_HOVER,
            command=self._save,
        ).pack(side="left", expand=True, fill="x", padx=(6, 0))

    def _field(self, label: str, initial: str) -> ctk.CTkEntry:
        ctk.CTkLabel(
            self._win, text=label, text_color=MUTED,
            font=ctk.CTkFont(size=10, weight="bold"), anchor="w",
        ).pack(fill="x", padx=20, pady=(4, 2))
        entry = ctk.CTkEntry(
            self._win, height=36, fg_color=SURFACE,
            text_color=ON_SURFACE, border_color=DIVIDER,
            font=ctk.CTkFont(family="Consolas", size=13),
        )
        if initial:
            entry.insert(0, initial)
        entry.pack(fill="x", padx=20, pady=(0, 4))
        return entry

    def _show_error(self, msg: str) -> None:
        self._error.configure(text=msg)

    def _cancel(self) -> None:
        self._win.destroy()

    def _save(self) -> None:
        name = self._name.get().strip()
        if not name:
            self._show_error("Имя ТС обязательно")
            return

        major_str = self._major.get().strip()
        minor_str = self._minor.get().strip()
        mac_str = self._mac.get().strip()

        major: Optional[int] = None
        if major_str:
            try:
                major = int(major_str)
            except ValueError:
                self._show_error("Major должен быть целым числом")
                return
            if not (0 <= major <= 0xFFFF):
                self._show_error("Major вне диапазона 0–65535")
                return

        minor: Optional[int] = None
        if minor_str:
            try:
                minor = int(minor_str)
            except ValueError:
                self._show_error("Minor должен быть целым числом")
                return
            if not (0 <= minor <= 0xFFFF):
                self._show_error("Minor вне диапазона 0–65535")
                return

        mac: Optional[str] = None
        if mac_str:
            mac = normalize_mac(mac_str)
            if mac is None:
                self._show_error("MAC должен быть в формате AA:BB:CC:DD:EE:FF")
                return

        if major is None and mac is None:
            self._show_error("Нужен Major или MAC (хотя бы что-то одно)")
            return

        self._result = AuthorizedVehicle(name=name, major=major, minor=minor, mac=mac)
        self._win.destroy()

    def show(self) -> Optional[AuthorizedVehicle]:
        self._win.wait_window()
        return self._result
