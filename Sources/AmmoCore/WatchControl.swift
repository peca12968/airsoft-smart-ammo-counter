import Foundation

/// Device-local settings: microphone models are never copied between devices.
public struct LocalDetectionSettings: Codable, Equatable, Sendable {
    public var mode: Int
    public var similarity: Double
    public var motionThreshold: Double
    public init(mode: Int = 0, similarity: Double = 0.85, motionThreshold: Double = 0.015) {
        self.mode = mode; self.similarity = similarity; self.motionThreshold = motionThreshold
    }
    public var valid: Bool {
        (0...2).contains(mode) && similarity.isFinite && (0.65...0.98).contains(similarity)
            && motionThreshold.isFinite && (0.003...0.2).contains(motionThreshold)
    }
}

public struct WatchControlRequest: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case status, settings, start, validate, validateSpeech, train, speechBackground, otherBackground, stop }
    public var version = 1
    public let id: UUID
    public let issuedAt: Double
    public let action: Action
    public let settings: LocalDetectionSettings?
    public init(action: Action, settings: LocalDetectionSettings? = nil, now: Double = Date().timeIntervalSince1970) {
        id = UUID(); issuedAt = now; self.action = action; self.settings = settings
    }
    public func rejection(now: Double, foreground: Bool, busy: Bool, hasModel: Bool) -> String? {
        guard version == 1, issuedAt.isFinite, abs(now - issuedAt) <= 30 else { return "指令已過期，請重新操作。" }
        if action == .status || action == .stop { return nil }
        guard foreground else { return "請先在手錶開啟 Ammo 雙端並抬腕。" }
        guard !busy else { return "手錶正在收錄或驗證，請先等待完成或停止。" }
        if action == .settings && settings?.valid != true { return "設定數值無效，未套用。" }
        if [.start,.validate,.validateSpeech,.speechBackground,.otherBackground].contains(action) && !hasModel { return "請先替手錶收錄主特徵。" }
        return nil
    }
}

public struct WatchControlStatus: Codable, Sendable {
    public var settings: LocalDetectionSettings
    public var phase: String
    public var detail: String
    public var busy: Bool
    public var hasModel: Bool
    public var validationHits: Int
    public var build: String
    public var canStart: Bool?
    public init(settings: LocalDetectionSettings, phase: String, detail: String, busy: Bool,
                hasModel: Bool, validationHits: Int, build: String,canStart:Bool?=nil) {
        self.settings = settings; self.phase = phase; self.detail = detail; self.busy = busy
        self.hasModel = hasModel; self.validationHits = validationHits; self.build = build
        self.canStart=canStart
    }
}
