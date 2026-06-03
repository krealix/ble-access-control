# BLE Access Control (ВКР)

Система контроля удалённого доступа на основе **анализа траектории изменения
сигнала BLE-меток** (магистерская диссертация).

## Состав
- `ble-scanner/` — Python: сканер и генератор BLE-меток, **анализатор траектории**
  (`trajectory.py`), шлюз доступа, модуль управления HM10 (`hm10.py`).
- `hm10_lock/` — Flutter-приложение (Android): отправка команды открытия на BLE-модуль
  HM10 + виртуальная база замков для тестов.
- `hm10-flutter/` — отдельные Dart-файлы сервиса HM10 (для вставки в другой проект).
- `ble-ios-generator/` — iOS-генератор BLE-метки.
- `ha-mock/` — мок Home Assistant для тестов шлюза.
- `diploma/` — пояснительная записка (`ВКР.md`) и статус работы (`PROGRESS.md`).

## Продолжение работы на другом компьютере
1. `git clone <repo>` и открыть папку.
2. В Claude Code сказать: **«Продолжаем ВКР, прочитай diploma/PROGRESS.md»**.
3. Python: создать venv и `pip install -r ble-scanner/requirements.txt` + `pip install matplotlib`.
4. Flutter: в `hm10_lock/` выполнить `flutter pub get`.

## Демонстрация ядра
```
cd ble-scanner
python trajectory.py        # симуляция прохода метки → график trajectory_demo.png
```
