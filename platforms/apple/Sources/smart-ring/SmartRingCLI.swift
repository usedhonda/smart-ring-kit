import Foundation
import SmartRingKit
#if canImport(Darwin)
import Darwin
#endif

@main
struct SmartRingCLI {
    private struct StressInputRequest: Decodable {
        let histories: [RingDecodedHistory]
        let at: Date
        let timeZone: String
        let maximumAgeSeconds: Double
        let referenceWindow: DateInterval?
        let sleepWindow: DateInterval?
        let sleepProfile: String?
    }
    @MainActor static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    @MainActor private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args == ["--help"] {
            print("""
            smart-ring scan
            smart-ring info --id <peripheral-uuid>
            smart-ring history --id <peripheral-uuid>
            smart-ring sleep --id <peripheral-uuid>
            smart-ring raw-<kind> --id <peripheral-uuid>
            smart-ring all --id <peripheral-uuid>
            smart-ring capture --id <peripheral-uuid> --output <directory>
            smart-ring decode-history <hex-packets-file>
            smart-ring decode-sleep <hex-packets-file>
            smart-ring decode-raw <raw-history.json>
            smart-ring analyze-stress-inputs <request.json>
            smart-ring analyze-sleep <raw-history.json> --time-zone <identifier> --profile issin-0.7.5.0

            Raw kinds: sleep, heart-rate, temperature, oxygen, activity, daily-activity.
                       spot-heart-rate, manual-oxygen, exercise.

            scan runs for 8 seconds. History prints sensitive health data as JSON.
            decode-history reads one hex notification per line, without Bluetooth.
            Bluetooth commands require macOS and Bluetooth permission. See README.
            """)
            return
        }
        if args.count == 2, args[0] == "analyze-stress-inputs" {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let request = try decoder.decode(StressInputRequest.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            guard let zone = TimeZone(identifier: request.timeZone),
                  request.sleepProfile == nil || request.sleepProfile == "issin-0.7.5.0" else {
                throw RingError.invalidPacket("unknown stress-input time zone or sleep profile")
            }
            try output(RingStressInputs.assemble(request.histories, at: request.at, timeZone: zone,
                maximumAge: request.maximumAgeSeconds, referenceWindow: request.referenceWindow,
                sleepWindow: request.sleepWindow,
                sleepMapping: request.sleepProfile == nil ? nil : .issinFirmware0750))
            return
        }
        if args.count == 2, args[0] == "decode-raw" {
            let raw = try JSONDecoder().decode(RingRawHistory.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            try output(RingHistoryCodec.decode(raw))
            return
        }
        if args.count == 6, args[0] == "analyze-sleep", args[2] == "--time-zone", args[4] == "--profile",
           args[5] == "issin-0.7.5.0", let zone = TimeZone(identifier: args[3]) {
            let raw = try JSONDecoder().decode(RingRawHistory.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            guard raw.command == RingReadCommand.sleepHistory.rawValue else { throw RingError.invalidPacket("expected sleep history") }
            var parser = RingSleepHistoryDecoder()
            for bytes in raw.notifications { try parser.append(Data(bytes)) }
            guard parser.isComplete else { throw RingError.invalidPacket("sleep input has no transfer terminator") }
            try output(RingSleepAnalyzer.analyze(parser.records, timeZone: zone, mapping: .issinFirmware0750))
            return
        }
        if args.count == 2, ["decode-history", "decode-sleep"].contains(args[0]) {
            let text = try String(contentsOfFile: args[1], encoding: .utf8)
            var decoder = RingHistoryDecoder()
            var sleepDecoder = RingSleepHistoryDecoder()
            for line in text.split(whereSeparator: \.isNewline) {
                let hex = line.filter { !$0.isWhitespace }
                guard !hex.isEmpty, hex.count.isMultiple(of: 2) else {
                    throw RingError.invalidPacket("hex line must contain pairs of digits")
                }
                var bytes: [UInt8] = []
                var index = hex.startIndex
                while index < hex.endIndex {
                    let end = hex.index(index, offsetBy: 2)
                    guard let byte = UInt8(hex[index..<end], radix: 16) else {
                        throw RingError.invalidPacket("non-hexadecimal byte")
                    }
                    bytes.append(byte)
                    index = end
                }
                if args[0] == "decode-sleep" { try sleepDecoder.append(Data(bytes)) }
                else { try decoder.append(Data(bytes)) }
            }
            if args[0] == "decode-sleep" {
                guard sleepDecoder.isComplete else { throw RingError.invalidPacket("missing sleep terminator") }
                try output(sleepDecoder.records)
            } else {
                guard decoder.isComplete else { throw RingError.invalidPacket("missing history terminator") }
                try output(decoder.records)
            }
            return
        }
        #if os(macOS)
        if args.count == 5, args[0] == "capture", args[1] == "--id", args[3] == "--output",
           let id = UUID(uuidString: args[2]) {
            let folder = URL(fileURLWithPath: args[4], isDirectory: true)
                .appendingPathComponent("ring-capture-\(UUID().uuidString.lowercased())", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            func save<T: Encodable>(_ value: T, _ name: String) throws {
                let data = try encoder().encode(value)
                let url = folder.appendingPathComponent(name)
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
            let snapshot = try await RingHistoryReader.readAll(from: id, onCapture: {
                try save($0, String(format: "history-%02x.json", $0.command.rawValue))
            })
            try save(snapshot, "snapshot.json")
            print(folder.path)
            return
        }
        if args == ["scan"] {
            let client = RingClient()
            defer { client.disconnect() }
            try output(await client.discover())
            return
        }
        let rawKinds: [String: RingReadCommand] = [
            "raw-sleep": .sleepHistory, "raw-heart-rate": .heartRateHistory,
            "raw-temperature": .temperatureHistory, "raw-oxygen": .oxygenHistory,
            "raw-activity": .activityHistory, "raw-daily-activity": .dailyActivityHistory,
            "raw-spot-heart-rate": .spotHeartRateHistory, "raw-manual-oxygen": .manualOxygenHistory,
            "raw-exercise": .exerciseHistory
        ]
        guard args.count == 3, ["info", "history", "sleep", "all"].contains(args[0]) || rawKinds[args[0]] != nil,
              args[1] == "--id", let id = UUID(uuidString: args[2]) else {
            throw RingError.invalidPacket("invalid arguments; run smart-ring --help")
        }
        if args[0] == "all" { try output(await RingHistoryReader.readAll(from: id)); return }
        let client = RingClient()
        defer { client.disconnect() }
        // Wait for Bluetooth initialization and include already system-connected devices.
        _ = try await client.discover(duration: 2)
        try await client.connect(to: id)
        if args[0] == "info" { try output(await client.readInfo()) }
        else if args[0] == "sleep" { try output(await client.readSleepHistory()) }
        else if let command = rawKinds[args[0]] { try output(await client.readRawHistory(command)) }
        else { try output(await client.readHRVHistory()) }
        #else
        throw RingError.transport("Bluetooth CLI commands require macOS; use RingClient in an iOS app")
        #endif
    }

    private static func output<T: Encodable>(_ value: T) throws {
        FileHandle.standardOutput.write(try encoder().encode(value))
        FileHandle.standardOutput.write(Data([0x0a]))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
