"""HA-mock — лёгкий имитатор Home Assistant с анимированным шлагбаумом.

Принимает webhook на /api/webhook/<webhook_id> (как настоящий HA), обновляет
дашборд через WebSocket. Используется для демо BLE-Gateway pipeline'а.

Запуск:
    pip install -r requirements.txt
    python server.py
    # дашборд: http://localhost:8123
    # webhook: POST http://<your-ip>:8123/api/webhook/gate_open

В Flutter-приложении на вкладке «Шлюз» поставьте:
    HA URL: http://<IP вашего ноута>:8123
    Webhook ID: gate_open
"""
from __future__ import annotations

import asyncio
import json
import sys
from collections import deque
from datetime import datetime
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, HTMLResponse
from fastapi.staticfiles import StaticFiles

# --------------------------------------------------------------------------- #
# State
# --------------------------------------------------------------------------- #

STATIC_DIR = Path(__file__).parent / "static"
HOST = "0.0.0.0"
PORT = 8123  # как у настоящего HA
GATE_OPEN_DURATION_SECONDS = 5
MAX_EVENTS = 50


class HubState:
    def __init__(self) -> None:
        self.events: deque[dict[str, Any]] = deque(maxlen=MAX_EVENTS)
        self.opens_today = 0
        self.last_vehicle: str | None = None
        self.last_rssi: int | None = None
        self.last_open_at: datetime | None = None
        self.gate_state = "closed"  # closed / opening / open / closing
        self.clients: set[WebSocket] = set()

    def snapshot(self) -> dict[str, Any]:
        return {
            "gate_state": self.gate_state,
            "opens_today": self.opens_today,
            "last_vehicle": self.last_vehicle,
            "last_rssi": self.last_rssi,
            "last_open_at": (
                self.last_open_at.isoformat() if self.last_open_at else None
            ),
            "events": list(self.events),
        }

    async def broadcast(self, message: dict[str, Any]) -> None:
        dead = []
        for ws in self.clients:
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(ws)
        for d in dead:
            self.clients.discard(d)

    def add_event(self, level: str, text: str) -> dict[str, Any]:
        ev = {
            "ts": datetime.now().strftime("%H:%M:%S"),
            "level": level,
            "text": text,
        }
        self.events.appendleft(ev)
        return ev


state = HubState()


# --------------------------------------------------------------------------- #
# App
# --------------------------------------------------------------------------- #

app = FastAPI(title="HA Mock — Шлагбаум")

# статика для дашборда
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")


@app.get("/", response_class=HTMLResponse)
async def index() -> HTMLResponse:
    return HTMLResponse((STATIC_DIR / "index.html").read_text(encoding="utf-8"))


@app.post("/api/webhook/{webhook_id}")
async def webhook(webhook_id: str, request: Request) -> JSONResponse:
    """Принимает webhook от Flutter-Gateway. Контракт совпадает с HA."""
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {"raw": str(payload)}

    vehicle = str(payload.get("vehicle", "?"))
    rssi = payload.get("rssi")
    major = payload.get("major")
    minor = payload.get("minor")

    if webhook_id != "gate_open":
        ev = state.add_event(
            "warning",
            f"Webhook '{webhook_id}' не настроен (используется только 'gate_open')",
        )
        await state.broadcast({"type": "event", "event": ev})
        return JSONResponse({"status": "unknown_webhook"}, status_code=404)

    state.opens_today += 1
    state.last_vehicle = vehicle
    state.last_rssi = rssi if isinstance(rssi, int) else None
    state.last_open_at = datetime.now()
    rssi_str = f"{rssi} dBm" if rssi is not None else "—"
    extra = (
        f" (Major={major}{' Minor=' + str(minor) if minor is not None else ''})"
        if major is not None
        else ""
    )
    ev = state.add_event("success", f"Открыто: {vehicle} · {rssi_str}{extra}")

    # анимация: closed → opening → open → closing → closed
    await state.broadcast({"type": "event", "event": ev})
    await state.broadcast({"type": "snapshot", "snapshot": state.snapshot()})
    await _animate_gate_cycle()

    return JSONResponse(
        {"status": "ok", "vehicle": vehicle, "opens_today": state.opens_today}
    )


async def _animate_gate_cycle() -> None:
    """closed → opening → open (5s) → closing → closed."""
    state.gate_state = "opening"
    await state.broadcast({"type": "gate", "state": "opening"})
    await asyncio.sleep(1.5)

    state.gate_state = "open"
    await state.broadcast({"type": "gate", "state": "open"})
    await asyncio.sleep(GATE_OPEN_DURATION_SECONDS)

    state.gate_state = "closing"
    await state.broadcast({"type": "gate", "state": "closing"})
    await asyncio.sleep(1.5)

    state.gate_state = "closed"
    await state.broadcast({"type": "gate", "state": "closed"})


@app.post("/api/test/open")
async def manual_open() -> JSONResponse:
    """Ручное открытие из дашборда — для отладки без BLE."""
    state.opens_today += 1
    state.last_vehicle = "ручной тест"
    state.last_rssi = None
    state.last_open_at = datetime.now()
    ev = state.add_event("info", "Открыто вручную из дашборда")
    await state.broadcast({"type": "event", "event": ev})
    await state.broadcast({"type": "snapshot", "snapshot": state.snapshot()})
    await _animate_gate_cycle()
    return JSONResponse({"status": "ok"})


@app.post("/api/test/reset")
async def reset() -> JSONResponse:
    state.events.clear()
    state.opens_today = 0
    state.last_vehicle = None
    state.last_rssi = None
    state.last_open_at = None
    state.gate_state = "closed"
    await state.broadcast({"type": "snapshot", "snapshot": state.snapshot()})
    await state.broadcast({"type": "gate", "state": "closed"})
    return JSONResponse({"status": "ok"})


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await websocket.accept()
    state.clients.add(websocket)
    try:
        await websocket.send_json(
            {"type": "snapshot", "snapshot": state.snapshot()}
        )
        await websocket.send_json({"type": "gate", "state": state.gate_state})
        while True:
            # держим соединение, клиент может слать ping
            msg = await websocket.receive_text()
            if msg == "ping":
                await websocket.send_text("pong")
    except WebSocketDisconnect:
        pass
    finally:
        state.clients.discard(websocket)


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #


def _local_ips() -> list[str]:
    """Получить локальные IPv4-адреса для удобной подсказки в логах."""
    import socket
    ips = []
    try:
        host = socket.gethostname()
        for info in socket.getaddrinfo(host, None, socket.AF_INET):
            ip = info[4][0]
            if ip and ip not in ips and not ip.startswith("127."):
                ips.append(ip)
    except Exception:
        pass
    return ips


def main() -> None:
    # Windows-консоль по умолчанию в cp1251 — заставим её принимать UTF-8.
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except Exception:
        pass

    try:
        import uvicorn
    except ImportError:
        print(
            "Установите зависимости: pip install -r requirements.txt",
            file=sys.stderr,
        )
        sys.exit(1)

    ips = _local_ips()
    print()
    print("=" * 60)
    print(" HA Mock — Дашборд шлагбаума")
    print("=" * 60)
    print(f"  Дашборд:       http://localhost:{PORT}")
    if ips:
        print(f"  С телефона:    http://{ips[0]}:{PORT}")
        print(f"  Webhook URL:   http://{ips[0]}:{PORT}/api/webhook/gate_open")
    else:
        print(f"  Webhook URL:   http://<your-ip>:{PORT}/api/webhook/gate_open")
    print()
    print("  В Flutter-приложении → «Шлюз»:")
    if ips:
        print(f"    HA URL:       http://{ips[0]}:{PORT}")
    else:
        print(f"    HA URL:       http://<your-ip>:{PORT}")
    print(f"    Webhook ID:   gate_open")
    print("=" * 60)
    print()
    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")


if __name__ == "__main__":
    main()
