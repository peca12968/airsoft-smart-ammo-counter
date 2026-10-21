import XCTest
@testable import AmmoCore

final class DualSoundFusionTests:XCTestCase {
    func observation(_ station:SoundStation,_ sequence:UInt64,_ time:Double)->SoundObservation {SoundObservation(source:station.rawValue,sequence:sequence,station:station,time:time)}
    func testEitherStationCountsAndBothStationsCountOnlyOnceRegardlessOfArrivalOrder(){
        for order in [[SoundStation.phone,.watch],[.watch,.phone]] {
            var state=SoundFusionState(owner:"phone")
            XCTAssertEqual(state.accept(observation(order[0],1,100),now:101),.counted)
            XCTAssertEqual(state.accept(observation(order[1],1,100.035),now:101),.paired)
            XCTAssertEqual(state.accept(observation(order[0],2,102),now:103),.counted)
            XCTAssertEqual(state.accept(observation(order[1],2,104),now:105),.counted)
        }
    }
    func testPairingIsOneToOneAndDoesNotMergeSeparateRapidShots(){
        var state=SoundFusionState(owner:"phone"),count=0
        for observation in [observation(.phone,1,100),observation(.phone,2,100.1),observation(.watch,1,100.02),observation(.watch,2,100.12)] {
            if state.accept(observation,now:101) == .counted {count+=1}
        }
        XCTAssertEqual(count,2)
        XCTAssertEqual(state.accept(observation(.watch,3,100.14),now:101),.counted)
    }
    func testDuplicateTransportAndOutOfOrderDeliveryCannotAddCounts(){
        var state=SoundFusionState(owner:"phone")
        XCTAssertEqual(state.accept(observation(.watch,2,101),now:102),.gap)
        XCTAssertEqual(state.accept(observation(.watch,1,100),now:102),.counted)
        XCTAssertEqual(state.accept(observation(.watch,2,101),now:102),.counted)
        XCTAssertEqual(state.accept(observation(.watch,1,100),now:102),.duplicate)
        XCTAssertEqual(state.accept(observation(.watch,2,101),now:102),.duplicate)
    }
    func testLedgerAndReceiptsSurviveAtomicSnapshotAndBackupMerge() throws {
        var ledger=LocalAmmoLedger(seed:279,editor:"phone")
        var state=SoundFusionState(owner:"phone")
        let event=observation(.watch,1,100)
        if state.accept(event,now:101) == .counted {ledger.event(origin:"phone")}
        ledger.soundFusion=state
        let saved=try JSONDecoder().decode(LocalAmmoLedger.self,from:JSONEncoder().encode(ledger))
        var older=LocalAmmoLedger(seed:279,editor:"phone");older.soundFusion=SoundFusionState(owner:"phone")
        older.merge(saved)
        XCTAssertEqual(older.total,280)
        XCTAssertEqual(older.soundFusion?.accept(event,now:102),.duplicate)
        XCTAssertEqual(older.soundFusion?.accept(observation(.phone,1,100.02),now:102),.paired)
        XCTAssertEqual(older.total,280)
        older.reload(origin:"phone");XCTAssertEqual(older.total,280)
        older.correct(-1,origin:"phone");XCTAssertEqual(older.total,280)
        older.resetFromPhone(origin:"phone");XCTAssertEqual(older.total,0)
    }
    func testLegacyLedgerLoadsWithoutChangingCumulativeCount() throws {
        var ledger=LocalAmmoLedger(seed:279,editor:"phone");ledger.event(origin:"phone")
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(ledger)) as? [String:Any])
        json.removeValue(forKey:"soundFusion")
        let restored=try JSONDecoder().decode(LocalAmmoLedger.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertEqual(restored.total,280);XCTAssertNil(restored.soundFusion)
    }
    func testOutboxPersistsAndOnlyAcknowledgedSequenceIsRemoved() throws {
        var state=SoundFusionState(owner:"watch")
        for index in 0..<64 {XCTAssertNotNil(state.enqueue(station:.watch,time:100+Double(index)))}
        XCTAssertNil(state.enqueue(station:.watch,time:170))
        var restored=try JSONDecoder().decode(SoundFusionState.self,from:JSONEncoder().encode(state))
        restored.acknowledge(through:1000);XCTAssertEqual(restored.pending.count,64)
        restored.acknowledge(through:32);XCTAssertEqual(restored.pending.count,32)
        XCTAssertEqual(restored.pending.first?.sequence,33)
        restored.acknowledge(through:32);XCTAssertEqual(restored.pending.count,32)
        XCTAssertEqual(restored.enqueue(station:.watch,time:171)?.sequence,65)
    }
    func testExpiredOrInvalidObservationsCannotChangeCount(){
        var state=SoundFusionState(owner:"phone")
        XCTAssertEqual(state.accept(observation(.watch,1,100),now:300),.expired)
        XCTAssertEqual(state.accept(observation(.watch,1,100),now:300),.duplicate)
        XCTAssertEqual(state.accept(observation(.watch,2,301),now:300),.expired)
        XCTAssertEqual(state.accept(SoundObservation(source:"watch",sequence:3,station:.watch,time:.nan),now:300),.invalid)
        XCTAssertEqual(state.accept(SoundObservation(source:"watch",sequence:3,station:.watch,time:300,uncertainty:0.1),now:300),.invalid)
        XCTAssertTrue(state.history.isEmpty)
    }
    func testBoundedHistoryCannotRecountOlderLateObservation(){
        var state=SoundFusionState(owner:"phone")
        for index in 0..<2049 {XCTAssertEqual(state.accept(observation(.phone,UInt64(index+1),100+Double(index)*0.01),now:121),.counted)}
        XCTAssertEqual(state.history.count,2048)
        XCTAssertEqual(state.accept(observation(.watch,1,100),now:121),.expired)
    }
    func testTrainingPauseConsumesReceiptsWithoutCountingOrLaterReplay(){
        var state=SoundFusionState(owner:"phone")
        let event=observation(.watch,1,100)
        XCTAssertEqual(state.accept(event,now:101,counting:false),.suppressed)
        XCTAssertTrue(state.history.isEmpty)
        XCTAssertEqual(state.accept(event,now:102),.duplicate)
        XCTAssertEqual(state.accept(observation(.watch,2,103),now:104),.counted)
    }
    func testClockAlignmentRejectsSlowOrMalformedExchanges() throws {
        let clock=try XCTUnwrap(SoundClockEstimate(sent:100,receivedByPhone:105.01,repliedByPhone:105.012,returned:100.022))
        XCTAssertEqual(clock.offset,5,accuracy:0.00001);XCTAssertEqual(clock.uncertainty,0.01,accuracy:0.00001)
        XCTAssertTrue(clock.valid(at:110));XCTAssertFalse(clock.valid(at:161));XCTAssertFalse(clock.valid(at:99))
        XCTAssertNil(SoundClockEstimate(sent:100,receivedByPhone:105,repliedByPhone:105,returned:101))
        XCTAssertNil(SoundClockEstimate(sent:100,receivedByPhone:105,repliedByPhone:104,returned:100.01))
        XCTAssertNil(SoundClockEstimate(sent:.nan,receivedByPhone:105,repliedByPhone:105,returned:100.01))
    }
}
