import Foundation

/// One warning per magazine threshold, retained until notification scheduling
/// succeeds or an active-watch haptic consumes it.
public struct LowAmmoFeedback {
    public enum Warning:Int,Equatable {case low=1,empty=2}
    private var highest=0
    private var pending:Warning?
    public var pendingWarning:Warning? {pending}
    public init(){}
    public mutating func update(remaining:Int,capacity:Int){
        guard (1...9999).contains(capacity),(0...capacity).contains(remaining) else{return}
        let level=remaining==0 ? 2:(Double(remaining)/Double(capacity)<0.15 ? 1:0)
        if level==0 {highest=0;pending=nil;return}
        if level>highest {highest=level;pending=Warning(rawValue:level)}
    }
    public mutating func takePending(active:Bool)->Warning? {
        guard active else{return nil}
        defer {pending=nil};return pending
    }
    public mutating func acknowledge(_ warning:Warning){
        if pending==warning {pending=nil}
    }
}

/// Retry the identical unacknowledged batch; bound both time and memory.
public struct RelayRetryBudget {
    public static let maximumFrames=512
    public static let maximumWait:Double=4
    private var began:Double?
    public init(){}
    public mutating func begin(at now:Double){if began==nil {began=now}}
    public func expired(at now:Double)->Bool {
        guard let began else{return false}
        return !now.isFinite || now<began || now-began>=Self.maximumWait
    }
    public mutating func acknowledged(){began=nil}
}

/// Immediate phone-owned reload. Revision and expiry prevent a stale retry
/// from refilling a magazine again; lifetime/reset counters are untouched.
public struct MagazineReloadRequest:Codable,Sendable {
    public let id:UUID
    public let revision:UInt64
    public let issuedAt:Double
    public init(revision:UInt64,now:Double=Date().timeIntervalSince1970){id=UUID();self.revision=revision;issuedAt=now}
    public func apply(to ledger:inout LocalAmmoLedger,origin:String,now:Double)->Bool {
        guard ledger.valid,revision==ledger.revision,revision<UInt64.max,
              issuedAt.isFinite,now.isFinite,abs(now-issuedAt)<=10 else{return false}
        ledger.reload(origin:origin);return true
    }
}
