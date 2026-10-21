import XCTest
@testable import AmmoCore

final class WatchFeedbackTests:XCTestCase {
    func testThresholdCrossingWarnsOnceAndReloadRearms(){
        var state=LowAmmoFeedback()
        state.update(remaining:45,capacity:300);XCTAssertNil(state.takePending(active:true))
        state.update(remaining:44,capacity:300);XCTAssertEqual(state.takePending(active:true),.low)
        for value in [44,43,1] {state.update(remaining:value,capacity:300);XCTAssertNil(state.takePending(active:true))}
        state.update(remaining:0,capacity:300);XCTAssertEqual(state.takePending(active:true),.empty)
        state.update(remaining:0,capacity:300);XCTAssertNil(state.takePending(active:true))
        state.update(remaining:300,capacity:300);state.update(remaining:44,capacity:300)
        XCTAssertEqual(state.takePending(active:true),.low)
    }
    func testDimmedWarningDefersAndEmptySupersedesLow(){
        var state=LowAmmoFeedback()
        state.update(remaining:3,capacity:30);XCTAssertNil(state.takePending(active:false))
        state.update(remaining:0,capacity:30);XCTAssertNil(state.takePending(active:false))
        XCTAssertEqual(state.takePending(active:true),.empty)
        XCTAssertNil(state.takePending(active:true))
    }
    func testReloadCancelsDeferredWarningAndInvalidDataIsIgnored(){
        var state=LowAmmoFeedback()
        state.update(remaining:1,capacity:30);state.update(remaining:30,capacity:30)
        state.update(remaining:-1,capacity:30);state.update(remaining:0,capacity:0)
        XCTAssertNil(state.takePending(active:true))
    }
    func testRetryDeadlineDoesNotExtendOnRepeatedFailures(){
        var budget=RelayRetryBudget();budget.begin(at:10);budget.begin(at:13)
        XCTAssertFalse(budget.expired(at:13.9));XCTAssertTrue(budget.expired(at:14))
        budget.acknowledged();XCTAssertFalse(budget.expired(at:100))
        budget.begin(at:100);XCTAssertFalse(budget.expired(at:103));XCTAssertTrue(budget.expired(at:104))
    }
    func testPhoneReloadKeepsAllCountsAndRejectsDuplicateOrExpiredRequests(){
        var ledger=LocalAmmoLedger(seed:200,capacity:30,remaining:5,editor:"phone")
        ledger.resetFromPhone(origin:"phone");ledger.event(origin:"phone")
        let request=MagazineReloadRequest(revision:ledger.revision,now:10)
        let lifetime=ledger.lifetime,total=ledger.total,baseline=ledger.resetBaseline
        XCTAssertTrue(request.apply(to:&ledger,origin:"phone",now:11))
        XCTAssertEqual(ledger.remaining,30);XCTAssertEqual(ledger.lifetime,lifetime)
        XCTAssertEqual(ledger.total,total);XCTAssertEqual(ledger.resetBaseline,baseline)
        ledger.event(origin:"phone")
        XCTAssertFalse(request.apply(to:&ledger,origin:"phone",now:12));XCTAssertEqual(ledger.remaining,29)
        let stale=MagazineReloadRequest(revision:ledger.revision,now:0)
        XCTAssertFalse(stale.apply(to:&ledger,origin:"phone",now:20))
    }
    func testStaleReloadDoesNotOverwritePhoneCapacityChange(){
        var ledger=LocalAmmoLedger(capacity:300,remaining:10,editor:"phone")
        let request=MagazineReloadRequest(revision:ledger.revision,now:10)
        ledger.setCapacity(130,origin:"phone")
        XCTAssertFalse(request.apply(to:&ledger,origin:"phone",now:11))
        XCTAssertEqual(ledger.capacity,130);XCTAssertEqual(ledger.remaining,10)
    }
}
