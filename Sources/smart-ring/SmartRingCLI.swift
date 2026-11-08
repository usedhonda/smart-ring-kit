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
            smart-ring decode-history <hex-packets-file>

            scan runs for 8 seconds. History prints sensitive health data as JSON.
            decode-history reads one hex notification per line, without Bluetooth.
            Bluetooth commands require macOS and Bluetooth permission. See README.
            """)
            return
        }
        if args.count == 2, args[0] == "decode-history" {
            let text = try String(contentsOfFile: args[1], encoding: .utf8)
            var decoder = RingHistoryDecoder()
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
                try decoder.append(Data(bytes))
            }
            guard decoder.isComplete else { throw RingError.invalidPacket("missing history terminator") }
            try output(decoder.records)
            return
        }
        #if os(macOS)
        let client = RingClient()
        defer { client.disconnect() }
        if args == ["scan"] {
            try output(await client.discover())
            return
        }
        guard args.count == 3, ["info", "history"].contains(args[0]),
              args[1] == "--id", let id = UUID(uuidString: args[2]) else {
            throw RingError.invalidPacket("invalid arguments; run smart-ring --help")
        }
        // Wait for Bluetooth initialization and include already system-connected devices.
        _ = try await client.discover(duration: 2)
        try await client.connect(to: id)
        if args[0] == "info" { try output(await client.readInfo()) }
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
