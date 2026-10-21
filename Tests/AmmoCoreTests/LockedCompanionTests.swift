import XCTest
@testable import AmmoCore

final class LockedCompanionTests:XCTestCase {
    func testOfflineWatchCountingAndReloadMergeWithoutDuplicateEvents() throws {
        let directory=try folder()
        var phone=LocalAmmoLedger(seed:420,capacity:300,remaining:10,editor:"phone")
        let stalePhone=phone
        var watch=phone
        for _ in 0..<5 {watch.event(origin:"watch")}
        watch.reload(origin:"watch")
        for _ in 0..<2 {watch.event(origin:"watch")}
        try LocalLedgerStorage.save(watch,to:directory)
        watch=try XCTUnwrap(LocalLedgerStorage.load(from:directory))
        watch.merge(stalePhone)
        for _ in 0..<5 {phone.merge(watch)}
        XCTAssertEqual(phone.lifetime,427);XCTAssertEqual(phone.total,427)
        XCTAssertEqual(phone.remaining,298);XCTAssertEqual(watch.remaining,298)
        XCTAssertEqual(phone.resetBaseline,stalePhone.resetBaseline)
    }
    func folder() throws -> URL {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        addTeardownBlock{try? FileManager.default.removeItem(at:folder)}
        return folder
    }
    func testMissingLedgerIsDistinctFromUnreadableLedger() throws {
        let url=try folder();XCTAssertNil(try LocalLedgerStorage.load(from:url))
        try Data("invalid".utf8).write(to:url.appendingPathComponent("local-counter.json"))
        XCTAssertThrowsError(try LocalLedgerStorage.load(from:url))
    }
    func testReloadAfterColdLaunchPreservesLifetimeAndRejectsDuplicate() throws {
        let url=try folder()
        var ledger=LocalAmmoLedger(seed:420,capacity:300,remaining:40,editor:"phone")
        ledger.event(origin:"phone");try LocalLedgerStorage.save(ledger,to:url)
        let request=MagazineReloadRequest(revision:ledger.revision,now:10)
        var restored=try XCTUnwrap(LocalLedgerStorage.load(from:url))
        XCTAssertTrue(request.apply(to:&restored,origin:"phone",now:11))
        try LocalLedgerStorage.save(restored,to:url)
        var secondLaunch=try XCTUnwrap(LocalLedgerStorage.load(from:url))
        XCTAssertEqual(secondLaunch.total,421);XCTAssertEqual(secondLaunch.remaining,300)
        XCTAssertFalse(request.apply(to:&secondLaunch,origin:"phone",now:12))
    }
    func testValidBackupSurvivesCorruptPrimary() throws {
        let url=try folder(),ledger=LocalAmmoLedger(seed:420,editor:"phone")
        try LocalLedgerStorage.save(ledger,to:url)
        try Data("bad".utf8).write(to:url.appendingPathComponent("local-counter.json"))
        XCTAssertEqual(try LocalLedgerStorage.load(from:url),ledger)
    }
    func testAutoStartRequiresReadyModelAndHonorsStopAndValidation(){
        var status=WatchControlStatus(settings:LocalDetectionSettings(),phase:"ready",detail:"",busy:false,hasModel:true,validationHits:0,build:"test",canStart:true)
        func allowed(_ s:WatchControlStatus?,active:Bool=true,suppressed:Bool=false,pending:Bool=false,receiving:Bool=false,watch:Bool=true)->Bool {
            WatchAutoStartPolicy.shouldStart(phoneActive:active,watchSource:watch,suppressed:suppressed,pending:pending,receiving:receiving,status:s)
        }
        XCTAssertTrue(allowed(status));XCTAssertFalse(allowed(status,active:false))
        XCTAssertFalse(allowed(status,suppressed:true));XCTAssertFalse(allowed(status,pending:true))
        XCTAssertFalse(allowed(status,receiving:true));XCTAssertFalse(allowed(status,watch:false))
        XCTAssertFalse(allowed(nil));status.busy=true;XCTAssertFalse(allowed(status))
        status.busy=false;status.canStart=false;XCTAssertFalse(allowed(status))
        status.canStart=true;status.hasModel=false;XCTAssertFalse(allowed(status))
    }
    func testOlderWatchStatusDoesNotAutoStart() throws {
        let status=WatchControlStatus(settings:LocalDetectionSettings(),phase:"ready",detail:"",busy:false,hasModel:true,validationHits:0,build:"old")
        let decoded=try JSONDecoder().decode(WatchControlStatus.self,from:JSONEncoder().encode(status))
        XCTAssertFalse(WatchAutoStartPolicy.shouldStart(phoneActive:true,watchSource:true,suppressed:false,pending:false,receiving:false,status:decoded))
    }
}
