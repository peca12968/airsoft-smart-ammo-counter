import XCTest
@testable import AmmoCore

final class AmmoCoreTests: XCTestCase {
    func testPresetsAndInvalidCapacities() throws {
        for cap in AmmoCounter.presets + [1, 9999] { XCTAssertEqual(try AmmoCounter(capacity: cap).remaining, cap) }
        for cap in [-1, 0, 10000, Int.max] { XCTAssertThrowsError(try AmmoCounter(capacity: cap)) }
    }
    func testBoundsAndExtremeCorrection() throws {
        var c = try AmmoCounter(capacity: 30)
        c.correct(by: Int.min); XCTAssertEqual(c.remaining, 0)
        c.correct(by: Int.max); XCTAssertEqual(c.remaining, 30)
        for _ in 0..<35 { c.recordEvent() }
        XCTAssertEqual(c.remaining, 0); XCTAssertEqual(c.totalEvents, 35)
    }
    func testCapacityChangeClampsWithoutRefilling() throws {
        var c = try AmmoCounter(capacity: 300, remaining: 247)
        try c.setCapacity(30); XCTAssertEqual(c.remaining, 30)
        try c.setCapacity(130); XCTAssertEqual(c.remaining, 30)
        XCTAssertThrowsError(try c.setCapacity(0)); XCTAssertEqual(c.capacity, 130)
    }
    func testReloadPreservesLifetimeEvents() throws {
        var c = try AmmoCounter(capacity: 130, remaining: 2, totalEvents: 400)
        try c.reload(capacity: 150); XCTAssertEqual(c.remaining, 150); XCTAssertEqual(c.totalEvents, 400)
    }
    func testLowThresholdStrictlyBelow15Percent() throws {
        var c = try AmmoCounter(capacity: 300, remaining: 45)
        XCTAssertFalse(c.isLow); c.correct(by: -1); XCTAssertTrue(c.isLow)
        XCTAssertEqual(c.fraction, 44.0 / 300.0)
    }
    func testTotalEventSaturates() throws {
        var c = try AmmoCounter(totalEvents: .max)
        c.recordEvent(); XCTAssertEqual(c.totalEvents, .max)
    }
    func sample(seq: UInt32 = 5, boot: UInt32 = 2) throws -> DeviceSnapshot {
        DeviceSnapshot(counter: try AmmoCounter(capacity: 300, remaining: 247, totalEvents: 53), sequence: seq, boot: boot, battery: 82, flags: 33)
    }
    func testWireGoldenVectorAndRoundtrip() throws {
        let s = try sample()
        XCTAssertEqual(s.data.map { String(format: "%02x", $0) }.joined(), "01212c01f7003500000005000000020000005200")
        XCTAssertEqual(try DeviceSnapshot(data: s.data), s)
        let cmd = DeviceCommand(opcode: .correction, value: -7, requestID: 123, expectedSequence: 5, boot: 2)
        XCTAssertEqual(cmd.data.count, 16); XCTAssertEqual(try DeviceCommand(data: cmd.data), cmd)
        let ack = CommandAck(result: .accepted, requestID: 123, boot: 2, sequence: 6)
        XCTAssertEqual(ack.data.count, 14); XCTAssertEqual(try CommandAck(data: ack.data), ack)
        let id = DeviceIdentity(id: 0x1234567890abcdef)
        XCTAssertEqual(try DeviceIdentity(data: id.data), id)
    }
    func testRejectBadSizesVersionsAndFields() throws {
        let valid = try sample().data
        for n in 0..<40 where n != 20 { XCTAssertThrowsError(try DeviceSnapshot(data: Data(repeating: 0, count: n))) }
        for (offset, value) in [(0, UInt8(2)), (18, 101), (19, 1), (1, 128)] {
            var d = valid; d[offset] = value; XCTAssertThrowsError(try DeviceSnapshot(data: d))
        }
        var zeroCap = valid; zeroCap[2] = 0; zeroCap[3] = 0
        XCTAssertThrowsError(try DeviceSnapshot(data: zeroCap))
        var tooMany = valid; tooMany[4] = 255; tooMany[5] = 255
        XCTAssertThrowsError(try DeviceSnapshot(data: tooMany))
        var bootZero = valid; for i in 14..<18 { bootZero[i] = 0 }; XCTAssertThrowsError(try DeviceSnapshot(data: bootZero))
        var unknownBattery = valid; unknownBattery[18] = 255; XCTAssertNil(try DeviceSnapshot(data: unknownBattery).battery)
        XCTAssertThrowsError(try DeviceIdentity(data: Data(repeating: 0, count: 9)))
        XCTAssertThrowsError(try DeviceCommand(data: Data(repeating: 0, count: 16)))
        XCTAssertThrowsError(try CommandAck(data: Data(repeating: 0, count: 14)))
    }
    func testSlicedDataDecoding() throws {
        let s = try sample(); let padded = Data([99, 99]) + s.data
        XCTAssertEqual(try DeviceSnapshot(data: padded.dropFirst(2)), s)
    }
    func testDeterministicMalformedPacketFuzz() {
        var random: UInt64 = 0xcafe
        for length in 0..<80 {
            for _ in 0..<100 {
                let data = Data((0..<length).map { _ -> UInt8 in random = random &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded: random >> 32) })
                _ = try? DeviceSnapshot(data: data); _ = try? DeviceCommand(data: data)
                _ = try? CommandAck(data: data); _ = try? DeviceIdentity(data: data)
            }
        }
    }
    func testDuplicateOldLostNotificationsAndReboot() throws {
        var sync = SnapshotSynchronizer(); let id = DeviceIdentity(id: 7)
        let first = try sample()
        XCTAssertEqual(sync.ingest(identity: id, snapshot: first), .accepted)
        XCTAssertEqual(sync.ingest(identity: id, snapshot: first), .duplicate)
        XCTAssertEqual(sync.ingest(identity: id, snapshot: try sample(seq: 4)), .outdated)
        XCTAssertEqual(sync.ingest(identity: id, snapshot: try sample(seq: 100)), .accepted) // skipped notifications
        XCTAssertEqual(sync.ingest(identity: id, snapshot: try sample(seq: 0, boot: 3)), .accepted)
        XCTAssertEqual(sync.ingest(identity: id, snapshot: try sample(seq: 999, boot: 2)), .outdated)
        XCTAssertEqual(sync.ingest(identity: DeviceIdentity(id: 8), snapshot: first), .accepted)
    }
    func testInconsistentSameSequenceOrRegressedTotalRejected() throws {
        var sync = SnapshotSynchronizer(); let id = DeviceIdentity(id: 7)
        _ = sync.ingest(identity: id, snapshot: try sample())
        var changed = try sample(); changed.counter.correct(by: -1)
        XCTAssertEqual(sync.ingest(identity: id, snapshot: changed), .inconsistent)
        changed.sequence += 1; changed.counter = try AmmoCounter(totalEvents: 2)
        XCTAssertEqual(sync.ingest(identity: id, snapshot: changed), .inconsistent)
    }
    func testDuplicateReadRefreshesStaleTimestamp() throws {
        var sync = SnapshotSynchronizer(); let id = DeviceIdentity(id: 7); let s = try sample(); let time = Date()
        _ = sync.ingest(identity: id, snapshot: s, at: time.addingTimeInterval(-20))
        XCTAssertTrue(sync.state!.isStale(at: time))
        _ = sync.ingest(identity: id, snapshot: s, at: time)
        XCTAssertFalse(sync.state!.isStale(at: time))
    }
    func testAckRequiresMatchingCommandAndSnapshot() throws {
        let command = DeviceCommand(opcode: .reload, value: 300, requestID: 17, expectedSequence: 5, boot: 2)
        var t = CommandTracker(); XCTAssertTrue(t.begin(command)); XCTAssertFalse(t.begin(command))
        XCTAssertFalse(t.acknowledge(CommandAck(result: .accepted, requestID: 18, boot: 2, sequence: 6)))
        XCTAssertFalse(t.acknowledge(CommandAck(result: .accepted, requestID: 17, boot: 1, sequence: 6)))
        XCTAssertFalse(t.acknowledge(CommandAck(result: .accepted, requestID: 17, boot: 2, sequence: 5)))
        XCTAssertTrue(t.acknowledge(CommandAck(result: .accepted, requestID: 17, boot: 2, sequence: 6)))
        XCTAssertFalse(t.observe(try sample(seq: 5))); XCTAssertNotNil(t.pending)
        XCTAssertTrue(t.observe(try sample(seq: 8))); XCTAssertNil(t.pending)
    }
    func testPendingCommandCancelledOnRebootAndRejection() throws {
        let c = DeviceCommand(opcode: .correction, value: -1, requestID: 7, expectedSequence: 5, boot: 2)
        var t = CommandTracker(); _ = t.begin(c); _ = t.observe(try sample(boot: 3)); XCTAssertNil(t.pending)
        _ = t.begin(c); XCTAssertTrue(t.acknowledge(CommandAck(result: .stale, requestID: 7, boot: 2, sequence: 6))); XCTAssertNil(t.pending)
    }
    func temporaryStore() -> PersistenceService { PersistenceService(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json")) }
    func testPersistenceRoundtripAndCorruptData() throws {
        let p = temporaryStore(); defer { try? FileManager.default.removeItem(at: p.url.deletingLastPathComponent()) }
        XCTAssertNil(try p.load())
        let state = DeviceState(identity: DeviceIdentity(id: 7), snapshot: try sample(), syncedAt: Date(timeIntervalSince1970: 123456))
        try p.save(state); XCTAssertEqual(try p.load(), state)
        try Data("broken".utf8).write(to: p.url); XCTAssertEqual(try p.load(),try JSONDecoder().decode(DeviceState.self,from:Data(contentsOf:p.url.appendingPathExtension("backup"))))
        try Data("broken".utf8).write(to:p.url.appendingPathExtension("backup"));XCTAssertThrowsError(try p.load())
    }
    func testPersistenceRejectsDecodedInvalidCounterWithoutTrap() throws {
        let p = temporaryStore(); defer { try? FileManager.default.removeItem(at: p.url.deletingLastPathComponent()) }
        try p.save(DeviceState(identity: DeviceIdentity(id: 7), snapshot: try sample()))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: p.url)) as! [String: Any]
        var snap = json["snapshot"] as! [String: Any]; var counter = snap["counter"] as! [String: Any]
        counter["capacity"] = -100; counter["remaining"] = -1; snap["counter"] = counter; json["snapshot"] = snap
        try JSONSerialization.data(withJSONObject: json).write(to: p.url)
        XCTAssertEqual(try p.load(),try JSONDecoder().decode(DeviceState.self,from:Data(contentsOf:p.url.appendingPathExtension("backup"))))
        try Data("broken".utf8).write(to:p.url.appendingPathExtension("backup"));XCTAssertThrowsError(try p.load())
    }
    func testDemoReloadCorrectionRetryAndDisconnect() async throws {
        await MainActor.run {
            let demo = DemoDevice(); var states = [DeviceSnapshot](); var acks = [CommandAck]()
            demo.onEvent = { event in
                if case .state(let data) = event, let s = try? DeviceSnapshot(data: data) { states.append(s) }
                if case .ack(let data) = event, let a = try? CommandAck(data: data) { acks.append(a) }
            }
            demo.start(); XCTAssertEqual(states.last?.counter.remaining, 247)
            let c = DeviceCommand(opcode: .correction, value: -7, requestID: 12, expectedSequence: 0, boot: 1)
            demo.dropNextAck = true; demo.send(c.data); XCTAssertTrue(acks.isEmpty)
            demo.send(c.data); XCTAssertEqual(acks.last?.result, .accepted); XCTAssertEqual(demo.snapshot.counter.remaining, 240)
            demo.stop(); demo.simulateEvent(); XCTAssertEqual(states.last?.counter.remaining, 240)
            demo.start(); XCTAssertEqual(states.last?.counter.remaining, 239)
            let reload = DeviceCommand(opcode: .reload, value: 30, requestID: 13, expectedSequence: demo.snapshot.sequence, boot: 1)
            demo.send(reload.data); XCTAssertEqual(states.last?.counter.remaining, 30)
            XCTAssertEqual(demo.snapshot.counter.totalEvents, 1)
            demo.send(c.data); XCTAssertEqual(acks.last?.result, .stale)
            demo.reboot(); XCTAssertEqual(demo.snapshot.boot, 2); XCTAssertEqual(demo.snapshot.counter.remaining, 30)
        }
    }
    func testDemoLostNotificationAndDevicePersistence() async throws {
        let p = temporaryStore(); defer { try? FileManager.default.removeItem(at: p.url.deletingLastPathComponent()) }
        await MainActor.run {
            let d = DemoDevice(persistence: p); var last: DeviceSnapshot?
            d.onEvent = { if case .state(let data) = $0 { last = try? DeviceSnapshot(data: data) } }
            d.start(); d.dropNextState = true; d.simulateEvent(); XCTAssertEqual(last?.counter.remaining, 247)
            d.readState(); XCTAssertEqual(last?.counter.remaining, 246)
            let restored = DemoDevice(persistence: p); XCTAssertEqual(restored.snapshot.counter.remaining, 246)
        }
    }
    func testDemoRejectsInvalidCommandsWithoutMutation() async {
        await MainActor.run {
            let d = DemoDevice(); d.start(); let before = d.snapshot
            d.send(DeviceCommand(opcode: .reload, value: 0, requestID: 7, expectedSequence: 0, boot: 1).data)
            XCTAssertEqual(d.snapshot, before)
            d.send(DeviceCommand(opcode: .correction, value: 30000, requestID: 8, expectedSequence: 0, boot: 1).data)
            XCTAssertEqual(d.snapshot, before)
        }
    }
    func testPersistenceRejectsHugeDecodedRemainingWithoutOverflow() throws {
        let p = temporaryStore(); defer { try? FileManager.default.removeItem(at: p.url.deletingLastPathComponent()) }
        try p.save(DeviceState(identity: DeviceIdentity(id: 7), snapshot: try sample()))
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: p.url)) as! [String: Any]
        var snap = json["snapshot"] as! [String: Any]; var counter = snap["counter"] as! [String: Any]
        counter["remaining"] = Int.max; snap["counter"] = counter; json["snapshot"] = snap
        try JSONSerialization.data(withJSONObject: json).write(to: p.url)
        XCTAssertEqual(try p.load(),try JSONDecoder().decode(DeviceState.self,from:Data(contentsOf:p.url.appendingPathExtension("backup"))))
        try Data("broken".utf8).write(to:p.url.appendingPathExtension("backup"));XCTAssertThrowsError(try p.load())
    }
    func testDemoSequenceExhaustionAndUnknownBattery() async throws {
        let p = temporaryStore(); defer { try? FileManager.default.removeItem(at: p.url.deletingLastPathComponent()) }
        let snapshot = DeviceSnapshot(counter: try AmmoCounter(), sequence: .max, boot: 2, battery: nil, flags: 16)
        try p.save(DeviceState(identity: DeviceIdentity(id: 0x44454D4F00000001), snapshot: snapshot))
        await MainActor.run {
            let demo = DemoDevice(persistence: p); var ack: CommandAck?
            demo.onEvent = { if case .ack(let data) = $0 { ack = try? CommandAck(data: data) } }
            demo.start(); demo.simulateEvent(); XCTAssertEqual(demo.snapshot, snapshot)
            demo.send(DeviceCommand(opcode: .reload, value: 30, requestID: 7, expectedSequence: .max, boot: 2).data)
            XCTAssertEqual(ack?.result, .exhausted); XCTAssertNil(demo.snapshot.battery)
            demo.reboot(); XCTAssertEqual(demo.snapshot.boot, 3); XCTAssertEqual(demo.snapshot.sequence, 0); XCTAssertEqual(demo.snapshot.flags & 16, 0)
        }
    }

}

extension AmmoCoreTests {
    func testLifetimeNeverRegressesAcrossBoots() throws {
        let id=DeviceIdentity(id:7);var sync=SnapshotSynchronizer()
        let old=try sample();_ = sync.ingest(identity:id,snapshot:old)
        var zero=try sample(seq:0,boot:3);zero.counter=try AmmoCounter(totalEvents:0)
        XCTAssertEqual(sync.ingest(identity:id,snapshot:zero),.inconsistent)
        XCTAssertEqual(sync.state?.snapshot.counter.totalEvents,53)
    }
    func testLegacyAppStateLoadsAndBackupSurvivesMissingPrimary() throws {
        let p=temporaryStore();defer{try? FileManager.default.removeItem(at:p.url.deletingLastPathComponent())}
        let state=DeviceState(identity:DeviceIdentity(id:7),snapshot:try sample())
        try p.save(state);try FileManager.default.removeItem(at:p.url)
        XCTAssertEqual(try p.load(),state)
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as! [String:Any]
        object.removeValue(forKey:"resetStatus")
        try JSONSerialization.data(withJSONObject:object).write(to:p.url)
        XCTAssertEqual(try p.load(),state)
    }
    func testResetMetadataValidationAndWireRoundTrip() throws {
        let status=CounterResetStatus(baseline:42,generation:1,boot:3)
        XCTAssertEqual(try CounterResetStatus(data:status.data),status)
        XCTAssertEqual(status.reportedTotal(lifetime:50),8)
        var malformed=status.data;malformed[1]=1;XCTAssertThrowsError(try CounterResetStatus(data:malformed))
        XCTAssertThrowsError(try CounterResetStatus(data:CounterResetStatus(baseline:2,generation:0,boot:3).data))
    }
    @MainActor func testExplicitResetKeepsRawLifetimeAndPersistsAcrossUpdateAndReboot() throws {
        let p=temporaryStore();defer{try? FileManager.default.removeItem(at:p.url.deletingLastPathComponent())}
        let d=DemoDevice(persistence:p);d.start();d.simulateEvent();d.simulateEvent()
        let original=d.snapshot
        let invalid=DeviceCommand(opcode:.resetTotal,value:0,requestID:60,expectedSequence:original.sequence,boot:original.boot)
        d.send(invalid.data);XCTAssertEqual(d.snapshot,original)
        let command=DeviceCommand(opcode:.resetTotal,value:21075,requestID:61,expectedSequence:original.sequence,boot:original.boot)
        d.send(command.data);d.send(command.data)
        XCTAssertEqual(d.snapshot.counter.totalEvents,2);XCTAssertEqual(d.snapshot.counter.remaining,original.counter.remaining)
        XCTAssertEqual(try p.load()?.resetStatus?.generation,1);XCTAssertEqual(try p.load()?.resetStatus?.baseline,2)
        d.simulateEvent();d.reboot();d.stop()
        let updated=DemoDevice(persistence:p);updated.start()
        XCTAssertEqual(updated.snapshot.counter.totalEvents,3)
        let reset=try XCTUnwrap(try p.load()?.resetStatus)
        XCTAssertEqual(reset.reportedTotal(lifetime:updated.snapshot.counter.totalEvents),1)
    }
}

extension AmmoCoreTests {
    func testInterruptedSaveUsesNewerNonzeroBackup() throws {
        let p=temporaryStore();defer{try? FileManager.default.removeItem(at:p.url.deletingLastPathComponent())}
        let old=DeviceState(identity:DeviceIdentity(id:7),snapshot:DeviceSnapshot(counter:try AmmoCounter(totalEvents:0)))
        try p.save(old)
        let newer=DeviceState(identity:old.identity,snapshot:DeviceSnapshot(counter:try AmmoCounter(totalEvents:57),sequence:57))
        try JSONEncoder().encode(newer).write(to:p.url.appendingPathExtension("backup"),options:.atomic)
        XCTAssertEqual(try p.load()?.snapshot.counter.totalEvents,57)
    }
}

extension AmmoCoreTests {
    func testLocalMigrationAndRepeatedSyncNeverClearsOrDoubleCounts() throws {
        var phone=LocalAmmoLedger(seed:51,capacity:300,remaining:249,editor:"phone")
        var watch=LocalAmmoLedger(seed:5,capacity:300,remaining:295,editor:"watch")
        phone.event(origin:"phone");watch.event(origin:"watch")
        phone.merge(watch);watch.merge(phone);phone.merge(watch)
        XCTAssertEqual(phone.total,53);XCTAssertEqual(watch.total,53);XCTAssertEqual(phone.remaining,247)
        let update=try JSONDecoder().decode(LocalAmmoLedger.self,from:JSONEncoder().encode(phone))
        XCTAssertEqual(update.total,53);XCTAssertEqual(update.remaining,247)
    }
    func testLocalReloadAndCorrectionPreserveTotalAndExplicitResetPersists() throws {
        var s=LocalAmmoLedger(seed:51,capacity:300,remaining:249,editor:"phone")
        s.reload(capacity:130,origin:"phone");s.correct(-2,origin:"phone")
        XCTAssertEqual(s.total,51);XCTAssertEqual(s.remaining,128)
        s.resetFromPhone(origin:"phone");XCTAssertEqual(s.total,0);XCTAssertEqual(s.lifetime,51)
        s.event(origin:"watch");XCTAssertEqual(s.total,1)
        let restored=try JSONDecoder().decode(LocalAmmoLedger.self,from:JSONEncoder().encode(s))
        XCTAssertEqual(restored.total,1);XCTAssertEqual(restored.lifetime,52)
    }
    func testLocalOldPeerCannotUndoResetOrReload() {
        var phone=LocalAmmoLedger(seed:51,capacity:300,remaining:249,editor:"phone"),old=phone
        phone.reload(capacity:150,origin:"phone");phone.resetFromPhone(origin:"phone")
        old.event(origin:"watch");phone.merge(old);old.merge(phone)
        XCTAssertEqual(phone.total,1);XCTAssertEqual(old.total,1);XCTAssertEqual(phone.remaining,149)
    }
    func testLocalSensorOwnershipConvergesAndDoesNotChangeCount() {
        var phone=LocalAmmoLedger(seed:51,editor:"phone"),watch=phone
        phone.claimSensor(origin:"phone");watch.claimSensor(origin:"watch")
        phone.merge(watch);watch.merge(phone)
        XCTAssertEqual(phone.sensorOwner,watch.sensorOwner);XCTAssertEqual(phone.total,51)
    }
    func testLocalTriggerRequiresQuietAndCountsOnlyOnePerBurst() {
        var gate=LocalTriggerGate()
        XCTAssertFalse(gate.update(match:true,quiet:false,time:0))
        XCTAssertFalse(gate.update(match:false,quiet:true,time:0.1));_ = gate.update(match:false,quiet:true,time:0.16)
        XCTAssertTrue(gate.update(match:true,quiet:false,time:0.2))
        XCTAssertFalse(gate.update(match:true,quiet:false,time:0.5))
        _ = gate.update(match:false,quiet:true,time:0.6);_ = gate.update(match:false,quiet:true,time:0.66)
        XCTAssertTrue(gate.update(match:true,quiet:false,time:0.7))
    }
}
