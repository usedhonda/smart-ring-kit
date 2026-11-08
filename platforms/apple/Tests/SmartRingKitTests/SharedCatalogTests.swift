import Foundation
import XCTest
@testable import SmartRingKit

final class SharedCatalogTests: XCTestCase {
    // Shared repository artifacts stay outside either platform's source tree.
    // SwiftPM tests run from a source checkout; these files are not runtime assets.
    private func shared(_ path: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appendingPathComponent(path))
    }

    func testExactFirmwareProfileMatchesSharedCatalogWithoutFutureVersionFallback() throws {
        struct Profile: Decodable {
            let formatVersion: Int
            let id: String
            let deviceID: String
            let firmware: String
            let protocolID: String
            let historyCommands: [UInt8]
            let sleepStages: [String: String]
            let unknownSleepCodes: [UInt8]
        }
        let catalog = try JSONDecoder().decode(Profile.self, from: shared(
            "devices/issin-smart-recovery-ring/firmware/0.7.5.0.json"))
        XCTAssertEqual(catalog.formatVersion, 1)
        let profile = try XCTUnwrap(RingDeviceProfiles.matching(deviceID: catalog.deviceID, firmware: catalog.firmware))
        XCTAssertEqual(profile.id, catalog.id)
        XCTAssertEqual(profile.protocolID, catalog.protocolID)
        XCTAssertEqual(RingReadCommand.historyCommands.map(\.rawValue), catalog.historyCommands)
        let mapping = try XCTUnwrap(profile.sleepMapping)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: mapping.values.map { (String($0.key), $0.value.rawValue) }), catalog.sleepStages)
        XCTAssertEqual(mapping.values, RingSleepStageMapping.issinFirmware0750.values)
        for unknown in catalog.unknownSleepCodes { XCTAssertNil(mapping.values[unknown]) }
        XCTAssertNil(RingDeviceProfiles.matching(deviceID: catalog.deviceID, firmware: "0.7.5.1"))
        XCTAssertNil(RingDeviceProfiles.matching(deviceID: "other-device", firmware: catalog.firmware))
    }

    func testSharedLanguageNeutralDecoderVectors() throws {
        struct Document: Decodable {
            struct Vector: Decodable {
                struct Expected: Decodable {
                    struct Measurement: Decodable { let name: String; let value: Double; let unit: String? }
                    let hrvCount: Int; let sleepCount: Int; let sensorCount: Int; let opaqueCount: Int; let issueCount: Int
                    let hrvRaw: UInt8?; let heartRateBPM: UInt8?; let stressRaw: UInt8?
                    let categoryValues: [UInt8]?; let sampleIntervalMinutes: Int?; let measurement: Measurement?
                }
                let id: String; let command: UInt8; let notifications: [[UInt8]]; let expected: Expected
            }
            let formatVersion: Int; let synthetic: Bool; let protocolID: String; let vectors: [Vector]
        }
        let document = try JSONDecoder().decode(Document.self, from: shared("protocols/fff0/fixtures/history-v1.json"))
        XCTAssertEqual(document.formatVersion, 1)
        XCTAssertTrue(document.synthetic)
        XCTAssertEqual(document.protocolID, "fff0")
        XCTAssertFalse(document.vectors.isEmpty)
        for vector in document.vectors {
            let decoded = RingHistoryCodec.decode(RingRawHistory(command: vector.command, notifications: vector.notifications))
            let expected = vector.expected
            XCTAssertEqual(decoded.hrv.count, expected.hrvCount, vector.id)
            XCTAssertEqual(decoded.sleep.count, expected.sleepCount, vector.id)
            XCTAssertEqual(decoded.sensors.count, expected.sensorCount, vector.id)
            XCTAssertEqual(decoded.opaqueRecords.count, expected.opaqueCount, vector.id)
            XCTAssertEqual(decoded.issues.count, expected.issueCount, vector.id)
            if let value = expected.hrvRaw { XCTAssertEqual(decoded.hrv.first?.hrvRaw, value, vector.id) }
            if let value = expected.heartRateBPM { XCTAssertEqual(decoded.hrv.first?.heartRateBPM, value, vector.id) }
            if let value = expected.stressRaw { XCTAssertEqual(decoded.hrv.first?.stressRaw, value, vector.id) }
            if let values = expected.categoryValues { XCTAssertEqual(decoded.sleep.first?.categoryValues, values, vector.id) }
            if let interval = expected.sampleIntervalMinutes { XCTAssertEqual(decoded.sleep.first?.sampleIntervalMinutes, interval, vector.id) }
            if let measurement = expected.measurement {
                let actual = try XCTUnwrap(decoded.sensors.first?.measurements.first { $0.name == measurement.name })
                XCTAssertEqual(actual.value, measurement.value, accuracy: 0.0001, vector.id)
                XCTAssertEqual(actual.unit, measurement.unit, vector.id)
            }
        }
    }
}
