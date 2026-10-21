import Foundation
public struct LiveSignal {
    public let sequence: UInt16
    public let timestamp: UInt32
    public let microphoneActive: Bool
    public let clipped: Bool
    public let imuReady: Bool
    public let rms: Double
    public let peak: Double
    public let vibrationG: Double
    public let samples: UInt16
    public let boot: UInt32
    public init(data: Data) throws {
        let d = Data(data)
        guard d.count == 20, d[0] == 1, d[1] & 0xf8 == 0 else { throw AmmoError.malformedPacket }
        sequence = d.integer(UInt16.self,at:2); timestamp = d.integer(UInt32.self,at:4)
        microphoneActive = d[1]&1 != 0; clipped = d[1]&2 != 0; imuReady = d[1]&4 != 0
        let r = d.integer(UInt16.self,at:8),p = d.integer(UInt16.self,at:10)
        rms = Double(r)/32768; peak = Double(p)/32768; vibrationG = Double(d.integer(UInt16.self,at:12))/1000
        samples = d.integer(UInt16.self,at:14); boot = d.integer(UInt32.self,at:16)
        guard sequence != 0, boot != 0, r <= p, p <= 32768, vibrationG <= 32, samples <= 16000,
              microphoneActive ? samples > 0 : (samples == 0 && r == 0 && p == 0) else { throw AmmoError.invalidValue }
    }
    public static func data(sequence: UInt16,timestamp: UInt32,rms: UInt16,peak: UInt16,vibrationMG: UInt16,samples: UInt16,boot: UInt32) -> Data {
        var d = Data([1,UInt8(4 | (samples > 0 ? 1:0))]);d.put(sequence);d.put(timestamp);d.put(rms);d.put(peak);d.put(vibrationMG);d.put(samples);d.put(boot);return d
    }
}
