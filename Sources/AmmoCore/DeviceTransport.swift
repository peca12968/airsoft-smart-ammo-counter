import Foundation

public struct DiscoveredDevice: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public init(id: UUID, name: String, rssi: Int) { self.id = id; self.name = name; self.rssi = rssi }
}
public enum TransportEvent {
    case status(String), discovered([DiscoveredDevice]), identity(DeviceIdentity), state(Data), ack(Data), disconnected, failure(String)
    case safetySupport(Bool), safety(Data)
    case liveSupport(Bool), liveSignal(Data)
    case resetSupport(Bool), resetStatus(Data)
    case audioSupport(Bool), audioSpectrum(Data)
    case trainingSupport(Bool), trainingData(Data), trainingStatus(Data), trainingWriteFailure(String)
}
@MainActor public protocol DeviceTransport: AnyObject {
    var onEvent: ((TransportEvent) -> Void)? { get set }
    func start()
    func stop()
    func connect(_ id: UUID)
    func readState()
    func send(_ data: Data)
    func train(_ data: Data)
    func uploadProfile(_ chunks: [Data])
}

public extension DeviceTransport {
    func train(_ data: Data) { onEvent?(.trainingWriteFailure("此裝置未支援採集")) }
    func uploadProfile(_ chunks: [Data]) { onEvent?(.trainingWriteFailure("此裝置未支援模型")) }
}
