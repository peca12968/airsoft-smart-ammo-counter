import XCTest
@testable import AmmoCore

extension VibrationTrainingTests {
    func relayFixture() throws -> (WatchAudioStart,[WatchAudioFrame]) {
        let model=try refinedFixture().model
        let session=WatchAudioStart(model:model,settings:LocalDetectionSettings(similarity:model.minimumScore),validation:true)
        var frames=[WatchAudioFrame]()
        for time in [0.0,0.04] {frames.append(WatchAudioFrame(spectrum:refinedTone(250,0.0004),motion:0,time:time))}
        for index in 0..<5 {
            let onset=0.08+Double(index)*0.2
            for (offset,amplitude) in [(0.0,index==0 ? 0.006:0.06),(0.02,0.16),(0.05,0.04),(0.10,0.008),(0.11,0.008),(0.12,0.008),(0.13,0.008),(0.14,0.008),(0.15,0.008),(0.16,0.008),(0.17,0.008)] {
                frames.append(WatchAudioFrame(spectrum:refinedTone(1250,amplitude),motion:0,time:onset+offset))
            }
        }
        return (session,frames)
    }
    func testRelayRapidFiveIndependentOfBatchBoundariesAndDuplicateDelivery() throws {
        let (session,frames)=try relayFixture()
        for size in [1,8,24] {
            var receiver=try XCTUnwrap(WatchAudioReceiver(session:session)),count=0,sequence:UInt64=0
            for offset in stride(from:0,to:frames.count,by:size) {
                let chunk=Array(frames[offset..<min(frames.count,offset+size)])
                let batch=WatchAudioBatch(id:session.id,sequence:sequence,frames:chunk,finished:offset+size>=frames.count)
                let data=try PropertyListEncoder().encode(batch)
                XCTAssertLessThan(data.count,60000)
                let decoded=try PropertyListDecoder().decode(WatchAudioBatch.self,from:data)
                let result=try receiver.accept(decoded);count+=result.newHits
                let duplicate=try receiver.accept(decoded)
                XCTAssertEqual(duplicate.newHits,0);XCTAssertEqual(duplicate.totalHits,result.totalHits)
                sequence+=1
            }
            XCTAssertEqual(count,5)
        }
    }
    func testRelayRejectsMissingReorderedOrForeignBatchesWithoutAdvancing() throws {
        let (session,frames)=try relayFixture()
        var receiver=try XCTUnwrap(WatchAudioReceiver(session:session))
        XCTAssertThrowsError(try receiver.accept(WatchAudioBatch(id:session.id,sequence:1,frames:[frames[0]])))
        XCTAssertThrowsError(try receiver.accept(WatchAudioBatch(id:UUID(),sequence:0,frames:[frames[0]])))
        XCTAssertThrowsError(try receiver.accept(WatchAudioBatch(id:session.id,sequence:0,frames:[frames[1],frames[0]])))
        XCTAssertEqual(try receiver.accept(WatchAudioBatch(id:session.id,sequence:0,frames:[frames[0]])).sequence,0)
    }
    func testRelayGapsAreExplicitAndSessionCannotResumeAfterFinish() throws {
        let (session,frames)=try relayFixture()
        var receiver=try XCTUnwrap(WatchAudioReceiver(session:session))
        _ = try receiver.accept(WatchAudioBatch(id:session.id,sequence:0,frames:[frames[0]]))
        let later=WatchAudioFrame(spectrum:frames[0].spectrum,motion:0,time:0.3)
        XCTAssertEqual(try receiver.accept(WatchAudioBatch(id:session.id,sequence:1,frames:[later],finished:true)).gaps,1)
        XCTAssertThrowsError(try receiver.accept(WatchAudioBatch(id:session.id,sequence:2,frames:[later])))
    }
    func testRelaySpeechValidationAndCountingAreDistinctSessions() throws {
        let model=try refinedFixture().model
        let settings=LocalDetectionSettings(similarity:model.minimumScore)
        let validation=WatchAudioStart(model:model,settings:settings,validation:true,expected:0)
        let restored=try PropertyListDecoder().decode(WatchAudioStart.self,from:PropertyListEncoder().encode(validation))
        XCTAssertTrue(restored.valid);XCTAssertTrue(restored.validation);XCTAssertEqual(restored.expected,0)
        let counting=WatchAudioStart(model:model,settings:settings,validation:false)
        XCTAssertFalse(counting.validation);XCTAssertNotEqual(validation.id,counting.id)
        XCTAssertNil(WatchAudioReceiver(session:WatchAudioStart(model:model,settings:settings,validation:true,expected:7)))
    }
    func testRelayRejectsNonfiniteInputAndOversizedBatches() throws {
        let (session,frames)=try relayFixture()
        var receiver=try XCTUnwrap(WatchAudioReceiver(session:session))
        let invalid=WatchAudioFrame(spectrum:frames[0].spectrum,motion:0,time:.nan)
        XCTAssertThrowsError(try receiver.accept(WatchAudioBatch(id:session.id,sequence:0,frames:[invalid])))
        XCTAssertThrowsError(try receiver.accept(WatchAudioBatch(id:session.id,sequence:0,frames:Array(frames.prefix(25)))))
    }
}
