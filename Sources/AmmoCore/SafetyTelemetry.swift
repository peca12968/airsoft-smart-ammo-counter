import Foundation

/// MCU die and VBAT-rail telemetry. Neither reading is cell temperature or a certified protection.
public struct SafetyTelemetry: Equatable {
    public enum Reason: UInt8 { case none, hot, lowVoltage, highVoltage, temperatureUnavailable, watchdog, voltageUnavailable }
    public let flags: UInt8
    public let millivolts: UInt16?
    public let quarterDegrees: Int16?
    public let usbPresent: Bool
    public let chargeActive: Bool?
    public let reason: Reason
    public let sample: UInt32
    public let boot: UInt32
    public var isWarning: Bool { flags & 4 != 0 }
    public var isLocked: Bool { flags & 8 != 0 }
    public var dieCelsius: Double? { quarterDegrees.map { Double($0) / 4 } }
    public init(data: Data) throws {
        let b = [UInt8](data)
        guard b.count == 20 else { throw SafetyError.invalidPacket }
        func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i+1]) << 8 }
        func u32(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24 }
        guard b[0] == 1, b[1] & 0xf0 == 0, b[6] <= 1, [0,1,255].contains(b[7]),
              b[9...11].allSatisfy({ $0 == 0 }), let reason = Reason(rawValue: b[8]), u32(16) > 0 else { throw SafetyError.invalidPacket }
        let mv = u16(2), temp = Int16(bitPattern: u16(4))
        guard (b[1] & 1 != 0 ? (-160...500).contains(temp) : temp == .min),
              (b[1] & 2 != 0 ? (1000...9000).contains(mv) : mv == .max),
              (b[1] & 4 != 0 ? reason != .none : reason == .none),
              b[1] & 1 != 0 || b[1] & 4 != 0,
              b[1] & 8 == 0 || (b[1] & 4 != 0 && reason != .none) else { throw SafetyError.invalidPacket }
        flags = b[1]; millivolts = b[1] & 2 != 0 ? mv : nil; quarterDegrees = b[1] & 1 != 0 ? temp : nil
        usbPresent = b[6] == 1; chargeActive = b[7] == 255 ? nil : b[7] == 1
        self.reason = reason; sample = u32(12); boot = u32(16)
    }
    public enum SafetyError: Error { case invalidPacket }
}

public struct SafetyStream {
    public private(set) var latest: SafetyTelemetry?
    public private(set) var receivedAt: Date?
    public init() {}
    public mutating func invalidateFreshness() { receivedAt = nil }
    public func isStale(at date: Date = Date()) -> Bool {
        guard let receivedAt else { return true }
        return date < receivedAt || date.timeIntervalSince(receivedAt) > 10
    }
    public mutating func ingest(_ packet: SafetyTelemetry, expectedBoot: UInt32?, at date: Date = Date()) -> SyncDisposition {
        if let expectedBoot, packet.boot != expectedBoot { return .outdated }
        if let old = latest {
            if packet.boot < old.boot || (packet.boot == old.boot && packet.sample < old.sample) { return .outdated }
            if packet.boot == old.boot && packet.sample == old.sample {
                // Reading a frozen characteristic must not make old measurements fresh.
                return packet == old ? .duplicate : .inconsistent
            }
        }
        latest = packet; receivedAt = date; return .accepted
    }
}
