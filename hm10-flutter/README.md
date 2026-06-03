# HM10 → замок (Flutter)

Реальная отправка 10 байт в HM10 (`HMSoft`) по BLE: приложение **подключается**
к модулю и пишет пакет в характеристику **FFE1** (сервис **FFE0**). Что записано
в FFE1 — вылетает в RS-485 и открывает замок. Ответ замка приходит обратно
через notify на FFE1.

> ⚠️ Это путь **connect-write** — стандартный для HM-10. Если выяснится, что в
> вашей архитектуре HM10/ESP вместо этого **слушает рекламу** метки, подход
> другой (метка просто вещает 10 байт, подключение не нужно). Проверить можно
> в одну кнопку: nRF Connect → connect к `HMSoft` → запись `87000000000000007702`
> в FFE1. Если замок открылся — connect-write верный.

## Файлы

| Файл | Что это |
|------|---------|
| `hm10_service.dart` | вся BLE-логика: `buildPayload`, `Hm10Service`, `openLockOnce` |
| `lock_send_page.dart` | готовый экран: скан → выбор HM10 → поля → «Открыть замок» |

Скопируйте оба файла в `lib/` своего проекта.

## Зависимости (`pubspec.yaml`)

```yaml
dependencies:
  flutter_blue_plus: ^1.32.0
  permission_handler: ^11.3.0
```

```bash
flutter pub get
```

## Android — права (`android/app/src/main/AndroidManifest.xml`)

Внутри `<manifest>`, до `<application>`:

```xml
<!-- Android 12+ (API 31+) -->
<uses-permission android:name="android.permission.BLUETOOTH_SCAN"
    android:usesPermissionFlags="neverForLocation" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />

<!-- Android 11 и ниже -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
```

`minSdkVersion` ≥ 21 (`android/app/build.gradle`). Для flutter_blue_plus обычно
требуется 21+.

## iOS — права (`ios/Runner/Info.plist`)

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Открытие замков по Bluetooth</string>
```

## Использование

Из любого места:

```dart
import 'lock_send_page.dart';

Navigator.push(
  context,
  MaterialPageRoute(builder: (_) => const LockSendPage()),
);
```

Или программно, без UI:

```dart
import 'hm10_service.dart';

// 1) найти HM10
final found = await Hm10Service.scan();          // List<ScanResult>
final device = found.first.device;

// 2) открыть замок 0x7702 (полный цикл connect→write→disconnect)
final reply = await openLockOnce(
  device,
  0x7702,
  cmd: 0x87,
  ident: parseIdent('AA:BB:CC:DD:EE:FF'),         // опц., в байты 2–8
);
print('Ответ замка: ${hexString(reply)}');
```

## Формат пакета (10 байт)

```
[0]      команда (0x87 / 0x01) — открытие, обычно не меняется
[1..7]   идентификатор (MAC, 6 байт), незанятое = 0x00
[8..9]   номер замка big-endian (0x7702 -> 77 02)
```

Пример: открыть замок `7702` без идентификатора → `87 00 00 00 00 00 00 00 77 02`.

⚠️ В байты 2–8 помещается **7 байт**: MAC (6 байт) — ок, **полный 128-битный UUID
(16 байт) НЕ влезает**. Для идентификации используйте MAC или короткий ID.

## Если не открывается

1. Запись прошла, замок молчит → почти всегда **бодрейт HM10** не совпал с
   RS-485 (дефолт 9600) или проводка RS-485 — это к человеку по железу.
2. `Сервис FFE0 не найден` → модуль не HM-10 / другая прошивка. Глянь UUID
   в nRF Connect.
3. Не находит при скане → включи питание модуля; на Android проверь, что выданы
   разрешения Bluetooth и включена геолокация (на Android ≤ 11).
4. HM10 — **одно подключение за раз**: пока кто-то подключён, второй не зайдёт.
