/// Screen dimming is a presentation change. It must not stop an existing,
/// explicitly started watch recording when audio background mode is enabled.
public enum CaptureSceneState:String, Codable, Sendable {
    case active, inactive, background
}

public enum CaptureLifecycle {
    public static func shouldStop(scene:CaptureSceneState,isWatch:Bool,
                                  recordingRunning:Bool,backgroundAudioEnabled:Bool)->Bool {
        guard scene != .active else{return false}
        return !(isWatch && recordingRunning && backgroundAudioEnabled)
    }
}
