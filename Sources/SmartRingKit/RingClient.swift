#if canImport(CoreBluetooth)
import Foundation
@preconcurrency import CoreBluetooth

public struct RingPeripheral: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String?
    public let rssi: Int?
    /// Already connected to the system; not proof this client is connected.
    public let connectedToSystem: Bool
}

/// A foreground, single-operation client for the verified FFF0 read subset.
/// Retain the client for the lifetime of the connection. Call from the main actor.
@MainActor
public final class RingClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private static let service = CBUUID(string: "FFF0")
    private static let writeID = CBUUID(string: "FFF6")
    private static let notifyID = CBUUID(string: "FFF7")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var seen: [UUID: CBPeripheral] = [:]
    private var candidates: [UUID: RingPeripheral] = [:]
    private var continuation: CheckedContinuation<Response, Error>?
    private var timer: Timer?
    private var operationID: UUID?
    private var phase: Phase = .idle
    private var history = RingHistoryDecoder()
    private var sleepHistory = RingSleepHistoryDecoder()
    private var rawHistory: RingRawHistoryDecoder?
    private var rawNotificationHandler: (@MainActor (Data) -> Void)?
    private var unexpectedNotificationHandler: (@MainActor (Data) -> Void)?
    private var continuationTimer: Timer?

    private enum Phase {
        case idle, discovery, connecting
        case request(RingReadCommand)
        case rawHistory(RingReadCommand)
    }
    private enum Response {
        case devices([RingPeripheral]), ready, packet(Data), history([RingHRVRecord])
        case sleep([RingSleepRecord]), raw(RingRawHistory)
    }

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// Includes system-connected FFF0 peripherals and advertising SRR-* candidates.
    /// A candidate name alone does not establish protocol compatibility.
    public func discover(duration: TimeInterval = 8) async throws -> [RingPeripheral] {
        guard peripheral == nil else { throw RingError.busy }
        guard case .devices(let devices) = try await perform(timeout: duration, phase: .discovery, start: {
            self.candidates.removeAll()
            self.beginDiscoveryIfReady()
        }) else { throw RingError.unsupportedDevice }
        return devices
    }

    public func connect(to id: UUID, timeout: TimeInterval = 15) async throws {
        guard peripheral == nil else { throw RingError.busy }
        guard central.state == .poweredOn else { throw RingError.bluetoothUnavailable }
        guard let target = seen[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            throw RingError.unsupportedDevice
        }
        _ = try await perform(timeout: timeout, phase: .connecting) {
            self.peripheral = target
            target.delegate = self
            self.central.connect(target)
        }
    }

    public func readInfo(timeout: TimeInterval = 10) async throws -> RingInfo {
        let version = try RingPacketDecoder.firmware(await request(.firmware, timeout: timeout))
        let battery = try RingPacketDecoder.battery(await request(.battery, timeout: timeout))
        return RingInfo(firmware: version, batteryPercent: battery)
    }

    public func readDeviceClock(timeout: TimeInterval = 10) async throws -> RingTimestamp {
        let data = try await request(.deviceClock, timeout: timeout)
        guard data.count >= 7 else { throw RingError.invalidPacket("device clock length") }
        return try RingPacketDecoder.timestamp(Array(data.dropFirst().prefix(6)))
    }

    /// Read all currently available HRV records. Never deletes or acknowledges deletion.
    /// Timeouts/errors disconnect the local client so a late response cannot pollute a retry.
    public func readHRVHistory(timeout: TimeInterval = 40, maxRecords: Int = 10_000) async throws -> [RingHRVRecord] {
        guard continuation == nil else { throw RingError.busy }
        guard maxRecords > 0 else { throw RingError.recordLimitExceeded }
        history = RingHistoryDecoder(maxRecords: maxRecords)
        guard case .history(let records) = try await send(.hrvHistory, timeout: timeout) else {
            throw RingError.invalidPacket("unexpected response")
        }
        return records
    }

    public func disconnect() {
        if continuation != nil { finish(.failure(RingError.cancelled)) }
        closeConnection()
    }

    /// Experimental SDK-defined sleep history, retaining unlabelled sleep categories.
    public func readSleepHistory(timeout: TimeInterval = 40, maxRecords: Int = 10_000) async throws -> [RingSleepRecord] {
        guard continuation == nil else { throw RingError.busy }
        guard maxRecords > 0 else { throw RingError.recordLimitExceeded }
        sleepHistory = RingSleepHistoryDecoder(maxRecords: maxRecords)
        guard case .sleep(let records) = try await send(.sleepHistory, timeout: timeout) else {
            throw RingError.invalidPacket("unexpected sleep response")
        }
        return records
    }

    /// Probe a supported read-only history command without inventing field semantics.
    /// Completes on the SDK-style command/0xff marker, with idle-aware read continuation.
    public func readRawHistory(_ command: RingReadCommand, timeout: TimeInterval = 40,
                               maxBytes: Int = 2_000_000,
                               onNotification: (@MainActor (Data) -> Void)? = nil,
                               onUnexpectedNotification: (@MainActor (Data) -> Void)? = nil) async throws -> RingRawHistory {
        guard continuation == nil else { throw RingError.busy }
        rawHistory = try RingRawHistoryDecoder(command: command, maxBytes: maxBytes)
        rawNotificationHandler = onNotification
        unexpectedNotificationHandler = onUnexpectedNotification
        defer { rawNotificationHandler = nil; unexpectedNotificationHandler = nil }
        guard case .raw(let result) = try await send(command, timeout: timeout, raw: true) else {
            throw RingError.invalidPacket("unexpected raw history response")
        }
        return result
    }

    private func request(_ command: RingReadCommand, timeout: TimeInterval) async throws -> Data {
        guard case .packet(let data) = try await send(command, timeout: timeout) else {
            throw RingError.invalidPacket("unexpected response")
        }
        return data
    }

    private func send(_ command: RingReadCommand, timeout: TimeInterval, raw: Bool = false) async throws -> Response {
        guard let p = peripheral, p.state == .connected, let tx = writeCharacteristic,
              notifyCharacteristic?.isNotifying == true else { throw RingError.disconnected }
        return try await perform(timeout: timeout, phase: raw ? .rawHistory(command) : .request(command)) {
            p.writeValue(command.packet, for: tx, type: .withResponse)
        }
    }

    private func perform(timeout: TimeInterval, phase: Phase, start: () -> Void) async throws -> Response {
        guard continuation == nil else { throw RingError.busy }
        guard timeout.isFinite, timeout > 0 else { throw RingError.timedOut }
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { callback in
                self.continuation = callback
                self.operationID = id
                self.phase = phase
                self.timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.operationID == id else { return }
                        if case .discovery = self.phase {
                            self.finish(.success(.devices(self.candidates.values.sorted { $0.id.uuidString < $1.id.uuidString })))
                        } else { self.fail(RingError.timedOut) }
                    }
                }
                start()
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                guard let self, self.operationID == id else { return }
                self.fail(RingError.cancelled)
            }
        })
    }

    private func beginDiscoveryIfReady() {
        guard case .discovery = phase else { return }
        switch central.state {
        case .poweredOn:
            for p in central.retrieveConnectedPeripherals(withServices: [Self.service]) {
                seen[p.identifier] = p
                candidates[p.identifier] = RingPeripheral(id: p.identifier, name: p.name, rssi: nil, connectedToSystem: true)
            }
            // Observed devices do not advertise the service UUID, so scan unfiltered.
            central.scanForPeripherals(withServices: nil)
        case .unknown, .resetting: break
        default: fail(RingError.bluetoothUnavailable)
        }
    }

    private func finish(_ result: Result<Response, Error>) {
        continuationTimer?.invalidate()
        continuationTimer = nil
        let callback = continuation
        continuation = nil
        operationID = nil
        timer?.invalidate()
        timer = nil
        phase = .idle
        central.stopScan()
        callback?.resume(with: result)
    }

    private func fail(_ error: Error) {
        finish(.failure(error))
        closeConnection()
    }

    private func closeConnection() {
        if let p = peripheral {
            p.delegate = nil
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if case .discovery = phase { beginDiscoveryIfReady() }
        else if central.state != .poweredOn, continuation != nil { fail(RingError.bluetoothUnavailable) }
        else if central.state != .poweredOn { closeConnection() }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard case .discovery = phase else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? p.name
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard name?.hasPrefix("SRR-") == true || services.contains(Self.service) else { return }
        seen[p.identifier] = p
        candidates[p.identifier] = RingPeripheral(id: p.identifier, name: name, rssi: RSSI.intValue,
                                                  connectedToSystem: p.state == .connected)
    }

    public func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral else { return }
        p.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        fail(error.map { RingError.transport($0.localizedDescription) } ?? .disconnected)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        fail(error.map { RingError.transport($0.localizedDescription) } ?? .disconnected)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        if let error { fail(RingError.transport(error.localizedDescription)); return }
        guard let service = p.services?.first(where: { $0.uuid == Self.service }) else {
            fail(RingError.unsupportedDevice); return
        }
        p.discoverCharacteristics([Self.writeID, Self.notifyID], for: service)
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral else { return }
        if let error { fail(RingError.transport(error.localizedDescription)); return }
        writeCharacteristic = service.characteristics?.first { $0.uuid == Self.writeID }
        notifyCharacteristic = service.characteristics?.first { $0.uuid == Self.notifyID }
        guard writeCharacteristic?.properties.contains(.write) == true,
              let rx = notifyCharacteristic, rx.properties.contains(.notify) else {
            fail(RingError.unsupportedDevice); return
        }
        p.setNotifyValue(true, for: rx)
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard p === peripheral, characteristic.uuid == Self.notifyID else { return }
        if let error { fail(RingError.transport(error.localizedDescription)); return }
        guard characteristic.isNotifying else { fail(RingError.unsupportedDevice); return }
        if case .connecting = phase { finish(.success(.ready)) }
    }

    public func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard p === peripheral else { return }
        if let error { fail(RingError.transport(error.localizedDescription)) }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard p === peripheral, characteristic.uuid == Self.notifyID else { return }
        if let error { fail(RingError.transport(error.localizedDescription)); return }
        guard let data = characteristic.value, !data.isEmpty else { return }
        if case .rawHistory(let command) = phase {
            guard data.first == command.rawValue else {
                unexpectedNotificationHandler?(data)
                if let byte = data.first, RingReadCommand(rawValue: byte)?.isHistory == true {
                    fail(RingError.conflictingHistoryResponse(expected: command.rawValue, received: byte))
                }
                return
            }
            continuationTimer?.invalidate()
            rawNotificationHandler?(data)
            do {
                guard rawHistory != nil else { throw RingError.invalidPacket("missing raw decoder") }
                try rawHistory?.append(data)
                if let decoder = rawHistory, decoder.isComplete { finish(.success(.raw(decoder.result))) }
                else { scheduleContinuation(command) }
            } catch { fail(error) }
            return
        }
        guard case .request(let command) = phase else { return }
        if data.first == command.rawValue { continuationTimer?.invalidate() }
        // Other clients may receive/write on the same peripheral. Ignore other response types.
        guard data.first == command.rawValue else {
            if command.isHistory, let byte = data.first, RingReadCommand(rawValue: byte)?.isHistory == true {
                fail(RingError.conflictingHistoryResponse(expected: command.rawValue, received: byte))
            }
            return
        }
        do {
            switch command {
            case .firmware:
                _ = try RingPacketDecoder.firmware(data)
                finish(.success(.packet(data)))
            case .battery:
                _ = try RingPacketDecoder.battery(data)
                finish(.success(.packet(data)))
            case .deviceClock:
                guard data.count >= 7 else { throw RingError.invalidPacket("device clock length") }
                _ = try RingPacketDecoder.timestamp(Array(data.dropFirst().prefix(6)))
                finish(.success(.packet(data)))
            case .hrvHistory:
                try history.append(data)
                if history.isComplete { finish(.success(.history(history.records))) }
                else { scheduleContinuation(command) }
            case .sleepHistory:
                try sleepHistory.append(data)
                if sleepHistory.isComplete { finish(.success(.sleep(sleepHistory.records))) }
                else { scheduleContinuation(command) }
            default:
                throw RingError.invalidPacket("additional history requires readRawHistory")
            }
        } catch { fail(error) }
    }

    private func scheduleContinuation(_ command: RingReadCommand) {
        guard let operationID else { return }
        // The sample uses 50 responses, but hardware may deliver 49 before stalling.
        // Continue only at an idle boundary, never count received packets as proof
        // that the ring sent the whole page. Any next packet invalidates this timer.
        continuationTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.operationID == operationID,
                      let p = self.peripheral, let tx = self.writeCharacteristic else { return }
                p.writeValue(command.readPacket(continuing: true), for: tx, type: .withResponse)
            }
        }
    }
}
#endif
