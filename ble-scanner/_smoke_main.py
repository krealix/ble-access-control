"""Smoke-тест: запускаем ble_scanner.main() на 6 секунд и завершаем.
Проверяет, что сканер стартует, рендерит таблицу, корректно останавливается.
"""
from __future__ import annotations

import asyncio

import ble_scanner


async def run() -> None:
    task = asyncio.create_task(ble_scanner.main())
    try:
        await asyncio.wait_for(task, timeout=6.0)
    except asyncio.TimeoutError:
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, KeyboardInterrupt):
            pass
    print("\n[smoke] main() корректно завершён по таймауту")


if __name__ == "__main__":
    asyncio.run(run())
