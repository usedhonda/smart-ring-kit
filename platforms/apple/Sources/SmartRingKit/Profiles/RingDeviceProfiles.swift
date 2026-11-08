import Foundation

/// An evidence-backed interpretation for an exact device and firmware pair.
/// This metadata does not select a BLE driver or establish device identity.
public struct RingDeviceProfile: Sendable {
    public let id: String
    public let deviceID: String
    public let firmware: String
    public let protocolID: String
    public let sleepMapping: RingSleepStageMapping?
}

public enum RingDeviceProfiles {
    // Mirrored from devices/; the shared-catalog test prevents profile drift.
    // Do not broaden an exact firmware match to a numeric range without evidence.
    public static let issinSmartRecoveryRing0750 = RingDeviceProfile(
        id: "issin-smart-recovery-ring-0.7.5.0",
        deviceID: "issin-smart-recovery-ring", firmware: "0.7.5.0", protocolID: "fff0",
        sleepMapping: RingSleepStageMapping(
            name: "issin-0.7.5.0-observed", values: [1: .deep, 2: .light, 3: .rem, 5: .awake]
        )
    )

    /// Returns nil for an unknown device or firmware; never guesses compatibility
    /// from a service UUID, advertising name or a higher version number.
    public static func matching(deviceID: String, firmware: String) -> RingDeviceProfile? {
        let known = issinSmartRecoveryRing0750
        return known.deviceID == deviceID && known.firmware == firmware ? known : nil
    }
}
