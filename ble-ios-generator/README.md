# BLE-генератор для iOS (Swift / SwiftUI)

Нативное iOS-приложение, которое вещает BLE-метку с **кастомным 128-битным
Service UUID** (+ локальное имя). Метка ловится сторонним приёмником: ESP32 /
Home Assistant, твоим Windows-сканером `ble_scanner.py`, любым BLE-сканером.

> Проект сделан «впрок»: исходники готовы, но собрать и запустить можно только
> на **Mac с Xcode + реальном iPhone**. См. раздел «Что нужно».

---

## ⚠️ Что iOS НЕ умеет (прочитай до начала)

Apple сознательно ограничила вещание. Через публичный `CoreBluetooth` при
рекламе можно задать **только два поля**:

| Можно                                   | Нельзя                              |
|-----------------------------------------|-------------------------------------|
| `CBAdvertisementDataLocalNameKey`       | Manufacturer Data → **нет iBeacon** |
| `CBAdvertisementDataServiceUUIDsKey`    | Service Data → **нет Eddystone**    |

Поэтому:

- **iBeacon вещать с iPhone нельзя** (это manufacturer data `0x004C`).
- **Eddystone (URL/UID/TLM) нельзя** (это service data `0xFEAA`).
- Доступна только идентификация по **Service UUID** — это и делает приложение.

Дополнительно:

- **Симулятор iOS не имеет Bluetooth** — вещать можно только на реальном iPhone.
- **Фон**: когда приложение свёрнуто, Service UUID уходит в «overflow area» и
  виден только Apple-устройствам. Для ESP32 / HA / Windows это бесполезно —
  **держи приложение на переднем плане** (экран включён, приложение открыто).
- **MAC рандомизируется**: iOS периодически меняет BLE-адрес. Идентифицируй
  метку **по Service UUID**, а не по адресу.

---

## Состав

```
ble-ios-generator/
├── README.md                       ← этот файл
└── BLEGenerator/
    ├── BLEGeneratorApp.swift       ← точка входа (@main)
    ├── ContentView.swift           ← интерфейс (поля, кнопка, статус)
    ├── BeaconAdvertiser.swift      ← логика вещания (CBPeripheralManager)
    └── Info.plist                  ← справочный, см. «Шаг 3»
```

---

## Что нужно

- **macOS** + **Xcode 15** или новее.
- **Реальный iPhone**, iOS 16+ (минимальная версия из-за `NavigationStack` /
  `LabeledContent`; при желании легко опустить — см. «FAQ»).
- **Apple ID**. Бесплатного Personal Team хватает, чтобы запустить на своём
  устройстве (подпись на 7 дней). Платный аккаунт ($99/год) нужен только для
  TestFlight / App Store.
- Кабель Lightning/USB-C для первого запуска (дальше можно по Wi-Fi).

---

## Сборка в Xcode (пошагово)

### Шаг 1. Создать проект
1. Xcode → **File ▸ New ▸ Project… ▸ iOS ▸ App**.
2. Product Name: `BLEGenerator`, Interface: **SwiftUI**, Language: **Swift**.
3. Сними галочки Core Data / Tests (не нужны).

### Шаг 2. Подключить исходники
Xcode создаст свои `BLEGeneratorApp.swift` и `ContentView.swift`. Замени их
содержимое файлами из папки `BLEGenerator/`, а `BeaconAdvertiser.swift` добавь
в проект (перетащи в навигатор, отметь **Copy items if needed** и галочку
таргета `BLEGenerator`).

### Шаг 3. Ключи Info (обязательно!)
Открой таргет `BLEGenerator` → вкладка **Info** → секция *Custom iOS Target
Properties* → добавь строку:

- **Privacy - Bluetooth Always Usage Description**
  (`NSBluetoothAlwaysUsageDescription`)
  значение, например: `Bluetooth используется для вещания BLE-метки.`

> Без этого ключа приложение **падает** при запуске (на iOS 13+ это требование
> для любого доступа к Bluetooth).

Необязательно — для фонового вещания (помни про ограничение overflow выше):
- **Required background modes** → добавь item
  **App shares data using CoreBluetooth** (`bluetooth-peripheral`).

> Альтернатива: использовать готовый `BLEGenerator/Info.plist` как собственный
> Info.plist (Build Settings → Packaging → *Info.plist File* + выключить
> *Generate Info.plist File*). Способ через вкладку Info проще.

### Шаг 4. Подпись
Таргет → **Signing & Capabilities** → **Automatically manage signing** →
выбери свой **Team** (Apple ID). Если нужно — поменяй Bundle Identifier на
уникальный (например, `com.tvoyimya.blegenerator`).

### Шаг 5. Запуск
1. Подключи iPhone, выбери его в списке устройств вверху Xcode.
2. На iPhone: **Настройки ▸ Конфиденциальность ▸ Режим разработчика** → включить
   (iOS 16+), перезагрузить телефон.
3. Нажми **Run (⌘R)**. При первом запуске на телефоне:
   **Настройки ▸ Основные ▸ VPN и управление устройством** → доверять своему
   профилю разработчика.
4. В приложении разреши доступ к Bluetooth, нажми **Начать вещание**.

---

## Как проверить, что метка вещает

> Полный пошаговый чеклист с тест-кейсами и критерием приёмки —
> в [`TESTING.md`](TESTING.md). Ниже — краткая версия.

### Твой Windows-сканер
Запусти `ble-scanner/ble_scanner.py` рядом. Метка появится строкой
**`Generic`**, в колонке *Параметры* будет `Services=<твой-UUID>`.
(iBeacon/Eddystone там не будет — это ожидаемо, см. ограничения.)

### Home Assistant (цель проекта)
Голый Service UUID HA из коробки не превращает в сенсор, но присутствие метки
удобно ловить через **ESPHome** на ESP32 по `service_uuid`:

```yaml
esp32_ble_tracker:

binary_sensor:
  - platform: ble_presence
    service_uuid: 'XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX'  # ← UUID из приложения
    name: "iPhone BLE Tag"
```

ESP32 с этой прошивкой работает и как Bluetooth-прокси для HA. Ловить по
`service_uuid`, а не по MAC — правильно, потому что iOS рандомизирует адрес.

---

## FAQ / устранение проблем

**Приложение падает сразу при запуске.**
Не добавлен `NSBluetoothAlwaysUsageDescription` (Шаг 3).

**Статус «BLE-вещание недоступно».**
Запущено на симуляторе — нужен реальный iPhone.

**Сканер видит метку, только пока приложение открыто.**
Так и есть: в фоне UUID уходит в overflow-область (см. ограничения). Для
постоянной метки используй ESP32/ESPHome — это надёжнее iPhone.

**Хочу поддержать iOS 15.**
Замени `NavigationStack` на `NavigationView` и `LabeledContent` на обычный
`HStack { Text(...); Spacer(); Text(...) }` в `ContentView.swift`.

**Нужен именно iBeacon/Eddystone.**
С iPhone — невозможно. Бери ESP32 + ESPHome (умеет любой формат) или Android.

---

## Лицензия
Учебный проект, используй как угодно.
