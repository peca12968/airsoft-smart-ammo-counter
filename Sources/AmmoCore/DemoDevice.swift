import Foundation

/// A wire-level mock peripheral. Real and demo transports exercise the same decoding/sync path.
@MainActor public final class DemoDevice: DeviceTransport {
    public var onEvent: ((TransportEvent) -> Void)?
    public private(set) var snapshot: DeviceSnapshot
    public let identity = DeviceIdentity(id: 0x44454D4F00000001)
    public private(set) var connected = false
    public var dropNextAck = false
    public var dropNextState = false
    public var trainingSignalScale: Double = 1
    private var liveTask: Task<Void,Never>?
    private var liveSeq: UInt16 = 0
    private var captureTask: Task<Void, Never>?
    private var trainingMode: UInt8 = 0
    private var trainingRequest: UInt32 = 0
    private var sent: UInt16 = 0
    private var model: DetectorProfile?
    private var acousticModel: AudioProfile?
    private var selectedModelID: UInt32 {acousticModel?.id ?? model?.id ?? 0}
    private var lastTraining: Data?
    private var uploadBytes = Data()
    private var uploadTransfer: UInt16 = 0
    private var modelURL: URL? { persistence?.url.deletingLastPathComponent().appendingPathComponent("demo-model.json") }
    private var resetBaseline: UInt32 = 0
    private var resetGeneration: UInt32 = 0
    private var resetStatus: CounterResetStatus {CounterResetStatus(baseline:resetBaseline,generation:resetGeneration,boot:snapshot.boot)}
    private var lastCommand: DeviceCommand?
    private var lastAck: CommandAck?
    private let persistence: PersistenceService?
    public init(persistence: PersistenceService? = nil) {
        self.persistence = persistence
        let saved = try? persistence?.load()
        resetBaseline=saved?.resetStatus?.baseline ?? 0;resetGeneration=saved?.resetStatus?.generation ?? 0
        if let url = persistence?.url.deletingLastPathComponent().appendingPathComponent("demo-model.json"), let data = try? Data(contentsOf: url), let bytes = try? JSONDecoder().decode(Data.self, from: data) { model = try? DetectorProfile(data: bytes);acousticModel=try? AudioProfile(data:bytes) }
        snapshot = saved?.snapshot ?? DeviceSnapshot(counter: try! AmmoCounter(capacity: 300, remaining: 247), battery: 82, flags: 33)
    }
    public func start() { connected = true; onEvent?(.audioSupport(true));onEvent?(.resetSupport(true)); onEvent?(.trainingSupport(true)); onEvent?(.liveSupport(true)); onEvent?(.identity(identity)); onEvent?(.status("Demo 已連線")); readState() }
    public func stop() { liveTask?.cancel(); captureTask?.cancel(); if trainingMode == 1 || trainingMode == 2 { trainingMode = 0 }; connected = false; onEvent?(.disconnected) }
    public func connect(_ id: UUID) { start() }
    public func readState() {
        guard connected else { return }
        if dropNextState { dropNextState = false; return }
        onEvent?(.state(snapshot.data));onEvent?(.resetStatus(resetStatus.data)); emitTrainingStatus()
    }
    public func send(_ data: Data) {
        guard connected, let command = try? DeviceCommand(data: data) else { return }
        let ack: CommandAck
        if command == lastCommand, let lastAck { ack = lastAck }
        else {
            var next = snapshot
            var result = AckResult.accepted
            if command.boot != snapshot.boot || command.expectedSequence != snapshot.sequence { result = .stale }
            else if snapshot.sequence == .max { result = .exhausted }
            else {
                do {
                    switch command.opcode {
                    case .reload: try next.counter.reload(capacity: Int(command.value))
                    case .correction:
                        guard (-9999...9999).contains(Int(command.value)) else { throw AmmoError.invalidValue }
                        next.counter.correct(by: Int(command.value))
                    case .setCapacity: try next.counter.setCapacity(Int(command.value))
                    case .resetTotal:
                        guard command.value==21075,resetGeneration<UInt32.max else {throw AmmoError.invalidValue}
                    
                    }
                    next.sequence += 1
                    if next.sequence == .max { next.flags |= 16 }
                    if command.opcode == .resetTotal {
                        let status=CounterResetStatus(baseline:next.counter.totalEvents,generation:resetGeneration+1,boot:next.boot)
                        try persistence?.save(DeviceState(identity:identity,snapshot:next,resetStatus:status))
                        resetBaseline=status.baseline;resetGeneration=status.generation
                    } else {try persist(next)}
                    snapshot = next
                } catch { result = error is AmmoError ? .invalid : .storageFailure }
            }
            ack = CommandAck(result: result, requestID: command.requestID, boot: snapshot.boot, sequence: snapshot.sequence)
            if result == .accepted { lastCommand = command; lastAck = ack }
        }
        if dropNextAck { dropNextAck = false } else { onEvent?(.ack(ack.data)) }
        readState()
    }
    public func simulateEvent() {
        guard snapshot.sequence < .max else { return }
        var next = snapshot; next.counter.recordEvent(); next.sequence += 1
        if next.sequence == .max { next.flags |= 16 }
        if next.counter.totalEvents == .max { next.flags |= 8 }
        do { try persist(next); snapshot = next; readState() } catch { onEvent?(.failure("Demo 保存失敗")) }
    }
    public func reboot() {
        guard snapshot.boot < .max else { return }
        var next = snapshot; next.boot += 1; next.sequence = 0; next.flags &= ~UInt8(16)
        do { try persist(next); snapshot = next; lastCommand = nil; lastAck = nil; if connected { start() } }
        catch { onEvent?(.failure("Demo 重啟保存失敗")) }
    }
    public func emitMalformed() { onEvent?(.state(Data([1, 0]))) }
    private func persist(_ next: DeviceSnapshot) throws { try persistence?.save(DeviceState(identity: identity, snapshot: next, resetStatus:resetStatus)) }
}

@MainActor extension DemoDevice {
    private func emitTrainingStatus(result: UInt8 = 0) {
        guard connected else { return }
        onEvent?(.trainingStatus(TrainingStatus.data(mode: trainingMode, result: result, modelID:selectedModelID, test:acousticModel?.isTest ?? model?.isTest ?? true, requestID: trainingRequest, sent: sent, boot: snapshot.boot)))
    }
    public func train(_ data: Data) {
        let data = Data(data)
        guard connected, data.count == 16, data[0] == 1, let op = TrainingOpcode(rawValue: data[1]), data.integer(UInt32.self, at: 8) == snapshot.boot else { return }
        trainingRequest = data.integer(UInt32.self, at: 4)
        if lastTraining == data { emitTrainingStatus(); return }
        lastTraining = data
        switch op {
        case .background, .positive:
            let duration = data.integer(UInt16.self, at: 2)
            guard (4...20).contains(duration), UInt16(truncatingIfNeeded: trainingRequest) != 0 else { emitTrainingStatus(result: 1); return }
            captureTask?.cancel(); trainingMode = op == .background ? 1:2; sent = 0; emitTrainingStatus()
            let id = UInt16(truncatingIfNeeded: trainingRequest), label: CaptureLabel = op == .background ? .background:.positive
            captureTask = Task { @MainActor [weak self] in
                for index in 1...Int(Double(duration)/0.04) {
                    do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
                    guard let self, self.connected else { return }
                    let candidate = index % 25 == 0
                    let scale = self.trainingSignalScale.isFinite ? min(1,max(0.01,self.trainingSignalScale)):1
                    let peak = label == .positive && candidate ? (0.20 + Double(index % 3)*0.002)*scale : (candidate ? 0.065:0.004)
                    let feature = VibrationFeature(captureID: id, sequence: UInt16(index), label: label, timestamp: UInt32(index*40), peakG: peak, rmsG: label == .positive && candidate ? 0.08*scale:peak/3, gyroDps: candidate && label == .background ? 35:5, candidate: candidate)
                    let target=label == .positive && candidate
                    let bandValues=target ? [0.02,0.04,0.08,0.4,0.3,0.1,0.04,0.02]:Array(repeating:0.125,count:8)
                    self.onEvent?(.audioSpectrum(AudioSpectrum.data(sequence:UInt16(index),captureID:id,rms:target ? 0.2*scale:0.002,bands:bandValues,dominantHz:target ? 1500:400,timestamp:UInt16(index*40))))
                    self.sent += 1; self.onEvent?(.trainingData(feature.data))
                }
                guard let self else { return }; self.trainingMode = 0; self.emitTrainingStatus()
            }
        case .preview:
            liveTask?.cancel()
            liveTask = Task { @MainActor [weak self] in
                for tick in 0..<200 {
                    do {try await Task.sleep(nanoseconds:100_000_000)}catch{return}
                    guard let self,self.connected else{return};self.liveSeq &+= 1;if self.liveSeq == 0 {self.liveSeq = 1}
                    let level: UInt16 = tick % 10 == 0 ? 4000:200
                    self.onEvent?(.audioSpectrum(AudioSpectrum.data(sequence:self.liveSeq,captureID:0,rms:0.002,bands:Array(repeating:0.125,count:8),dominantHz:400,timestamp:UInt16(truncatingIfNeeded:tick*100))))
                    self.onEvent?(.liveSignal(LiveSignal.data(sequence:self.liveSeq,timestamp:UInt32(tick*100),rms:level/2,peak:level,vibrationMG:tick%10 == 0 ? 12:2,samples:1600,boot:self.snapshot.boot)))
                }
            }
        case .stopPreview: liveTask?.cancel()
        case .stop: captureTask?.cancel(); trainingMode = 0; emitTrainingStatus()
        case .enable, .disable:
            guard selectedModelID != 0, selectedModelID == data.integer(UInt32.self, at: 12) else { emitTrainingStatus(result: 1); return }
            trainingMode = op == .enable ? 3:0; emitTrainingStatus()
        }
    }
    public func uploadProfile(_ chunks: [Data]) {
        guard connected, chunks.count == 4 else { return }
        var bytes = Data(); var transfer: UInt16 = 0
        for (index, input) in chunks.enumerated() {
            let d = Data(input)
            guard d.count == 20, d[0] == 1, Int(d[1]) == index else { emitTrainingStatus(result: 1); return }
            let next = d.integer(UInt16.self, at: 2); if index == 0 { transfer = next }
            guard transfer != 0, transfer == next else { emitTrainingStatus(result: 1); return }
            bytes.append(d[4..<20])
        }
        trainingRequest = UInt32(transfer)
        let profile=try? DetectorProfile(data:bytes),audio=try? AudioProfile(data:bytes)
        guard profile != nil || audio != nil else {emitTrainingStatus(result:1);return}
        if let url = modelURL {
            do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(bytes).write(to: url, options: .atomic) }
            catch { emitTrainingStatus(result: 4); return }
        }
        model = profile;acousticModel=audio; trainingMode = 0; emitTrainingStatus()
    }
    public func simulateTrainedEvent() { if trainingMode == 3 { simulateEvent() } }
}
