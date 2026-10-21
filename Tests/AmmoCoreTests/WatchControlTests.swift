import XCTest
@testable import AmmoCore

final class WatchControlTests:XCTestCase {
    func testSettingsRoundTripAndRejectUnsafeValues() throws {
        let settings=LocalDetectionSettings(mode:1,similarity:0.91,motionThreshold:0.02)
        XCTAssertEqual(try JSONDecoder().decode(LocalDetectionSettings.self,from:JSONEncoder().encode(settings)),settings)
        XCTAssertTrue(settings.valid)
        for settings in [LocalDetectionSettings(mode:3),LocalDetectionSettings(similarity:Double.nan),
                         LocalDetectionSettings(similarity:0.1),LocalDetectionSettings(motionThreshold:0),
                         LocalDetectionSettings(motionThreshold:Double.infinity)] {XCTAssertFalse(settings.valid)}
    }
    func testRecordingCannotStartLateInBackgroundOrDuringValidation() {
        let request=WatchControlRequest(action:.train,now:100)
        XCTAssertNil(request.rejection(now:101,foreground:true,busy:false,hasModel:false))
        XCTAssertNotNil(request.rejection(now:131,foreground:true,busy:false,hasModel:true))
        XCTAssertNotNil(request.rejection(now:69,foreground:true,busy:false,hasModel:true))
        XCTAssertNotNil(request.rejection(now:101,foreground:false,busy:false,hasModel:true))
        XCTAssertNotNil(request.rejection(now:101,foreground:true,busy:true,hasModel:true))
    }
    func testStatusAndStopRemainAvailableWhileBusy() {
        for action in [WatchControlRequest.Action.status,.stop] {
            XCTAssertNil(WatchControlRequest(action:action,now:100).rejection(now:101,foreground:false,busy:true,hasModel:false))
        }
    }
    func testSettingsAndBackgroundRequireValidInputs() throws {
        let bad=WatchControlRequest(action:.settings,settings:LocalDetectionSettings(mode:-1),now:100)
        XCTAssertNotNil(bad.rejection(now:101,foreground:true,busy:false,hasModel:true))
        XCTAssertNotNil(WatchControlRequest(action:.settings,now:100).rejection(now:101,foreground:true,busy:false,hasModel:true))
        for action in [WatchControlRequest.Action.start,.validate,.validateSpeech,.speechBackground,.otherBackground] {
            XCTAssertNotNil(WatchControlRequest(action:action,now:100).rejection(now:101,foreground:true,busy:false,hasModel:false))
        }
        let original=WatchControlRequest(action:.settings,settings:LocalDetectionSettings(),now:100)
        let decoded=try JSONDecoder().decode(WatchControlRequest.self,from:JSONEncoder().encode(original))
        XCTAssertEqual(original.id,decoded.id)
        XCTAssertNil(decoded.rejection(now:101,foreground:true,busy:false,hasModel:true))
        var future=decoded;future.version=2
        XCTAssertNotNil(future.rejection(now:101,foreground:true,busy:false,hasModel:true))
    }
}
