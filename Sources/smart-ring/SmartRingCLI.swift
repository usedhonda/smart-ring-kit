import Foundation
import SmartRingKit
#if canImport(Darwin)
import Darwin
#endif

@main
struct SmartRingCLI {
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
            smart-ring decode-history <hex-packets-file>
            smart-ring decode-sleep <hex-packets-file>

            Raw kinds: sleep, heart-rate, temperature, oxygen, activity, daily-activity.

            scan runs for 8 seconds. History prints sensitive health data as JSON.
            decode-history reads one hex notification per line, without Bluetooth.
            Bluetooth commands require macOS and Bluetooth permission. See README.
            """)
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
        let client = RingClient()
        defer { client.disconnect() }
        if args == ["scan"] {
            try output(await client.discover())
            return
        }
        let rawKinds: [String: RingReadCommand] = [
            "raw-sleep": .sleepHistory, "raw-heart-rate": .heartRateHistory,
            "raw-temperature": .temperatureHistory, "raw-oxygen": .oxygenHistory,
            "raw-activity": .activityHistory, "raw-daily-activity": .dailyActivityHistory
        ]
        guard args.count == 3, ["info", "history", "sleep"].contains(args[0]) || rawKinds[args[0]] != nil,
              args[1] == "--id", let id = UUID(uuidString: args[2]) else {
            throw RingError.invalidPacket("invalid arguments; run smart-ring --help")
        }
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
