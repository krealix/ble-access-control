import Foundation
import Combine
import CoreBluetooth

/// Обёртка над `CBPeripheralManager` для вещания BLE-метки.
///
/// ВАЖНОЕ ОГРАНИЧЕНИЕ iOS:
/// При вещании CoreBluetooth разрешает задать только два поля рекламы:
///   • `CBAdvertisementDataLocalNameKey`    — локальное имя
///   • `CBAdvertisementDataServiceUUIDsKey` — список Service UUID
/// Manufacturer Data и Service Data задать НЕЛЬЗЯ, поэтому iBeacon и
/// Eddystone с iPhone не вещаются. Эта метка идентифицируется приёмником
/// по кастомному Service UUID (+ имени).
///
/// queue: nil → делегатные коллбэки приходят на main-очередь, что удобно
/// для обновления @Published-свойств, читаемых из SwiftUI.
final class BeaconAdvertiser: NSObject, ObservableObject {

    enum Status: Equatable {
        case unknown
        case unsupported
        case unauthorized
        case poweredOff
        case ready
        case advertising

        var humanReadable: String {
            switch self {
            case .unknown:      return "Инициализация…"
            case .unsupported:  return "BLE-вещание недоступно (симулятор или старое устройство)"
            case .unauthorized: return "Нет доступа к Bluetooth — разрешите в Настройках"
            case .poweredOff:   return "Bluetooth выключен"
            case .ready:        return "Готов к вещанию"
            case .advertising:  return "Вещает"
            }
        }
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var lastError: String?
    @Published private(set) var currentUUID: String?
    @Published private(set) var currentName: String?

    private var manager: CBPeripheralManager!
    private var pendingUUID: CBUUID?
    private var pendingName: String?

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    var isAdvertising: Bool { status == .advertising }

    /// Запустить вещание. `uuidString` — строгий 128-битный UUID (например, из `UUID()`).
    /// Если Bluetooth ещё не включён, параметры запоминаются и вещание стартует,
    /// как только менеджер перейдёт в `.poweredOn`.
    func start(uuidString: String, name: String?) {
        guard let uuid = Self.makeUUID(from: uuidString) else {
            lastError = "Некорректный UUID: \(uuidString)"
            return
        }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = nil
        pendingUUID = uuid
        pendingName = (trimmedName?.isEmpty == false) ? trimmedName : nil

        guard manager.state == .poweredOn else { return }
        beginAdvertising()
    }

    func stop() {
        manager.stopAdvertising()
        pendingUUID = nil
        pendingName = nil
        currentUUID = nil
        currentName = nil
        if status == .advertising {
            status = .ready
        }
    }

    private func beginAdvertising() {
        guard let uuid = pendingUUID else { return }
        var data: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [uuid]
        ]
        if let name = pendingName {
            data[CBAdvertisementDataLocalNameKey] = name
        }
        manager.stopAdvertising()
        manager.startAdvertising(data)
        currentUUID = uuid.uuidString
        currentName = pendingName
        // Фактический переход в .advertising подтверждается в делегате
        // peripheralManagerDidStartAdvertising(_:error:).
    }

    /// Валидация/парсинг строки UUID. Принимаем строгий 128-битный UUID,
    /// чтобы метка не пересекалась с зарегистрированными 16-битными UUID.
    static func makeUUID(from string: String) -> CBUUID? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: trimmed) != nil else { return nil }
        return CBUUID(string: trimmed)
    }
}

extension BeaconAdvertiser: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            // Если "Старт" нажали до включения Bluetooth — стартуем сейчас.
            if pendingUUID != nil, status != .advertising {
                beginAdvertising()
            } else if status != .advertising {
                status = .ready
            }
        case .poweredOff:
            status = .poweredOff
        case .unauthorized:
            status = .unauthorized
        case .unsupported:
            status = .unsupported
        case .resetting, .unknown:
            status = .unknown
        @unknown default:
            status = .unknown
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error = error {
            lastError = error.localizedDescription
            status = .ready
        } else {
            status = .advertising
        }
    }
}
