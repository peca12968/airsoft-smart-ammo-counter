import Foundation

extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
    func integer<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size { value |= T(self[startIndex + offset + i]) << (8 * i) }
        return value
    }
}
public struct DeviceIdentity: Codable, Equatable {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
    public init(data: Data) throws {
        guard data.count == 9 else { throw AmmoError.malformedPacket }
        guard data[data.startIndex] == GATT.version else { throw AmmoError.unsupportedVersion }
        id = data.integer(UInt64.self, at: 1)
        guard id != 0 else { throw AmmoError.invalidValue }
    }
    public var data: Data { var d = Data([GATT.version]); d.put(id); return d }
}
public struct DeviceSnapshot: Codable, Equatable {
    public var counter: AmmoCounter
    public var sequence: UInt32
    public var boot: UInt32
    public var battery: UInt8? // 255 on wire means unknown
    public var flags: UInt8
    public init(counter: AmmoCounter, sequence: UInt32 = 0, boot: UInt32 = 1, battery: UInt8? = nil, flags: UInt8 = 0) {
        self.counter = counter; self.sequence = sequence; self.boot = boot; self.battery = battery; self.flags = flags
    }
    public init(data: Data) throws {
        guard data.count == 20 else { throw AmmoError.malformedPacket }
        guard data[data.startIndex] == GATT.version else { throw AmmoError.unsupportedVersion }
        let cap = Int(data.integer(UInt16.self, at: 2)), left = Int(data.integer(UInt16.self, at: 4))
        let bat = data[data.startIndex + 18]
        guard (1...9999).contains(cap), left <= cap, (bat <= 100 || bat == 255), data[data.startIndex + 19] == 0 else { throw AmmoError.invalidValue }
        counter = try AmmoCounter(capacity: cap, remaining: left, totalEvents: data.integer(UInt32.self, at: 6))
        flags = data[data.startIndex + 1]; sequence = data.integer(UInt32.self, at: 10); boot = data.integer(UInt32.self, at: 14)
        guard boot > 0, flags & 0xC0 == 0 else { throw AmmoError.invalidValue }
        battery = bat == 255 ? nil : bat
    }
    public var data: Data {
        var d = Data([GATT.version, flags]); d.put(UInt16(counter.capacity)); d.put(UInt16(counter.remaining))
        d.put(counter.totalEvents); d.put(sequence); d.put(boot); d.append(battery ?? 255); d.append(0); return d
    }
}
public enum CommandOpcode: UInt8, Codable { case reload = 1, correction = 2, setCapacity = 3, resetTotal = 4 }
public struct DeviceCommand: Equatable {
    public let opcode: CommandOpcode
    public let value: Int16
    public let requestID: UInt32
    public let expectedSequence: UInt32
    public let boot: UInt32
    public init(opcode: CommandOpcode, value: Int16, requestID: UInt32, expectedSequence: UInt32, boot: UInt32) {
        self.opcode = opcode; self.value = value; self.requestID = requestID; self.expectedSequence = expectedSequence; self.boot = boot
    }
    public init(data: Data) throws {
        guard data.count == 16 else { throw AmmoError.malformedPacket }
        guard data[data.startIndex] == GATT.version else { throw AmmoError.unsupportedVersion }
        guard let op = CommandOpcode(rawValue: data[data.startIndex + 1]) else { throw AmmoError.invalidValue }
        opcode = op; value = data.integer(Int16.self, at: 2); requestID = data.integer(UInt32.self, at: 4)
        expectedSequence = data.integer(UInt32.self, at: 8); boot = data.integer(UInt32.self, at: 12)
        guard requestID != 0, boot != 0 else { throw AmmoError.invalidValue }
    }
    public var data: Data {
        var d = Data([GATT.version, opcode.rawValue]); d.put(value); d.put(requestID); d.put(expectedSequence); d.put(boot); return d
    }
}
public enum AckResult: UInt8 { case accepted = 0, stale = 1, invalid = 2, storageFailure = 3, exhausted = 4 }
public struct CommandAck: Equatable {
    public let result: AckResult
    public let requestID: UInt32
    public let boot: UInt32
    public let sequence: UInt32
    public init(result: AckResult, requestID: UInt32, boot: UInt32, sequence: UInt32) {
        self.result = result; self.requestID = requestID; self.boot = boot; self.sequence = sequence
    }
    public init(data: Data) throws {
        guard data.count == 14 else { throw AmmoError.malformedPacket }
        guard data[data.startIndex] == GATT.version else { throw AmmoError.unsupportedVersion }
        guard let result = AckResult(rawValue: data[data.startIndex + 1]) else { throw AmmoError.invalidValue }
        self.result = result; requestID = data.integer(UInt32.self, at: 2); boot = data.integer(UInt32.self, at: 6); sequence = data.integer(UInt32.self, at: 10)
        guard requestID != 0, boot != 0 else { throw AmmoError.invalidValue }
    }
    public var data: Data {
        var d = Data([GATT.version, result.rawValue]); d.put(requestID); d.put(boot); d.put(sequence); return d
    }
}

/// Display reset offset; the lifetime hardware event counter never decreases.
public struct CounterResetStatus: Codable, Equatable {
    public let baseline: UInt32
    public let generation: UInt32
    public let boot: UInt32
    public init(baseline: UInt32 = 0, generation: UInt32 = 0, boot: UInt32) {self.baseline=baseline;self.generation=generation;self.boot=boot}
    public init(data: Data) throws {
        let d=Data(data)
        guard d.count==20,d[0]==1,d[1]==0,d[2]==0,d[3]==0,d.integer(UInt32.self,at:16)==0 else {throw AmmoError.malformedPacket}
        self.init(baseline:d.integer(UInt32.self,at:4),generation:d.integer(UInt32.self,at:8),boot:d.integer(UInt32.self,at:12))
        guard boot>0, generation>0 || baseline==0 else {throw AmmoError.invalidValue}
    }
    public var data: Data {var d=Data([1,0,0,0]);d.put(baseline);d.put(generation);d.put(boot);d.put(UInt32(0));return d}
    public func reportedTotal(lifetime: UInt32) -> UInt32 {lifetime>=baseline ? lifetime-baseline:0}
}
