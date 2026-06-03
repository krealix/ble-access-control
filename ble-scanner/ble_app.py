"""BLE Beacon Toolkit — desktop GUI for Windows.

Объединяет сканер и генератор BLE-меток в одно приложение с тёмной
STOWN-палитрой. Использует customtkinter для виджетов и стилизации.

Запуск:
    pip install -r requirements.txt
    python ble_app.py

Сканер использует bleak (любые BLE-устройства).
Генератор использует WinRT BluetoothLEAdvertisementPublisher (Windows).
iBeacon на Windows не вещается — ОС блокирует Apple Manufacturer ID 0x004C.
"""
from __future__ import annotations

import asyncio
import secrets
import threading
import tkinter as tk
from datetime import datetime
from typing import Callable, Optional

import customtkinter as ctk

from bleak import BleakScanner
from bleak.exc import BleakError
from winrt.windows.devices.bluetooth.advertisement import (
    BluetoothLEAdvertisementPublisher,
    BluetoothLEAdvertisementPublisherStatus as PubStatus,
)

from ble_generator import (
    build_custom,
    build_eddystone_uid,
    build_eddystone_url,
)
from ble_scanner import BeaconKind, parse as parse_beacon

# --------------------------------------------------------------------------- #
# STOWN palette
# --------------------------------------------------------------------------- #

BG = "#0B1426"
SURFACE = "#142136"
SURFACE_HI = "#1B2A44"
PRIMARY = "#2D8CFF"
PRIMARY_HOVER = "#1565DD"
PRIMARY_LIGHT = "#4FA3FF"
DANGER = "#E74C5C"
DANGER_HOVER = "#C73947"
SUCCESS = "#22C55E"
WARNING = "#FFB74D"
ACCENT = "#4DD0E1"
ON_SURFACE = "#E7ECF4"
MUTED = "#8FA0BA"
DIVIDER = "#243450"

KIND_COLORS = {
    BeaconKind.IBEACON: PRIMARY_LIGHT,
    BeaconKind.EDDYSTONE_UID: SUCCESS,
    BeaconKind.EDDYSTONE_URL: WARNING,
    BeaconKind.EDDYSTONE_TLM: "#BA68C8",
    BeaconKind.GENERIC: MUTED,
}

STALE_AFTER_SECONDS = 15

ctk.set_appearance_mode("dark")
ctk.set_widget_scaling(1.0)


# --------------------------------------------------------------------------- #
# Reusable widgets
# --------------------------------------------------------------------------- #


class Card(ctk.CTkFrame):
    """Скруглённая тёмная карточка."""

    def __init__(self, master, **kw):
        kw.setdefault("fg_color", SURFACE)
        kw.setdefault("corner_radius", 14)
        super().__init__(master, **kw)


class SectionLabel(ctk.CTkLabel):
    """Заглавная подпись секции (uppercase, muted)."""

    def __init__(self, master, text: str):
        super().__init__(
            master,
            text=text.upper(),
            text_color=MUTED,
            font=ctk.CTkFont(size=11, weight="bold"),
            anchor="w",
        )


class StatusDot(ctk.CTkFrame):
    def __init__(self, master, color: str = MUTED):
        super().__init__(master, width=12, height=12, corner_radius=6, fg_color=color)
        self.pack_propagate(False)

    def set_color(self, color: str) -> None:
        self.configure(fg_color=color)


class HelperText(ctk.CTkLabel):
    """Серая подсказка под полем ввода."""

    def __init__(self, master, text: str):
        super().__init__(
            master,
            text=text,
            text_color=MUTED,
            font=ctk.CTkFont(size=11),
            wraplength=520,
            justify="left",
            anchor="w",
        )


def labelled_entry(
    parent,
    label: str,
    helper: str = "",
    width: int = 320,
    initial: str = "",
) -> tuple[ctk.CTkEntry, ctk.CTkFrame]:
    """Создаёт лейбл + поле + helper. Возвращает (entry, container)."""
    container = ctk.CTkFrame(parent, fg_color="transparent")
    ctk.CTkLabel(
        container,
        text=label,
        text_color=MUTED,
        font=ctk.CTkFont(size=11, weight="bold"),
        anchor="w",
    ).pack(fill="x", padx=2, pady=(0, 4))
    entry = ctk.CTkEntry(
        container,
        fg_color=SURFACE,
        text_color=ON_SURFACE,
        border_color=DIVIDER,
        border_width=1,
        corner_radius=10,
        height=42,
        font=ctk.CTkFont(family="Consolas", size=13),
        width=width,
    )
    if initial:
        entry.insert(0, initial)
    entry.pack(fill="x")
    if helper:
        HelperText(container, helper).pack(fill="x", padx=2, pady=(4, 0))
    return entry, container


# --------------------------------------------------------------------------- #
# Scanner worker — runs bleak in a background thread
# --------------------------------------------------------------------------- #


class ScannerWorker:
    def __init__(self, on_result: Callable):
        self._on_result = on_result
        self._loop: Optional[asyncio.AbstractEventLoop] = None
        self._scanner: Optional[BleakScanner] = None
        self._thread: Optional[threading.Thread] = None
        self._stop_event: Optional[threading.Event] = None
        self._error: Optional[str] = None

    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def start(self) -> None:
        if self.running:
            return
        self._error = None
        self._stop_event = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if not self.running or not self._loop:
            return
        # Сигналим event loop'у воркера, что нужно остановиться.
        self._stop_event.set()
        try:
            self._loop.call_soon_threadsafe(self._stop_event_set_in_loop)
        except RuntimeError:
            pass

    def _stop_event_set_in_loop(self) -> None:
        # Прерываем asyncio.sleep — для этого создаём фьючу и отменяем
        pass

    @property
    def error(self) -> Optional[str]:
        return self._error

    def _run(self) -> None:
        self._loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self._loop)
        try:
            self._loop.run_until_complete(self._scan_main())
        except Exception as e:
            self._error = str(e)
        finally:
            self._loop.close()
            self._loop = None

    async def _scan_main(self) -> None:
        try:
            self._scanner = BleakScanner(detection_callback=self._on_result)
            await self._scanner.start()
        except BleakError as e:
            msg = str(e).lower()
            if "powered" in msg or "not available" in msg:
                self._error = "Bluetooth выключен"
            else:
                self._error = str(e)
            return

        try:
            while not self._stop_event.is_set():
                await asyncio.sleep(0.25)
        finally:
            try:
                await self._scanner.stop()
            except Exception:
                pass


# --------------------------------------------------------------------------- #
# Scanner tab
# --------------------------------------------------------------------------- #


class ScannerPanel(ctk.CTkFrame):
    def __init__(self, master):
        super().__init__(master, fg_color="transparent")

        self._beacons: dict[str, object] = {}
        # Порядок и плитки фиксированы по первому появлению — список не пересортировывается.
        self._tiles: dict[str, dict] = {}
        self._order: list[str] = []
        self._empty_shown: bool = True
        self._filter: Optional[BeaconKind] = None
        self._worker = ScannerWorker(on_result=self._on_scan_result)

        # Status row
        status_row = ctk.CTkFrame(self, fg_color="transparent")
        status_row.pack(fill="x", padx=4, pady=(8, 12))

        self._status_dot = StatusDot(status_row, color=DANGER)
        self._status_dot.pack(side="left", padx=(0, 10))
        self._status_label = ctk.CTkLabel(
            status_row,
            text="Сканер остановлен",
            text_color=ON_SURFACE,
            font=ctk.CTkFont(size=15, weight="bold"),
        )
        self._status_label.pack(side="left")
        self._count_label = ctk.CTkLabel(
            status_row, text="", text_color=MUTED, font=ctk.CTkFont(size=12)
        )
        self._count_label.pack(side="right")

        # Filter chips
        filters_row = ctk.CTkFrame(self, fg_color="transparent")
        filters_row.pack(fill="x", padx=4, pady=(0, 12))

        self._filter_buttons: dict[Optional[BeaconKind], ctk.CTkButton] = {}
        filters: list[tuple[str, Optional[BeaconKind]]] = [
            ("Все", None),
            ("iBeacon", BeaconKind.IBEACON),
            ("Eddy UID", BeaconKind.EDDYSTONE_UID),
            ("Eddy URL", BeaconKind.EDDYSTONE_URL),
            ("Generic", BeaconKind.GENERIC),
        ]
        for label, kind in filters:
            btn = ctk.CTkButton(
                filters_row,
                text=label,
                width=88,
                height=32,
                corner_radius=16,
                font=ctk.CTkFont(size=12, weight="bold"),
                fg_color=SURFACE,
                hover_color=SURFACE_HI,
                text_color=ON_SURFACE,
                border_width=1,
                border_color=DIVIDER,
                command=lambda k=kind: self._set_filter(k),
            )
            btn.pack(side="left", padx=(0, 6))
            self._filter_buttons[kind] = btn
        self._highlight_filter()

        # List
        self._list = ctk.CTkScrollableFrame(self, fg_color=BG, corner_radius=0)
        self._list.pack(fill="both", expand=True, padx=0, pady=(0, 12))

        self._empty_label = ctk.CTkLabel(
            self._list,
            text="\n\nНажмите «Начать поиск», чтобы увидеть BLE-маяки рядом\n",
            text_color=MUTED,
            font=ctk.CTkFont(size=13),
        )
        self._empty_label.pack(pady=40)

        # Action button
        self._action_btn = ctk.CTkButton(
            self,
            text="▶  Начать поиск",
            height=50,
            corner_radius=12,
            fg_color=PRIMARY,
            hover_color=PRIMARY_HOVER,
            text_color="white",
            font=ctk.CTkFont(size=15, weight="bold"),
            command=self._toggle,
        )
        self._action_btn.pack(fill="x", padx=4, pady=(0, 4))

        # Periodic UI refresh
        self._tick_id = self.after(500, self._tick)

    # ---- UI state ----

    def _set_filter(self, kind: Optional[BeaconKind]) -> None:
        self._filter = kind
        self._highlight_filter()
        self._repack_all()

    def _highlight_filter(self) -> None:
        for kind, btn in self._filter_buttons.items():
            if kind == self._filter:
                btn.configure(
                    fg_color=PRIMARY,
                    border_color=PRIMARY,
                    text_color="white",
                )
            else:
                btn.configure(
                    fg_color=SURFACE,
                    border_color=DIVIDER,
                    text_color=ON_SURFACE,
                )

    def _set_running(self, running: bool) -> None:
        if running:
            self._status_dot.set_color(SUCCESS)
            self._status_label.configure(text="Поиск активен")
            self._action_btn.configure(
                text="■  Остановить поиск",
                fg_color=DANGER,
                hover_color=DANGER_HOVER,
            )
        else:
            self._status_dot.set_color(DANGER)
            self._status_label.configure(text="Сканер остановлен")
            self._action_btn.configure(
                text="▶  Начать поиск",
                fg_color=PRIMARY,
                hover_color=PRIMARY_HOVER,
            )

    # ---- BLE callbacks ----

    def _on_scan_result(self, device, adv) -> None:
        """Вызывается из воркер-потока bleak. Перекидываем в UI-поток."""

        class _R:
            pass

        r = _R()
        r.device = device
        r.advertisement_data = adv
        r.rssi = getattr(adv, "rssi", None) or getattr(device, "rssi", 0) or 0
        try:
            parsed = parse_beacon(device, adv)
        except Exception:
            return
        # marshal to UI thread
        self.after(0, self._add_beacon, parsed)

    def _matches(self, parsed) -> bool:
        return self._filter is None or parsed.kind == self._filter

    def _add_beacon(self, parsed) -> None:
        address = parsed.address
        is_new = address not in self._beacons
        self._beacons[address] = parsed

        if is_new:
            # Новое устройство — в конец списка; порядок дальше не меняется.
            self._order.append(address)
            self._create_tile(parsed)
        elif address in self._tiles:
            # Известное — обновляем плитку НА МЕСТЕ, позиция не двигается.
            was_packed = self._tiles[address]["packed"]
            self._update_tile(parsed)
            should = self._matches(parsed)
            if should and not was_packed:
                self._repack_all()  # стал подходить под фильтр — вернуть по порядку
            elif not should and was_packed:
                self._hide_tile(address)
                if not any(r["packed"] for r in self._tiles.values()):
                    self._set_empty(True)
        else:
            # Рассинхрон (плитки нет) — создаём.
            if address not in self._order:
                self._order.append(address)
            self._create_tile(parsed)

        self._update_counter()

    def _update_counter(self) -> None:
        visible = sum(
            1 for b in self._beacons.values()
            if self._filter is None or b.kind == self._filter
        )
        total = len(self._beacons)
        if total == 0:
            self._count_label.configure(text="")
        elif self._filter is None:
            self._count_label.configure(text=f"найдено: {total}")
        else:
            self._count_label.configure(text=f"найдено: {visible} / {total}")

    # ---- Плитки: фиксированный порядок, обновление на месте ----

    @staticmethod
    def _format_details(parsed) -> str:
        if not parsed.fields:
            return ""
        details = "  ".join(
            f"{k}: {v}" for k, v in list(parsed.fields.items())[:2]
        )
        if len(details) > 80:
            details = details[:80] + "…"
        return details

    def _create_tile(self, parsed) -> None:
        address = parsed.address
        color = KIND_COLORS.get(parsed.kind, MUTED)
        tile = Card(self._list, fg_color=SURFACE)
        tile.grid_columnconfigure(1, weight=1)

        # Left icon block
        icon_box = ctk.CTkFrame(
            tile, fg_color=SURFACE_HI, corner_radius=10, width=48, height=48
        )
        icon_box.grid(row=0, column=0, padx=12, pady=12, sticky="n")
        icon_box.pack_propagate(False)
        icon = ctk.CTkLabel(
            icon_box, text="📡", font=ctk.CTkFont(size=22), text_color=color
        )
        icon.place(relx=0.5, rely=0.5, anchor="center")

        # Middle column
        mid = ctk.CTkFrame(tile, fg_color="transparent")
        mid.grid(row=0, column=1, sticky="ew", pady=10)

        head = ctk.CTkFrame(mid, fg_color="transparent")
        head.pack(fill="x")
        badge = ctk.CTkLabel(
            head,
            text=f" {parsed.kind.value.upper()} ",
            text_color=color,
            fg_color=SURFACE_HI,
            corner_radius=6,
            font=ctk.CTkFont(size=10, weight="bold"),
        )
        badge.pack(side="left", padx=(0, 8))
        name = ctk.CTkLabel(
            head,
            text=parsed.name or "Неизвестное устройство",
            text_color=ON_SURFACE,
            font=ctk.CTkFont(size=14, weight="bold"),
            anchor="w",
        )
        name.pack(side="left", fill="x", expand=True)

        # Адрес статичен (это ключ устройства) — не меняется.
        ctk.CTkLabel(
            mid,
            text=address,
            text_color=MUTED,
            font=ctk.CTkFont(family="Consolas", size=11),
            anchor="w",
        ).pack(fill="x", pady=(4, 2))

        # Детали создаём всегда (пустые/скрытые), обновляем текст на месте.
        details = ctk.CTkLabel(
            mid,
            text="",
            text_color=MUTED,
            font=ctk.CTkFont(size=11),
            anchor="w",
            justify="left",
        )

        # Right RSSI
        right = ctk.CTkFrame(tile, fg_color="transparent")
        right.grid(row=0, column=2, padx=12, pady=10, sticky="ne")
        rssi = ctk.CTkLabel(
            right,
            text=f"{parsed.rssi}",
            text_color=_rssi_color(parsed.rssi),
            font=ctk.CTkFont(size=18, weight="bold"),
        )
        rssi.pack(anchor="e")
        ctk.CTkLabel(
            right, text="dBm", text_color=MUTED, font=ctk.CTkFont(size=10)
        ).pack(anchor="e")

        # Клик — всегда показываем актуальные данные (ищем по адресу).
        for w in (tile, mid, icon_box, head, name, badge, right):
            w.bind("<Button-1>", lambda _e, a=address: self._open_details(a))

        self._tiles[address] = {
            "frame": tile,
            "icon": icon,
            "badge": badge,
            "name": name,
            "details": details,
            "rssi": rssi,
            "packed": False,
            "details_packed": False,
        }
        self._update_tile(parsed)

        # Первое появление: показываем в конец списка, если проходит фильтр.
        if self._matches(parsed):
            self._set_empty(False)
            self._show_tile(address)

    def _update_tile(self, parsed) -> None:
        refs = self._tiles.get(parsed.address)
        if refs is None:
            return
        color = KIND_COLORS.get(parsed.kind, MUTED)
        refs["icon"].configure(text_color=color)
        refs["badge"].configure(
            text=f" {parsed.kind.value.upper()} ", text_color=color
        )
        refs["name"].configure(text=parsed.name or "Неизвестное устройство")
        refs["rssi"].configure(
            text=f"{parsed.rssi}", text_color=_rssi_color(parsed.rssi)
        )
        details = self._format_details(parsed)
        dl = refs["details"]
        if details:
            dl.configure(text=details)
            if not refs["details_packed"]:
                dl.pack(fill="x")
                refs["details_packed"] = True
        elif refs["details_packed"]:
            dl.pack_forget()
            refs["details_packed"] = False

    def _show_tile(self, address: str) -> None:
        refs = self._tiles.get(address)
        if refs and not refs["packed"]:
            refs["frame"].pack(fill="x", padx=8, pady=4)
            refs["packed"] = True

    def _hide_tile(self, address: str) -> None:
        refs = self._tiles.get(address)
        if refs and refs["packed"]:
            refs["frame"].pack_forget()
            refs["packed"] = False

    def _repack_all(self) -> None:
        """Перепаковать все плитки в фиксированном порядке (при смене фильтра)."""
        for addr in self._order:
            self._hide_tile(addr)
        visible = 0
        for addr in self._order:
            parsed = self._beacons.get(addr)
            if parsed is not None and self._matches(parsed):
                self._show_tile(addr)
                visible += 1
        self._set_empty(visible == 0)

    def _clear_all(self) -> None:
        for refs in self._tiles.values():
            refs["frame"].destroy()
        self._tiles.clear()
        self._order.clear()
        self._beacons.clear()
        self._set_empty(True)
        self._update_counter()

    def _set_empty(self, show: bool) -> None:
        if show and not self._empty_shown:
            self._empty_label.pack(pady=40)
            self._empty_shown = True
        elif not show and self._empty_shown:
            self._empty_label.pack_forget()
            self._empty_shown = False

    def _open_details(self, address: str) -> None:
        parsed = self._beacons.get(address)
        if parsed is not None:
            self._show_details(parsed)

    def _show_details(self, parsed) -> None:
        win = ctk.CTkToplevel(self)
        win.title(parsed.name or "BLE Beacon")
        win.geometry("520x520")
        win.configure(fg_color=BG)
        win.transient(self.winfo_toplevel())

        header = ctk.CTkFrame(win, fg_color="transparent")
        header.pack(fill="x", padx=20, pady=(20, 12))
        color = KIND_COLORS.get(parsed.kind, MUTED)
        ctk.CTkLabel(
            header,
            text=f" {parsed.kind.value.upper()} ",
            text_color=color,
            fg_color=SURFACE_HI,
            corner_radius=6,
            font=ctk.CTkFont(size=10, weight="bold"),
        ).pack(side="left", padx=(0, 10))
        ctk.CTkLabel(
            header,
            text=parsed.name or "Неизвестное устройство",
            text_color=ON_SURFACE,
            font=ctk.CTkFont(size=18, weight="bold"),
        ).pack(side="left")

        ctk.CTkLabel(
            win,
            text=parsed.address,
            text_color=MUTED,
            font=ctk.CTkFont(family="Consolas", size=12),
            anchor="w",
        ).pack(fill="x", padx=20, pady=(0, 4))
        ctk.CTkLabel(
            win,
            text=f"RSSI: {parsed.rssi} dBm",
            text_color=_rssi_color(parsed.rssi),
            font=ctk.CTkFont(size=12, weight="bold"),
            anchor="w",
        ).pack(fill="x", padx=20, pady=(0, 12))

        ctk.CTkFrame(win, height=1, fg_color=DIVIDER).pack(fill="x", padx=20)

        body = ctk.CTkScrollableFrame(win, fg_color=BG)
        body.pack(fill="both", expand=True, padx=12, pady=12)
        for k, v in parsed.fields.items():
            row = ctk.CTkFrame(body, fg_color="transparent")
            row.pack(fill="x", pady=4)
            ctk.CTkLabel(
                row,
                text=k.upper(),
                text_color=MUTED,
                font=ctk.CTkFont(size=10, weight="bold"),
                anchor="w",
            ).pack(fill="x", padx=4)
            ctk.CTkLabel(
                row,
                text=v,
                text_color=ON_SURFACE,
                font=ctk.CTkFont(family="Consolas", size=12),
                anchor="w",
                wraplength=460,
                justify="left",
            ).pack(fill="x", padx=4)

    # ---- Lifecycle ----

    def _toggle(self) -> None:
        if self._worker.running:
            self._worker.stop()
            self._set_running(False)
        else:
            self._clear_all()
            self._worker.start()
            self._set_running(True)

    def _tick(self) -> None:
        # Prune stale beacons
        now = datetime.now()
        stale = [
            addr for addr, b in self._beacons.items()
            if (now - b.seen_at).total_seconds() > STALE_AFTER_SECONDS
        ]
        for addr in stale:
            self._beacons.pop(addr, None)
            if addr in self._order:
                self._order.remove(addr)
            refs = self._tiles.pop(addr, None)
            if refs:
                refs["frame"].destroy()
        if stale:
            self._update_counter()
            if not self._tiles:
                self._set_empty(True)

        # Reflect worker error if any
        if not self._worker.running and self._action_btn.cget("text").startswith("■"):
            err = self._worker.error
            self._set_running(False)
            if err:
                self._status_label.configure(text=f"Ошибка: {err}")

        self._tick_id = self.after(500, self._tick)

    def shutdown(self) -> None:
        try:
            if self._tick_id:
                self.after_cancel(self._tick_id)
        except Exception:
            pass
        self._worker.stop()


def _rssi_color(rssi: int) -> str:
    if rssi >= -60:
        return SUCCESS
    if rssi >= -80:
        return WARNING
    return DANGER


# --------------------------------------------------------------------------- #
# Generator tab
# --------------------------------------------------------------------------- #


class GeneratorPanel(ctk.CTkFrame):
    """Три формата: Eddy URL, Eddy UID, Custom."""

    def __init__(self, master):
        super().__init__(master, fg_color="transparent")

        self._publisher: Optional[BluetoothLEAdvertisementPublisher] = None
        self._advertising = False
        self._current_kind = "eddy-url"

        # Status row
        status_row = ctk.CTkFrame(self, fg_color="transparent")
        status_row.pack(fill="x", padx=4, pady=(8, 12))

        self._status_dot = StatusDot(status_row, color=MUTED)
        self._status_dot.pack(side="left", padx=(0, 10))
        self._status_label = ctk.CTkLabel(
            status_row,
            text="Генератор остановлен",
            text_color=ON_SURFACE,
            font=ctk.CTkFont(size=15, weight="bold"),
        )
        self._status_label.pack(side="left")
        self._info_label = ctk.CTkLabel(
            status_row, text="", text_color=MUTED, font=ctk.CTkFont(size=12)
        )
        self._info_label.pack(side="right")

        # Format selector (segmented buttons)
        selector_frame = Card(self, fg_color=SURFACE)
        selector_frame.pack(fill="x", padx=4, pady=(0, 12))

        self._kind_btns: dict[str, ctk.CTkButton] = {}
        kinds = [
            ("eddy-url", "Eddystone URL"),
            ("eddy-uid", "Eddystone UID"),
            ("custom", "Custom"),
        ]
        inner = ctk.CTkFrame(selector_frame, fg_color="transparent")
        inner.pack(fill="x", padx=6, pady=6)
        for i, (key, label) in enumerate(kinds):
            btn = ctk.CTkButton(
                inner,
                text=label,
                height=40,
                corner_radius=10,
                font=ctk.CTkFont(size=13, weight="bold"),
                command=lambda k=key: self._set_kind(k),
                fg_color="transparent",
                hover_color=SURFACE_HI,
                text_color=MUTED,
            )
            btn.grid(row=0, column=i, sticky="ew", padx=2)
            inner.grid_columnconfigure(i, weight=1)
            self._kind_btns[key] = btn

        # Forms (one per kind) — show/hide
        self._forms_container = ctk.CTkFrame(self, fg_color="transparent")
        self._forms_container.pack(fill="both", expand=True, padx=4, pady=(0, 12))
        self._forms: dict[str, ctk.CTkFrame] = {}

        self._build_eddy_url_form()
        self._build_eddy_uid_form()
        self._build_custom_form()

        # Action buttons row
        actions = ctk.CTkFrame(self, fg_color="transparent")
        actions.pack(fill="x", padx=4, pady=(0, 4))

        self._random_btn = ctk.CTkButton(
            actions,
            text="🎲  Случайно",
            width=140,
            height=50,
            corner_radius=12,
            fg_color=SURFACE,
            hover_color=SURFACE_HI,
            text_color=ON_SURFACE,
            border_width=1,
            border_color=DIVIDER,
            font=ctk.CTkFont(size=13, weight="bold"),
            command=self._random_fill,
        )
        self._random_btn.pack(side="left", padx=(0, 8))

        self._action_btn = ctk.CTkButton(
            actions,
            text="▶  Начать вещание",
            height=50,
            corner_radius=12,
            fg_color=PRIMARY,
            hover_color=PRIMARY_HOVER,
            text_color="white",
            font=ctk.CTkFont(size=15, weight="bold"),
            command=self._toggle,
        )
        self._action_btn.pack(side="left", fill="x", expand=True)

        # Toast (error/info)
        self._toast = ctk.CTkLabel(
            self,
            text="",
            text_color=DANGER,
            fg_color=SURFACE,
            corner_radius=8,
            font=ctk.CTkFont(size=12),
            anchor="w",
            padx=12,
            pady=8,
        )
        # пакуем при показе

        self._set_kind("eddy-url")
        self._random_fill()
        self.after(500, self._poll_status)

    # ---- Forms ----

    def _build_eddy_url_form(self) -> None:
        f = ctk.CTkFrame(self._forms_container, fg_color="transparent")
        SectionLabel(f, "Параметры").pack(fill="x", padx=2, pady=(0, 4))

        self._url_entry, c = labelled_entry(
            f,
            "URL",
            "Полный адрес со схемой. Максимум 17 символов после http(s)://.",
            initial="https://flutter.dev",
        )
        c.pack(fill="x", pady=(0, 12))

        self._url_tx_entry, c = labelled_entry(
            f,
            "TX Power (dBm)",
            "Калиброванный RSSI на 1 м. Обычно -20 dBm.",
            initial="-20",
        )
        c.pack(fill="x")
        self._forms["eddy-url"] = f

    def _build_eddy_uid_form(self) -> None:
        f = ctk.CTkFrame(self._forms_container, fg_color="transparent")
        SectionLabel(f, "Параметры").pack(fill="x", padx=2, pady=(0, 4))

        self._ns_entry, c = labelled_entry(
            f,
            "Namespace (10 байт hex)",
            "20 hex-символов. Идентификатор организации, общий для всех маяков.",
        )
        c.pack(fill="x", pady=(0, 12))

        self._inst_entry, c = labelled_entry(
            f,
            "Instance (6 байт hex)",
            "12 hex-символов. Номер конкретного маяка внутри namespace.",
        )
        c.pack(fill="x", pady=(0, 12))

        self._uid_tx_entry, c = labelled_entry(
            f,
            "TX Power (dBm)",
            "Калиброванный RSSI на 1 м. Обычно -20 dBm.",
            initial="-20",
        )
        c.pack(fill="x")
        self._forms["eddy-uid"] = f

    def _build_custom_form(self) -> None:
        f = ctk.CTkFrame(self._forms_container, fg_color="transparent")
        SectionLabel(f, "Параметры").pack(fill="x", padx=2, pady=(0, 4))

        self._cid_entry, c = labelled_entry(
            f,
            "Company ID",
            "Hex (0x0001..0xFFFF) или dec. Для тестов используется 0xFFFF.",
            initial="0xFFFF",
        )
        c.pack(fill="x", pady=(0, 12))

        self._data_entry, c = labelled_entry(
            f,
            "Manufacturer Data (hex)",
            "Произвольные байты в hex (без пробелов или с — оба варианта).",
        )
        c.pack(fill="x")
        self._forms["custom"] = f

    def _set_kind(self, kind: str) -> None:
        if self._advertising:
            return
        self._current_kind = kind
        for key, btn in self._kind_btns.items():
            if key == kind:
                btn.configure(
                    fg_color=PRIMARY,
                    hover_color=PRIMARY_HOVER,
                    text_color="white",
                )
            else:
                btn.configure(
                    fg_color="transparent",
                    hover_color=SURFACE_HI,
                    text_color=MUTED,
                )
        for key, form in self._forms.items():
            form.pack_forget()
        self._forms[kind].pack(fill="both", expand=True)

    # ---- Random ----

    def _random_fill(self) -> None:
        if self._advertising:
            return
        sample_urls = [
            "https://flutter.dev",
            "https://anthropic.com",
            "https://example.com",
        ]
        self._url_entry.delete(0, "end")
        self._url_entry.insert(0, secrets.choice(sample_urls))

        self._ns_entry.delete(0, "end")
        self._ns_entry.insert(0, secrets.token_hex(10).upper())
        self._inst_entry.delete(0, "end")
        self._inst_entry.insert(0, secrets.token_hex(6).upper())

        self._cid_entry.delete(0, "end")
        self._cid_entry.insert(0, "0xFFFF")
        self._data_entry.delete(0, "end")
        self._data_entry.insert(0, secrets.token_hex(4).upper())

    # ---- Advertise lifecycle ----

    def _show_toast(self, text: str, kind: str = "error") -> None:
        color = DANGER if kind == "error" else WARNING
        self._toast.configure(text=text, text_color=color)
        if not self._toast.winfo_ismapped():
            self._toast.pack(fill="x", padx=4, pady=(0, 8), before=self._toast.master.pack_slaves()[-1])
        self.after(4000, self._hide_toast)

    def _hide_toast(self) -> None:
        try:
            self._toast.pack_forget()
        except Exception:
            pass

    def _toggle(self) -> None:
        if self._advertising:
            self._stop_publisher()
            return
        try:
            adv = self._build_advertisement()
        except ValueError as e:
            self._show_toast(str(e))
            return
        try:
            self._publisher = BluetoothLEAdvertisementPublisher(adv)
            self._publisher.start()
        except Exception as e:
            self._show_toast(f"Ошибка запуска: {e}")
            return
        self._advertising = True
        self._set_advertising_state(True)

    def _stop_publisher(self) -> None:
        if self._publisher is not None:
            try:
                self._publisher.stop()
            except Exception:
                pass
            self._publisher = None
        self._advertising = False
        self._set_advertising_state(False)

    def _build_advertisement(self):
        if self._current_kind == "eddy-url":
            url = self._url_entry.get().strip()
            tx = self._parse_int(self._url_tx_entry.get(), default=-20)
            return build_eddystone_url(url, tx)
        if self._current_kind == "eddy-uid":
            ns = self._ns_entry.get().strip()
            inst = self._inst_entry.get().strip()
            tx = self._parse_int(self._uid_tx_entry.get(), default=-20)
            return build_eddystone_uid(ns, inst, tx)
        # custom
        try:
            cid = int(self._cid_entry.get(), 0)
        except ValueError:
            raise ValueError(f"Некорректный Company ID: {self._cid_entry.get()}")
        try:
            data = bytes.fromhex(self._data_entry.get().replace(" ", ""))
        except ValueError as e:
            raise ValueError(f"Некорректный hex: {e}")
        return build_custom(cid, data)

    def _parse_int(self, s: str, default: int) -> int:
        try:
            return int(s.strip())
        except ValueError:
            return default

    def _set_advertising_state(self, on: bool) -> None:
        if on:
            self._status_dot.set_color(SUCCESS)
            self._status_label.configure(text="Вещание активно")
            self._action_btn.configure(
                text="■  Остановить вещание",
                fg_color=DANGER,
                hover_color=DANGER_HOVER,
            )
            self._random_btn.configure(state="disabled")
            for key, btn in self._kind_btns.items():
                btn.configure(state="disabled")
        else:
            self._status_dot.set_color(MUTED)
            self._status_label.configure(text="Генератор остановлен")
            self._info_label.configure(text="")
            self._action_btn.configure(
                text="▶  Начать вещание",
                fg_color=PRIMARY,
                hover_color=PRIMARY_HOVER,
            )
            self._random_btn.configure(state="normal")
            for key, btn in self._kind_btns.items():
                btn.configure(state="normal")

    def _poll_status(self) -> None:
        if self._advertising and self._publisher is not None:
            try:
                status = self._publisher.status
            except Exception:
                status = None
            if status == PubStatus.STARTED:
                self._info_label.configure(
                    text="статус: STARTED",
                    text_color=SUCCESS,
                )
            elif status == PubStatus.WAITING:
                self._info_label.configure(
                    text="статус: WAITING",
                    text_color=WARNING,
                )
            elif status == PubStatus.ABORTED:
                self._info_label.configure(
                    text="статус: ABORTED",
                    text_color=DANGER,
                )
                self._stop_publisher()
                self._show_toast("Вещание прервано системой")
        self.after(500, self._poll_status)

    def shutdown(self) -> None:
        self._stop_publisher()


# --------------------------------------------------------------------------- #
# Main app
# --------------------------------------------------------------------------- #


class BleApp(ctk.CTk):
    def __init__(self):
        super().__init__(fg_color=BG)
        self.title("BLE Beacon — Toolkit")
        self.geometry("960x740")
        self.minsize(720, 600)

        # Top bar
        self._build_top_bar()

        # Tabs
        self._tabs = ctk.CTkTabview(
            self,
            fg_color=BG,
            segmented_button_fg_color=SURFACE,
            segmented_button_selected_color=PRIMARY,
            segmented_button_selected_hover_color=PRIMARY_HOVER,
            segmented_button_unselected_color=SURFACE,
            segmented_button_unselected_hover_color=SURFACE_HI,
            text_color=ON_SURFACE,
            corner_radius=12,
        )
        self._tabs.pack(fill="both", expand=True, padx=16, pady=(0, 16))

        scanner_tab = self._tabs.add("  Сканер  ")
        generator_tab = self._tabs.add("  Генератор  ")
        lock_tab = self._tabs.add("  Замки  ")
        gateway_tab = self._tabs.add("  Шлюз  ")

        self.scanner_panel = ScannerPanel(scanner_tab)
        self.scanner_panel.pack(fill="both", expand=True)

        self.generator_panel = GeneratorPanel(generator_tab)
        self.generator_panel.pack(fill="both", expand=True)

        # Вкладка «Замки» — реальная отправка 10 байт в HM10 (connect + write FFE1).
        from ble_lock import LockPanel
        self.lock_panel = LockPanel(lock_tab)
        self.lock_panel.pack(fill="both", expand=True)

        # Импортируем здесь (а не наверху) — `ble_gateway` зависит от `requests`,
        # запускать без gateway-таба должно быть возможно.
        from ble_gateway import GatewayPanel
        self.gateway_panel = GatewayPanel(gateway_tab)
        self.gateway_panel.pack(fill="both", expand=True)

        self.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_top_bar(self) -> None:
        top = ctk.CTkFrame(self, fg_color=BG, height=80)
        top.pack(fill="x", padx=16, pady=(16, 12))
        top.pack_propagate(False)

        # Logo / title block
        title_block = ctk.CTkFrame(top, fg_color="transparent")
        title_block.pack(side="left", fill="y")

        ctk.CTkLabel(
            title_block,
            text="BLE BEACON",
            text_color=ON_SURFACE,
            font=ctk.CTkFont(size=24, weight="bold"),
            anchor="w",
        ).pack(anchor="w")
        ctk.CTkLabel(
            title_block,
            text="Сканер и генератор маяков",
            text_color=MUTED,
            font=ctk.CTkFont(size=12),
            anchor="w",
        ).pack(anchor="w")

        # Right-side info
        right_block = ctk.CTkFrame(top, fg_color="transparent")
        right_block.pack(side="right", fill="y")
        ctk.CTkLabel(
            right_block,
            text="🔵",
            text_color=PRIMARY,
            font=ctk.CTkFont(size=28),
        ).pack(anchor="e")

    def _on_close(self) -> None:
        try:
            self.scanner_panel.shutdown()
            self.generator_panel.shutdown()
            if hasattr(self, "lock_panel"):
                self.lock_panel.shutdown()
            if hasattr(self, "gateway_panel"):
                self.gateway_panel.shutdown()
        finally:
            self.destroy()


def main() -> None:
    app = BleApp()
    app.mainloop()


if __name__ == "__main__":
    main()
