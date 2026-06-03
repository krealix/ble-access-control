"""Вкладка «Замки» для ble_app.py — реальная отправка 10 байт в HM10.

В отличие от сканера (который только слушает рекламу), здесь приложение
ПОДКЛЮЧАЕТСЯ к HM10 и пишет пакет в характеристику FFE1 — то, что вылетает
в RS-485 и открывает замок. Вся BLE-логика — в hm10.py.

Поток работы:
    1. «Найти HM10» — однократный скан, заполняет выпадающий список.
    2. Указать команду / идентификатор / номер замка (превью пакета вживую).
    3. «Открыть замок» — connect → write FFE1 → ждём ответ → disconnect.

bleak запускается в отдельном потоке со своим event loop; результаты
прокидываются в UI-поток через очередь (как в ble_gateway / ScannerWorker).
"""
from __future__ import annotations

import asyncio
import threading
from datetime import datetime
from queue import Empty, Queue
from typing import Optional

import customtkinter as ctk

from hm10 import build_payload, parse_ident, scan_hm10, send_payload

# Палитра STOWN (дублируется локально, как в ble_gateway, чтобы не плодить импорты).
BG = "#0B1426"
SURFACE = "#142136"
SURFACE_HI = "#1B2A44"
PRIMARY = "#2D8CFF"
PRIMARY_HOVER = "#1565DD"
DANGER = "#E74C5C"
SUCCESS = "#22C55E"
WARNING = "#FFB74D"
ON_SURFACE = "#E7ECF4"
MUTED = "#8FA0BA"
DIVIDER = "#243450"

NO_DEVICE = "— сначала нажми «Найти HM10» —"


def _explain_error(e: Exception) -> str:
    """Человеческое описание ошибки + подсказка (str(e) у части исключений пуст)."""
    name = type(e).__name__
    s = str(e).strip()
    base = f"{name}: {s}" if s else name
    low = f"{name} {s}".lower()
    if "notfound" in low or "not found" in low or "not be found" in low:
        hint = (" — по адресу никто не отвечает в эфире. Убедись, что модуль запитан "
                "и телефон отключён от него.")
    elif "timeout" in low or name == "TimeoutError":
        hint = (" — подключение не завершилось. Останови «Сканер» в этом приложении, "
                "отключи телефон от модуля и выключи/включи Bluetooth на ПК.")
    elif "characteristic" in low or "ffe1" in low or "service" in low:
        hint = " — нет сервиса/характеристики FFE1: подключились не к тому устройству."
    else:
        hint = ""
    return base + hint


class LockPanel(ctk.CTkFrame):
    def __init__(self, master):
        super().__init__(master, fg_color="transparent")
        self._queue: "Queue[tuple]" = Queue()
        self._busy = False
        self._dev_map: dict[str, str] = {}  # label -> address

        self._build_ui()
        self._update_preview()
        self._poll()

    # ------------------------------------------------------------------ UI

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
            text="Готов",
            text_color=ON_SURFACE,
            font=ctk.CTkFont(size=15, weight="bold"),
        )
        self._status_label.pack(side="left")

        scroll = ctk.CTkScrollableFrame(self, fg_color=BG)
        scroll.pack(fill="both", expand=True, padx=0, pady=(0, 12))

        # --- Карточка: устройство HM10 ---
        dev_card = ctk.CTkFrame(scroll, fg_color=SURFACE, corner_radius=14)
        dev_card.pack(fill="x", padx=8, pady=6)
        self._section(dev_card, "УСТРОЙСТВО HM10")

        self._scan_btn = ctk.CTkButton(
            dev_card,
            text="🔍  Найти HM10",
            height=40,
            corner_radius=10,
            fg_color=SURFACE_HI,
            hover_color=DIVIDER,
            text_color=PRIMARY,
            border_width=1,
            border_color=DIVIDER,
            font=ctk.CTkFont(size=13, weight="bold"),
            command=self._start_scan,
        )
        self._scan_btn.pack(fill="x", padx=14, pady=(0, 8))

        self._device_menu = ctk.CTkOptionMenu(
            dev_card,
            values=[NO_DEVICE],
            fg_color=BG,
            button_color=SURFACE_HI,
            button_hover_color=DIVIDER,
            text_color=ON_SURFACE,
            font=ctk.CTkFont(family="Consolas", size=12),
            dropdown_fg_color=SURFACE,
            dropdown_text_color=ON_SURFACE,
        )
        self._device_menu.set(NO_DEVICE)
        self._device_menu.pack(fill="x", padx=14, pady=(0, 8))

        self._mac_target = self._labelled(
            dev_card,
            "MAC HM10 вручную (если скан не нашёл)",
            "напр. AA:BB:CC:DD:EE:FF — приоритетнее списка выше",
        )

        # --- Карточка: пакет ---
        cmd_card = ctk.CTkFrame(scroll, fg_color=SURFACE, corner_radius=14)
        cmd_card.pack(fill="x", padx=8, pady=6)
        self._section(cmd_card, "ПАКЕТ (10 БАЙТ)")

        row = ctk.CTkFrame(cmd_card, fg_color="transparent")
        row.pack(fill="x", padx=14, pady=(0, 6))
        self._cmd_entry = self._labelled(
            row, "Команда (hex)", "обычно 87 или 01", initial="87", side="left"
        )
        self._lock_entry = self._labelled(
            row, "Номер замка (hex)", "напр. 7702", initial="7702", side="left"
        )
        self._ident_entry = self._labelled(
            cmd_card,
            "Идентификатор / MAC (байты 2–8, опц.)",
            "MAC авторизованного устройства, 6 байт. Незанятое = 00. "
            "Полный UUID (16 байт) сюда НЕ влезает — максимум 7 байт.",
        )

        for e in (self._cmd_entry, self._lock_entry, self._ident_entry):
            e.bind("<KeyRelease>", self._update_preview)

        prev_box = ctk.CTkFrame(cmd_card, fg_color=BG, corner_radius=10)
        prev_box.pack(fill="x", padx=14, pady=(4, 14))
        ctk.CTkLabel(
            prev_box,
            text="ПАКЕТ К ОТПРАВКЕ",
            text_color=MUTED,
            font=ctk.CTkFont(size=10, weight="bold"),
            anchor="w",
        ).pack(fill="x", padx=12, pady=(8, 2))
        self._preview = ctk.CTkLabel(
            prev_box,
            text="",
            text_color=ON_SURFACE,
            font=ctk.CTkFont(family="Consolas", size=16, weight="bold"),
            anchor="w",
        )
        self._preview.pack(fill="x", padx=12, pady=(0, 10))

        # --- Карточка: лог ---
        log_card = ctk.CTkFrame(scroll, fg_color=SURFACE, corner_radius=14)
        log_card.pack(fill="both", expand=True, padx=8, pady=6)
        self._section(log_card, "ЖУРНАЛ")
        self._log = ctk.CTkTextbox(
            log_card,
            fg_color=BG,
            text_color=ON_SURFACE,
            font=ctk.CTkFont(family="Consolas", size=12),
            height=180,
            wrap="word",
        )
        self._log.pack(fill="both", expand=True, padx=14, pady=(0, 14))
        self._log.configure(state="disabled")

        # --- Кнопка отправки ---
        self._send_btn = ctk.CTkButton(
            self,
            text="🔓  Открыть замок",
            height=50,
            corner_radius=12,
            fg_color=PRIMARY,
            hover_color=PRIMARY_HOVER,
            text_color="white",
            font=ctk.CTkFont(size=15, weight="bold"),
            command=self._start_send,
        )
        self._send_btn.pack(fill="x", padx=4, pady=(0, 4))

    def _section(self, parent, text: str) -> None:
        ctk.CTkLabel(
            parent,
            text=text,
            text_color=MUTED,
            font=ctk.CTkFont(size=12, weight="bold"),
            anchor="w",
        ).pack(fill="x", padx=14, pady=(12, 6))

    def _labelled(
        self,
        parent,
        label: str,
        hint: str = "",
        initial: str = "",
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
            font=ctk.CTkFont(family="Consolas", size=13),
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
                wraplength=460,
                justify="left",
            ).pack(fill="x", padx=2, pady=(2, 0))
        return entry

    # ------------------------------------------------------------ payload

    def _current_payload(self) -> bytes:
        """Собирает пакет из полей. Бросает ValueError с понятным текстом."""
        cmd = self._parse_hex(self._cmd_entry.get(), "Команда", 0xFF)
        lock_id = self._parse_hex(self._lock_entry.get(), "Номер замка", 0xFFFF)
        ident = parse_ident(self._ident_entry.get())
        return build_payload(lock_id, cmd=cmd, ident=ident)

    def _parse_hex(self, s: str, field: str, max_val: int) -> int:
        s = s.strip().lower().replace("0x", "").replace(" ", "")
        if not s:
            raise ValueError(f"{field}: пусто")
        try:
            v = int(s, 16)
        except ValueError:
            raise ValueError(f"{field}: ожидался hex (напр. {'7702' if max_val > 0xFF else '87'})")
        if not 0 <= v <= max_val:
            raise ValueError(f"{field}: вне диапазона 0..{max_val:X}")
        return v

    def _update_preview(self, *_event) -> None:
        try:
            payload = self._current_payload()
            self._preview.configure(
                text=payload.hex(" ").upper(), text_color=ON_SURFACE
            )
        except ValueError as e:
            self._preview.configure(text=str(e), text_color=WARNING)

    def _target_address(self) -> Optional[str]:
        manual = self._mac_target.get().strip()
        if manual:
            return manual
        label = self._device_menu.get()
        return self._dev_map.get(label)

    # ------------------------------------------------------------ actions

    def _start_scan(self) -> None:
        if self._busy:
            return
        self._set_busy(True, "Поиск HM10…")
        self._emit("Скан 8 секунд…")

        def worker() -> None:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            try:
                devices = loop.run_until_complete(scan_hm10(timeout=8.0))
                self._queue.put(("devices", devices))
            except Exception as e:  # noqa: BLE001
                self._queue.put(("log", f"✕ Ошибка скана: {e}"))
            finally:
                loop.close()
                self._queue.put(("busy", False, "Готов"))

        threading.Thread(target=worker, daemon=True).start()

    def _start_send(self) -> None:
        if self._busy:
            return
        address = self._target_address()
        if not address:
            self._emit("✕ Сначала найди HM10 или впиши MAC вручную")
            return
        try:
            payload = self._current_payload()
        except ValueError as e:
            self._emit(f"✕ {e}")
            return

        self._set_busy(True, "Отправка…")

        def worker() -> None:
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            try:
                loop.run_until_complete(
                    send_payload(
                        address,
                        payload,
                        on_log=lambda m: self._queue.put(("log", m)),
                    )
                )
                self._queue.put(("log", "✓ Готово"))
            except Exception as e:  # noqa: BLE001
                self._queue.put(("log", f"✕ Ошибка отправки: {_explain_error(e)}"))
            finally:
                loop.close()
                self._queue.put(("busy", False, "Готов"))

        threading.Thread(target=worker, daemon=True).start()

    # ------------------------------------------------------------ queue/UI

    def _poll(self) -> None:
        try:
            while True:
                item = self._queue.get_nowait()
                kind = item[0]
                if kind == "log":
                    self._emit(item[1])
                elif kind == "devices":
                    self._populate_devices(item[1])
                elif kind == "busy":
                    self._set_busy(item[1], item[2])
        except Empty:
            pass
        self.after(150, self._poll)

    def _populate_devices(self, devices: list[tuple[str, str, int]]) -> None:
        if not devices:
            self._dev_map = {}
            self._device_menu.configure(values=[NO_DEVICE])
            self._device_menu.set(NO_DEVICE)
            self._emit("✕ HM10 не найден. Проверь питание модуля и Bluetooth.")
            return
        self._dev_map = {}
        labels: list[str] = []
        for name, addr, rssi in devices:
            label = f"{name}  ·  {addr}  ·  {rssi} dBm"
            labels.append(label)
            self._dev_map[label] = addr
        self._device_menu.configure(values=labels)
        self._device_menu.set(labels[0])
        first_name = (devices[0][0] or "").lower()
        if "hmsoft" in first_name:
            self._emit(f"✓ Найдено: {len(devices)}. HM10: {labels[0]}")
        else:
            self._emit(
                f"⚠ Найдено: {len(devices)}, но устройства с именем HMSoft нет. "
                "Возможно, это не HM10 — выбери нужное в списке или впиши MAC вручную."
            )

    def _set_busy(self, busy: bool, status: str) -> None:
        self._busy = busy
        state = "disabled" if busy else "normal"
        self._scan_btn.configure(state=state)
        self._send_btn.configure(state=state)
        self._status_dot.configure(fg_color=WARNING if busy else MUTED)
        self._status_label.configure(text=status)

    def _emit(self, msg: str) -> None:
        ts = datetime.now().strftime("%H:%M:%S")
        self._log.configure(state="normal")
        self._log.insert("end", f"{ts}  {msg}\n")
        self._log.see("end")
        self._log.configure(state="disabled")

    def shutdown(self) -> None:
        # Операции одноразовые (daemon-потоки) — отдельной остановки не нужно.
        pass
