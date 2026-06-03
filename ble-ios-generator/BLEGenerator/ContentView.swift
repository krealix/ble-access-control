import SwiftUI

struct ContentView: View {
    @StateObject private var advertiser = BeaconAdvertiser()
    @State private var uuidString: String = UUID().uuidString
    @State private var name: String = "HA-Tag"

    private var isAdvertising: Bool { advertiser.status == .advertising }

    /// Кнопку имеет смысл нажимать, только когда BLE готов или уже вещает.
    private var buttonEnabled: Bool {
        advertiser.status == .ready || advertiser.status == .advertising
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Параметры метки") {
                    HStack {
                        TextField("Service UUID", text: $uuidString)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                            .disabled(isAdvertising)
                        Button {
                            uuidString = UUID().uuidString
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isAdvertising)
                    }
                    TextField("Имя (Local Name)", text: $name)
                        .disabled(isAdvertising)
                }

                Section("Статус") {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 10, height: 10)
                        Text(advertiser.status.humanReadable)
                    }
                    if isAdvertising, let uuid = advertiser.currentUUID {
                        LabeledContent("UUID") {
                            Text(uuid).font(.system(.caption, design: .monospaced))
                        }
                    }
                    if let err = advertiser.lastError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(action: toggle) {
                        Text(isAdvertising ? "Остановить" : "Начать вещание")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!buttonEnabled)
                }

                Section {
                    Text("""
                    iOS вещает только Local Name + Service UUID — iBeacon и Eddystone \
                    с iPhone недоступны. В фоне UUID уходит в overflow-область и виден \
                    только Apple-устройствам, поэтому для стороннего приёмника (ESP32 / \
                    Home Assistant / Windows-сканер) держите приложение на переднем плане.
                    """)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("BLE-генератор")
        }
    }

    private var statusColor: Color {
        switch advertiser.status {
        case .advertising:
            return .green
        case .ready:
            return .blue
        case .poweredOff, .unauthorized, .unsupported:
            return .red
        case .unknown:
            return .gray
        }
    }

    private func toggle() {
        if isAdvertising {
            advertiser.stop()
        } else {
            advertiser.start(uuidString: uuidString, name: name)
        }
    }
}

#Preview {
    ContentView()
}
