import Foundation

public struct DeviceState: Codable, Equatable {
    public let identity: DeviceIdentity
    public let snapshot: DeviceSnapshot
    public let resetStatus: CounterResetStatus?
    public let syncedAt: Date
    public init(identity: DeviceIdentity, snapshot: DeviceSnapshot, syncedAt: Date = Date(), resetStatus: CounterResetStatus? = nil) {
        self.identity = identity; self.snapshot = snapshot; self.syncedAt = syncedAt; self.resetStatus = resetStatus
    }
    public func isStale(at date: Date = Date()) -> Bool { date.timeIntervalSince(syncedAt) > 15 || date < syncedAt }
}
public enum SyncDisposition: Equatable { case accepted, duplicate, outdated, inconsistent }
public struct SnapshotSynchronizer {
    public private(set) var state: DeviceState?
    public init(state: DeviceState? = nil) { self.state = state }
    public mutating func ingest(identity: DeviceIdentity, snapshot: DeviceSnapshot, at date: Date = Date()) -> SyncDisposition {
        if let old = state, old.identity == identity {
            if snapshot.boot < old.snapshot.boot { return .outdated }
            guard snapshot.counter.totalEvents >= old.snapshot.counter.totalEvents else {return .inconsistent}
            if snapshot.boot == old.snapshot.boot {
                if snapshot.sequence < old.snapshot.sequence { return .outdated }
                if snapshot.sequence == old.snapshot.sequence {
                    guard snapshot == old.snapshot else { return .inconsistent }
                    state = DeviceState(identity: identity, snapshot: snapshot, syncedAt: date)
                    return .duplicate
                }
                guard snapshot.counter.totalEvents >= old.snapshot.counter.totalEvents else { return .inconsistent }
            }
        }
        state = DeviceState(identity: identity, snapshot: snapshot, syncedAt: date); return .accepted
    }
}

/// One outstanding command. An ATT write response alone never counts as an application ACK.
public struct CommandTracker {
    public private(set) var pending: DeviceCommand?
    public private(set) var acceptedSequence: UInt32?
    public init() {}
    public mutating func begin(_ command: DeviceCommand) -> Bool {
        guard pending == nil else { return false }; pending = command; acceptedSequence = nil; return true
    }
    public mutating func acknowledge(_ ack: CommandAck) -> Bool {
        guard let p = pending, ack.requestID == p.requestID, ack.boot == p.boot else { return false }
        if ack.result == .accepted {
            guard p.expectedSequence < .max, ack.sequence == p.expectedSequence + 1 else { return false }
            acceptedSequence = ack.sequence
        } else { pending = nil; acceptedSequence = nil }
        return true
    }
    public mutating func observe(_ snapshot: DeviceSnapshot) -> Bool {
        guard let p = pending else { return false }
        if snapshot.boot != p.boot { pending = nil; acceptedSequence = nil; return false }
        if let sequence = acceptedSequence, snapshot.sequence >= sequence {
            pending = nil; acceptedSequence = nil; return true
        }
        return false
    }
    public mutating func cancel() { pending = nil; acceptedSequence = nil }
}
