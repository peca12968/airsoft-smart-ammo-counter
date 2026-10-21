import XCTest
@testable import AmmoCore

final class SafetyTelemetryTests: XCTestCase {
    private func packet(sample: UInt32 = 1, boot: UInt32 = 3) -> Data {
        var b: [UInt8] = [1,3,10,15,100,0,1,1,0,0,0,0,0,0,0,0,0,0,0,0]
        for i in 0..<4 { b[12+i] = UInt8(truncatingIfNeeded: sample >> (i*8)); b[16+i] = UInt8(truncatingIfNeeded: boot >> (i*8)) }
        return Data(b)
    }
    func testGoldenPacketAndSentinels() throws {
        let p = try SafetyTelemetry(data: packet())
        XCTAssertEqual(p.dieCelsius, 25); XCTAssertEqual(p.millivolts, 3850)
        XCTAssertTrue(p.usbPresent); XCTAssertEqual(p.chargeActive, true); XCTAssertFalse(p.isLocked)
        var b = [UInt8](packet()); b[1]=4; b[2]=255; b[3]=255; b[4]=0; b[5]=128; b[7]=255; b[8]=4
        let unknown = try SafetyTelemetry(data: Data(b))
        XCTAssertNil(unknown.dieCelsius); XCTAssertNil(unknown.millivolts); XCTAssertNil(unknown.chargeActive)
    }
    func testRejectMalformedSafetyPackets() {
        XCTAssertThrowsError(try SafetyTelemetry(data: packet().dropLast()))
        for (index,value) in [(0,2),(1,128),(6,2),(7,2),(8,99),(9,1),(10,1),(11,1)] {
            var b = [UInt8](packet()); b[index]=UInt8(value)
            XCTAssertThrowsError(try SafetyTelemetry(data: Data(b)))
        }
        XCTAssertThrowsError(try SafetyTelemetry(data: packet(boot: 0)))
        var b = [UInt8](packet()); b[1]=11 // Locked without warning/reason.
        XCTAssertThrowsError(try SafetyTelemetry(data: Data(b)))
        b = [UInt8](packet()); b[4]=255; b[5]=127
        XCTAssertThrowsError(try SafetyTelemetry(data: Data(b)))
    }
    func testDuplicateDoesNotRefreshFrozenMeasurements() throws {
        var stream = SafetyStream(); let start = Date(timeIntervalSince1970: 100)
        let p = try SafetyTelemetry(data: packet())
        XCTAssertEqual(stream.ingest(p, expectedBoot: 3, at: start), .accepted)
        XCTAssertEqual(stream.ingest(p, expectedBoot: 3, at: start.addingTimeInterval(11)), .duplicate)
        XCTAssertTrue(stream.isStale(at: start.addingTimeInterval(11)))
        XCTAssertTrue(stream.isStale(at: start.addingTimeInterval(-1)))
        XCTAssertEqual(stream.ingest(try SafetyTelemetry(data: packet(sample: 2)), expectedBoot: 3, at: start.addingTimeInterval(12)), .accepted)
        XCTAssertFalse(stream.isStale(at: start.addingTimeInterval(13)))
        XCTAssertEqual(stream.ingest(p, expectedBoot: 3), .outdated)
        XCTAssertEqual(stream.ingest(try SafetyTelemetry(data: packet(boot: 4)), expectedBoot: 3), .outdated)
        stream.invalidateFreshness(); XCTAssertTrue(stream.isStale())
    }
    func testSameCounterWithChangedPayloadIsRejected() throws {
        var stream = SafetyStream(); let p = try SafetyTelemetry(data: packet())
        _ = stream.ingest(p, expectedBoot: 3)
        var b = [UInt8](packet()); b[6]=0
        XCTAssertEqual(stream.ingest(try SafetyTelemetry(data: Data(b)), expectedBoot: 3), .inconsistent)
        XCTAssertEqual(stream.latest, p)
    }
}
