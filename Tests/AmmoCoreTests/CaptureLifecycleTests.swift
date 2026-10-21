import XCTest
@testable import AmmoCore

final class CaptureLifecycleTests:XCTestCase {
    func testWristDownAndBackgroundKeepAnExistingWatchRecording(){
        for scene in [CaptureSceneState.inactive,.background] {
            XCTAssertFalse(CaptureLifecycle.shouldStop(scene:scene,isWatch:true,recordingRunning:true,backgroundAudioEnabled:true))
        }
    }
    func testBackgroundPermissionIsRequired(){
        for scene in [CaptureSceneState.inactive,.background] {
            XCTAssertTrue(CaptureLifecycle.shouldStop(scene:scene,isWatch:true,recordingRunning:true,backgroundAudioEnabled:false))
        }
    }
    func testStoppedOrInterruptedRecordingDoesNotAcquireBackgroundRuntime(){
        for scene in [CaptureSceneState.inactive,.background] {
            XCTAssertTrue(CaptureLifecycle.shouldStop(scene:scene,isWatch:true,recordingRunning:false,backgroundAudioEnabled:true))
        }
    }
    func testPhoneStillRequiresForeground(){
        for scene in [CaptureSceneState.inactive,.background] {
            XCTAssertTrue(CaptureLifecycle.shouldStop(scene:scene,isWatch:false,recordingRunning:true,backgroundAudioEnabled:true))
        }
        XCTAssertFalse(CaptureLifecycle.shouldStop(scene:.active,isWatch:false,recordingRunning:true,backgroundAudioEnabled:false))
    }
}
