# BLE Access Control (ВКР)

Система контроля удалённого доступа на основе **анализа траектории изменения
сигнала BLE-меток** (магистерская диссертация).

## Состав
- `ble-beacon-app/` — **основное Flutter-приложение (Android)**: 4 вкладки — Сканер,
  Генератор, Шлюз (режимы «мёртвая зона»/«траектория», доступ по звонку, транспорты
  HTTP/TCP/HM10), Метка. Отдельный APK «Метка» — флейвор `tag`. APK — во вкладке Releases.
- `ble-scanner/` — Python: сканер и генератор BLE-меток, **анализатор траектории**
  (`trajectory.py`), шлюз доступа, модуль управления HM10 (`hm10.py`).
- `hm10_lock/` — ранний Flutter-прототип: отправка команды открытия на BLE-модуль
  HM10 + виртуальная база замков для тестов.
- `hm10-flutter/` — отдельные Dart-файлы сервиса HM10 (для вставки в другой проект).
- `ble-ios-generator/` — iOS-генератор BLE-метки.
- `ha-mock/` — мок Home Assistant + `tcp_listener.py` (приёмник 10-байтных пакетов для тестов шлюза).
- `diploma/` — пояснительная записка (`ВКР.md`), доклад, презентация и статус работы (`PROGRESS.md`).

## Продолжение работы на другом компьютере
1. `git clone https://github.com/krealix/ble-access-control.git` и открыть папку.
2. В Claude Code сказать: **«Продолжаем ВКР, прочитай diploma/PROGRESS.md»**.
3. Python: создать venv и `pip install -r ble-scanner/requirements.txt` + `pip install matplotlib`.
4. Flutter: в `ble-beacon-app/` выполнить `flutter pub get`; сборка:
   `flutter build apk --release --flavor full` (полное) и
   `flutter build apk --release --flavor tag -t lib/main_tag.dart` (только «Метка»).
   Для текста ВКР: `pip install python-docx python-pptx`, затем
   `python diploma/build_docx.py` и `python diploma/build_pptx.py`.

## Демонстрация ядра
```
cd ble-scanner
python trajectory.py        # симуляция прохода метки → график trajectory_demo.png
```
