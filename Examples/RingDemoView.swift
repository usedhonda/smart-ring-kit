import SwiftUI
import SmartRingKit

/// Add to an iOS app with NSBluetoothAlwaysUsageDescription in its Info.plist.
/// Use RingDemoView() as the app's root view. No background modes are required.
@MainActor
struct RingDemoView: View {
    @State private var client = RingClient()
    @State private var devices: [RingPeripheral] = []
    @State private var selected: RingPeripheral?
    @State private var status = "Tap Scan to find a ring."
    @State private var busy = false
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(status)
                    Button("Scan") { run {
                        devices = try await client.discover()
                        status = "Found \(devices.count) candidate(s). Select your ring."
                    } }.disabled(busy || selected != nil)
                }
                ForEach(devices) { device in
                    Button {
                        run {
                            try await client.connect(to: device.id)
                            selected = device
                            let info = try await client.readInfo()
                            status = "Firmware \(info.firmware), battery \(info.batteryPercent)%"
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(device.name ?? "Unnamed FFF0 peripheral")
                            Text(device.id.uuidString).font(.caption)
                            if device.connectedToSystem { Text("Already connected to iOS").font(.caption) }
                        }
                    }.disabled(busy || selected != nil)
                }
                if selected != nil {
                    Button("Read HRV history") { run {
                        let records = try await client.readHRVHistory()
                        status = "Read \(records.count) records."
                        if let last = records.last {
                            status += " Last: heart rate \(last.heartRateBPM) bpm, HRV raw \(last.hrvRaw), stress raw \(last.stressRaw)."
                        }
                    } }.disabled(busy)
                }
                Button("Disconnect / cancel", role: .destructive) {
                    operation?.cancel()
                    client.disconnect()
                    selected = nil
                    status = "Disconnected."
                }
            }
            .navigationTitle("SmartRingKit")
        }
        .onDisappear { operation?.cancel(); client.disconnect() }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        operation = Task { @MainActor in
            defer { busy = false }
            do { try await action() }
            catch { selected = nil; client.disconnect(); status = error.localizedDescription }
        }
    }
}
