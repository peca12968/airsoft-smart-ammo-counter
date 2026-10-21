import Foundation

public struct PersistenceService {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func save(_ state: DeviceState) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data=try JSONEncoder().encode(state)
        try data.write(to:url.appendingPathExtension("backup"),options:.atomic)
        try data.write(to: url, options: .atomic)
    }
    public func load() throws -> DeviceState? {
        guard FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath:url.appendingPathExtension("backup").path) else { return nil }
        let primary=try? decode(url),backup=try? decode(url.appendingPathExtension("backup"))
        if let a=primary,let b=backup {
            if a.identity==b.identity {
                if a.snapshot.counter.totalEvents != b.snapshot.counter.totalEvents {return a.snapshot.counter.totalEvents>b.snapshot.counter.totalEvents ? a:b}
                if (a.resetStatus?.generation ?? 0) != (b.resetStatus?.generation ?? 0) {return (a.resetStatus?.generation ?? 0)>(b.resetStatus?.generation ?? 0) ? a:b}
                if a.snapshot.boot != b.snapshot.boot {return a.snapshot.boot>b.snapshot.boot ? a:b}
                if a.snapshot.sequence != b.snapshot.sequence {return a.snapshot.sequence>b.snapshot.sequence ? a:b}
            }
            return a.syncedAt>=b.syncedAt ? a:b
        }
        if let state=primary ?? backup {return state}
        throw AmmoError.invalidValue
    }

    private func decode(_ file: URL) throws -> DeviceState {
        let state = try JSONDecoder().decode(DeviceState.self, from: Data(contentsOf: file))
        // Codable decoding bypasses normal initializers; re-validate all wire invariants.
        guard state.snapshot.counter.remaining >= 0,
              state.snapshot.counter.remaining <= state.snapshot.counter.capacity,
              (1...9999).contains(state.snapshot.counter.capacity),
              state.syncedAt.timeIntervalSince1970.isFinite else { throw AmmoError.invalidValue }
        _ = try DeviceSnapshot(data: state.snapshot.data)
        _ = try DeviceIdentity(data: state.identity.data)
        if let reset=state.resetStatus {
            _ = try CounterResetStatus(data:reset.data)
            guard reset.baseline<=state.snapshot.counter.totalEvents else {throw AmmoError.invalidValue}
        }
        return state
    }
}
