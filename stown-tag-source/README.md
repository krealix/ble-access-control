# Исходники STOWN-метки (генерация и вещание)

Это снимок файлов основного приложения `ble-beacon-app`, реализующих **генерацию
и BLE-вещание STOWN-метки** (вкладка «Метка»). Отдельное приложение «Метка» уже
собирается из основного проекта флейвором `tag`:

```bash
flutter build apk --release --flavor tag -t lib/main_tag.dart
```

Точка входа `lib/main_tag.dart` запускает только экран метки
(`StownScreen(standalone: true)`) — без сканера, шлюза и входа.

## Файлы и их роль

| Файл | Назначение |
|------|-----------|
| `lib/main_tag.dart` | Точка входа отдельного приложения «Метка». |
| `lib/models/stown_packet.dart` | Формат 10-байтного пакета: команда + 7-байтный идентификатор + номер замка; BCD-кодирование номера/IMEI, генерация Device ID, разбор пакета. |
| `lib/services/stown_advertiser.dart` | Вещание пакета через `flutter_ble_peripheral` в трёх обёртках (manufacturer / service / iBeacon); легаси-реклама, имя метки. |
| `lib/services/stown_storage.dart` | Сохранение конфигурации метки в `SharedPreferences`. |
| `lib/services/rolling_code.dart` | Динамический идентификатор (rolling-code, TOTP/HMAC-SHA256). |
| `lib/services/bt_info.dart` | Чтение/смена имени BT-адаптера (имя метки в эфире на Android). |
| `lib/screens/stown_screen.dart` | UI: ввод параметров, выбор обёртки/замка, запуск/остановка вещания. |
| `lib/theme.dart` | Тема оформления (общая с основным приложением). |
| `lib/widgets/common.dart` | Общие виджеты (карточки, кнопки). |

## Зависимости (pubspec)

`flutter_ble_peripheral`, `permission_handler`, `shared_preferences`, `crypto`.

## Примечания

- Это **снимок для чтения/переноса**, а не самостоятельный проект: для сборки
  как отдельного приложения нужны `pubspec.yaml`, папка `android/` (разрешения и
  BLE-peripheral) и т.д. — проще собирать флейвором `tag` из `ble-beacon-app`.
- `widgets/common.dart` в полном проекте подключает экран входа/`auth_service`
  (для функции выхода). В режиме `standalone: true` экран метки выход не вызывает.
