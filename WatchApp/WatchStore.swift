import Foundation
import Combine
#if os(watchOS)
import WatchKit
#elseif os(iOS)
import UIKit
#endif
import AmmoCore

@MainActor final class WatchStore: ObservableObject {
    @Published private(set) var state: DeviceState?
    @Published private(set) var audioSupported=false
    @Published private(set) var audioSpectrum: AudioSpectrum?
    @Published private(set) var audioReport: AudioTrainingReport?
    var hasTrainingReport: Bool {audioReport != nil || trainingReport != nil}
    private var selectedModelID: UInt32? {audioReport?.profile.id ?? trainingReport?.profile.id}
    @Published var sensitiveThresholdG: Double = 0.006
    @Published private(set) var resetSupported=false
    @Published private(set) var resetStatus: CounterResetStatus?
    @Published private(set) var resetFresh=false
    private var queuedResetStatus: CounterResetStatus?
    private var reportIdentity: UInt64?
    @Published var status = "尚未連線"
    @Published var message: String?
    @Published var devices: [DiscoveredDevice] = []
    @Published private(set) var connected = false
    @Published private(set) var pending = false
    @Published private(set) var stale = true
    @Published private(set) var demoMode: Bool
    @Published private(set) var safety: SafetyTelemetry?
    @Published private(set) var safetySupported = false
    @Published private(set) var safetyStale = true
    @Published private(set) var trainingSupported = false
    @Published private(set) var trainingState: TrainingStatus?
    @Published private(set) var captureDuration: Double = 12
    private var captureStopRequested = false
    @Published private(set) var capture: VibrationDataset?
    @Published private(set) var backgroundCapture: VibrationDataset?
    @Published private(set) var positiveCapture: VibrationDataset?
    @Published private(set) var trainingReport: TrainingReport?
    @Published private(set) var trainingBusy = false
    @Published var trainingText = "連線後可開始採集"
    @Published private(set) var trainingExport: URL?
    private var trainingExpected: UInt32?
    private var trainingDeadline = Date.distantPast
    private var trainingUpdated = Date.distantPast
    @Published private(set) var guidedActive = false
    @Published private(set) var guidedAnalyzing = false
    @Published private(set) var guidedRound = 0
    @Published private(set) var guidedPrompt = "按開始訓練，依提示安靜／敲桌面即可"
    private var guidedBackground: [VibrationDataset] = []
    private var guidedPositive: [VibrationDataset] = []
    private var guidedTest = true
    private var guidedTask: Task<Void, Never>?
    private var enableAfterUpload = false
    @Published private(set) var liveSupported = false
    @Published private(set) var liveMonitorEnabled = false
    @Published private(set) var audioWave: [Double] = []
    @Published private(set) var vibrationWave: [Double] = []
    @Published private(set) var audioActive = false
    @Published private(set) var liveUpdated = Date.distantPast
    private var lastLiveBoot: UInt32?
    private var lastLiveSequence: UInt16?
    private var safetyStream = SafetyStream()
    @Published var autoDemo = false
    @Published private(set) var demoDisconnected = false
    private var transport: DeviceTransport?
    private var demo: DemoDevice?
    private var sync = SnapshotSynchronizer()
    private var tracker = CommandTracker()
    private var identity: DeviceIdentity?
    private var timer: Timer?
    private var ticks = 0
    private var retryCount = 0
    private var commandTicks = 0
    private var active = true
    private let directory: URL
    private var persistence: PersistenceService {
        PersistenceService(url: directory.appendingPathComponent(demoMode ? "watch-demo.json" : "watch-device.json"))
    }
    var counter: AmmoCounter {
        guard let raw=state?.snapshot.counter else {return try! AmmoCounter()}
        let total=resetStatus?.reportedTotal(lifetime:raw.totalEvents) ?? raw.totalEvents
        return try! AmmoCounter(capacity:raw.capacity,remaining:raw.remaining,totalEvents:total)
    }
    var canResetTotal: Bool {canCommand && resetSupported && resetFresh && capture == nil && !trainingBusy}
    func resetTotalFromPhone() {guard canResetTotal else{return};command(.resetTotal,value:21075)}
    var batteryText: String {
        if !demoMode {
            guard connected, !stale, !safetySupported || !safetyStale else { return "—" }
            if safety?.usbPresent == true { return "USB · —" } // Cannot establish battery presence/SoC while charging.
        }
        guard let percent = state?.snapshot.battery else { return "—" }
        return demoMode ? "\(percent)%" : "估計 \(percent)%"
    }
    var canCommand: Bool { connected && !stale && !pending && (state?.snapshot.flags ?? 0) & 4 == 0 && (!safetySupported || (!safetyStale && safety?.isLocked == false && safety?.quarterDegrees != nil && (safety?.sample ?? 0) > 0)) }
    var safetyAttention: Bool { !demoMode && (!safetySupported || safetyStale || safety?.isWarning == true) }
    var safetyText: String {
        if demoMode { return "Demo · 無實體溫度監測" }
        if safety?.isLocked == true { return connected && !safetyStale ? "保護已啟動 · 計數暫停" : "曾啟動保護 · 離線／待更新" }
        guard connected else { return "安全監測離線" }
        guard safetySupported else { return "此韌體未提供安全監測" }
        guard let safety, !safetyStale else { return "安全資料待更新 · 校正暫停" }
        if safety.isLocked { return "保護已啟動 · 計數暫停" }
        if safety.isWarning { return "監測提醒：\(safetyReasonText)" }
        return safety.dieCelsius.map { String(format: "晶片 %.1f°C · 非電池溫度", $0) } ?? "晶片溫度未知"
    }
    var safetyReasonText: String {
        switch safety?.reason {
        case .hot: return "晶片溫度偏高"
        case .lowVoltage: return "電源電壓偏低"
        case .highVoltage: return "電源電壓偏高"
        case .temperatureUnavailable: return "晶片溫度讀取失敗"
        case .watchdog: return "先前程式停止回應"
        case .voltageUnavailable: return "電壓量測無效"
        default: return "尚無異常回報；不代表電池安全"
        }
    }
    var safetyDetails: String {
        if safety?.isLocked == true && safetyStale { return "\(safetyReasonText)（上次回報）。請拔 USB 並關閉電池開關。未量測電池溫度，韌體沒有切斷充電。" }
        guard let safety, !safetyStale else { return "尚無有效資料。未量測電池溫度，無法由韌體切斷充電。" }
        let volts = safety.millivolts.map { String(format: "VBAT 電源 %.3fV（未校準）", Double($0)/1000) } ?? "VBAT 電源未知"
        let charge = safety.chargeActive.map { $0 ? "充電指示有效" : "充電指示未啟動（不代表充滿）" } ?? "充電狀態未知"
        return "\(volts)\n\(safety.usbPresent ? "USB 已接上" : "USB 未接上") · \(charge)\n\(safetyReasonText)\n未量測電池溫度，韌體無法切斷充電。若異常，請拔 USB 並關閉電池開關。"
    }
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AirsoftAmmo")
        let smoke = ProcessInfo.processInfo.arguments.contains("--smoke-test")
        #if DEBUG
        if smoke, let root = ProcessInfo.processInfo.environment["AMMO_SMOKE_ROOT"] { directory = URL(fileURLWithPath: root) }
        else { directory = smoke ? base.appendingPathComponent("Smoke-" + UUID().uuidString) : base }
        #else
        directory = smoke ? base.appendingPathComponent("Smoke-" + UUID().uuidString) : base
        #endif
        demoMode = UserDefaults.standard.object(forKey: "demoMode") as? Bool ?? true
        if ProcessInfo.processInfo.arguments.contains("--demo") { demoMode = true }
        if ProcessInfo.processInfo.arguments.contains("--hardware") { demoMode = false; UserDefaults.standard.set(false, forKey: "demoMode") }
        configure()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--spectrum-smoke") {
            Task { @MainActor in
                for _ in 0..<150 {if self.canTrain && self.audioSupported {break};try? await Task.sleep(nanoseconds:200_000_000)}
                let before=self.state?.snapshot.counter.totalEvents ?? 0
                self.setLiveMonitor(true);self.startCapture(.background,duration:4)
                for _ in 0..<70 {try? await Task.sleep(nanoseconds:200_000_000);if self.capture == nil {break}}
                let frames=self.backgroundCapture?.audioFeatures ?? []
                let result:[String:Any] = ["connected":self.connected,"audioSupported":self.audioSupported,"audioFrames":frames.count,"audioUsable":frames.filter(\.usable).count,"frequencyHistogram":Dictionary(grouping:frames.filter(\.usable),by:{String($0.dominantHz)}).mapValues(\.count),"audioDropped":self.backgroundCapture?.audioDropped ?? 0,"dominantHz":frames.last?.dominantHz ?? 0,"IMUFrames":self.backgroundCapture?.features.count ?? 0,"lifetimeBefore":before,"lifetimeAfter":self.state?.snapshot.counter.totalEvents ?? 0,"displayTotal":self.counter.totalEvents,"resetFresh":self.resetFresh]
                self.setLiveMonitor(false)
                if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8){print("AMMO_SPECTRUM_SMOKE "+text);fflush(stdout)}
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--pause-model") {
            Task { @MainActor in
                for _ in 0..<150 {if self.canTrain {break};try? await Task.sleep(nanoseconds:200_000_000)}
                self.setDetectorEnabled(false)
                for _ in 0..<40 {try? await Task.sleep(nanoseconds:200_000_000);if !self.modelEnabled && !self.trainingBusy {break}}
                print("AMMO_MODEL_PAUSED enabled=\(self.modelEnabled) total=\(self.counter.totalEvents)");fflush(stdout)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--lifetime-smoke") {
            Task { @MainActor in
                for _ in 0..<150 {if self.canTrain && self.resetFresh {break};try? await Task.sleep(nanoseconds:200_000_000)}
                let before=self.state?.snapshot.counter.totalEvents ?? 0
                self.sensitiveThresholdG=0.006;self.enableSensitiveTrigger()
                for _ in 0..<75 {try? await Task.sleep(nanoseconds:200_000_000);if self.modelEnabled && self.trainingReport?.profile.detectionMode == .sensitive && !self.trainingBusy {break}}
                let result:[String:Any] = ["connected":self.connected,"resetSupported":self.resetSupported,"resetFresh":self.resetFresh,"rawLifetimeBefore":before,"rawLifetimeAfter":self.state?.snapshot.counter.totalEvents ?? 0,"displayTotal":self.counter.totalEvents,"resetBaseline":self.resetStatus?.baseline ?? 0,"resetGeneration":self.resetStatus?.generation ?? 0,"sensitiveProfile":self.trainingReport?.profile.detectionMode == .sensitive,"modelEnabled":self.modelEnabled,"onsetG":self.trainingReport?.profile.onsetG ?? 0,"minimumPeakG":self.trainingReport?.profile.minimumPeakG ?? 0,"text":self.trainingText]
                if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8){print("AMMO_LIFETIME_SMOKE "+text);fflush(stdout)}
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--capture-audit") {
            Task { @MainActor in self.printCaptureAudit() }
        }
        if ProcessInfo.processInfo.arguments.contains("--capture-smoke") {
            Task { @MainActor in
                for _ in 0..<150 {
                    if self.canTrain { break }
                    try? await Task.sleep(nanoseconds:200_000_000)
                }
                let before=self.state?.snapshot
                self.setLiveMonitor(true)
                self.startCapture(.background,duration:4)
                for _ in 0..<70 {
                    try? await Task.sleep(nanoseconds:200_000_000)
                    if self.capture == nil { break }
                }
                var result:[String:Any] = ["connected":self.connected,"audioPackets":self.audioWave.count,"microphoneActive":self.audioActive,"countsUnchanged":before?.counter.remaining == self.state?.snapshot.counter.remaining && before?.counter.totalEvents == self.state?.snapshot.counter.totalEvents]
                if let d=self.backgroundCapture {
                    let stable=d.features.filter{$0.flags&8==0}
                    let bad=stable.filter{!$0.usable}
                    result["frames"]=d.features.count;result["stable"]=stable.count;result["badStable"]=bad.count;result["gaps"]=d.features.filter{$0.flags&4 != 0}.count;result["dropped"]=d.dropped;result["completed"]=d.completed;result["duration"]=d.duration
                    result["qualityPassed"]=d.completed && stable.count>=30 && Double(bad.count)/Double(max(1,stable.count))<=0.1 && Double(d.dropped)/Double(max(1,d.features.count+d.dropped))<=0.05
                }
                self.setLiveMonitor(false)
                if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8){print("AMMO_CAPTURE_SMOKE "+text);fflush(stdout)}
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--live-smoke") {
            Task { @MainActor in
                for _ in 0..<100 {
                    if self.connected && self.liveSupported && self.canCommand { break }
                    try? await Task.sleep(nanoseconds:200_000_000)
                }
                self.setLiveMonitor(true)
                try? await Task.sleep(nanoseconds:3_000_000_000)
                let packetCount = self.audioWave.count
                let result:[String:Any] = ["connected":self.connected,"supported":self.liveSupported,"microphoneActive":self.audioActive,"packets":packetCount,"audioMaximum":self.audioWave.max() ?? 0,"vibrationMaximumG":self.vibrationWave.max() ?? 0]
                self.setLiveMonitor(false)
                if let data = try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]), let text = String(data:data,encoding:.utf8) { print("AMMO_LIVE_SMOKE " + text);fflush(stdout) }
            }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.runSmokeTest()
            }
        }
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    func setDemo(_ enabled: Bool) {
        guard enabled != demoMode else { return }
        transport?.onEvent = nil; transport?.stop()
        demoMode = enabled; UserDefaults.standard.set(enabled, forKey: "demoMode"); configure()
    }
    private func configure() {
        audioSupported=false;audioSpectrum=nil;audioReport=nil
        resetSupported=false;resetFresh=false;queuedResetStatus=nil;reportIdentity=nil
        liveMonitorEnabled = false;liveSupported = false;audioActive = false;audioWave = [];vibrationWave = [];lastLiveSequence = nil;liveUpdated = .distantPast
        guidedTask?.cancel(); guidedActive = false; guidedAnalyzing = false; enableAfterUpload = false
        trainingSupported = false; trainingState = nil; capture = nil; backgroundCapture = nil; positiveCapture = nil
        trainingReport = nil; trainingBusy = false; trainingExpected = nil; trainingExport = nil; trainingUpdated = .distantPast
        trainingText = "連線後可開始採集"
        safety = nil; safetySupported = false; safetyStale = true; safetyStream = SafetyStream()
        connected = false; stale = true; pending = false; demoDisconnected = false; autoDemo = false
        devices = []; identity = nil; tracker.cancel(); demo = nil
        do { state = try persistence.load() } catch { state = nil; message = "本機快取損壞，將從裝置重新同步" }
        resetStatus=state?.resetStatus
        sync = SnapshotSynchronizer(state: state)
        if demoMode {
            let d = DemoDevice(persistence: PersistenceService(url: directory.appendingPathComponent("demo-peripheral.json")))
            demo = d; transport = d
        } else { transport = BLEManager() }
        transport?.onEvent = { [weak self] in self?.receive($0) }
        transport?.start()
    }
    func setActive(_ value: Bool) {
        active = value
        if value { transport?.readState() }
        else { setLiveMonitor(false); if guidedActive { stopGuidedTraining() } else if capture != nil { stopCapture() }; stale = true }
    }
    private func tick() {
        guard active else { return }
        if trainingBusy && Date() > trainingDeadline {
            endCapture(completed: false); trainingBusy = false; trainingExpected = nil
            trainingText = "採集／模型確認逾時，請同步後檢查裝置狀態"; transport?.readState()
        }
        ticks += 1;
        if liveMonitorEnabled && (ticks % 10 == 0 || liveUpdated == .distantPast) && !trainingBusy && !guidedActive { sendLiveLease() }
        stale = !connected || (state?.isStale() ?? true)
        safetyStale = !connected || safetyStream.isStale() || safety?.boot != state?.snapshot.boot
        if ticks % 5 == 0 { transport?.readState() }
        if demoMode && autoDemo { demo?.simulateEvent() }
        if demoMode { demo?.simulateTrainedEvent() }
        if let command = tracker.pending {
            commandTicks += 1
            if commandTicks >= 3 {
                commandTicks = 0; retryCount += 1
                if retryCount <= 2 { transport?.send(command.data); transport?.readState() }
                else {
                    tracker.cancel(); pending = false; stale = true
                    message = "指令確認逾時，結果未知；請同步後檢查數值"; transport?.readState()
                }
            }
        }
    }
    private func receive(_ event: TransportEvent) {
        switch event {
        case .audioSupport(let supported):audioSupported=supported
        case .audioSpectrum(let data):
            guard let frame=try? AudioSpectrum(data:data) else {return}
            audioSpectrum=frame
            if var d=capture,frame.captureID==d.captureID {
                var frames=d.audioFeatures ?? []
                if let last=frames.last {let delta=frame.sequence &- last.sequence;if delta==0 || delta>32768 {return};d.audioDropped=(d.audioDropped ?? 0)+Int(delta-1)}
                guard frames.count<700 else{return};frames.append(frame);d.audioFeatures=frames;capture=d
            }
        case .resetSupport(let supported): resetSupported=supported
        case .resetStatus(let data):
            guard let reset=try? CounterResetStatus(data:data) else {message="累計重置資料無效，保留上次數值";return}
            queuedResetStatus=reset;acceptCounterReset()
        case .liveSupport(let supported): liveSupported = supported
        case .liveSignal(let data):
            guard let p = try? LiveSignal(data:data), p.boot == state?.snapshot.boot else { return }
            if lastLiveBoot == p.boot, let lastLiveSequence { let delta = p.sequence &- lastLiveSequence; guard delta > 0 && delta < 32768 else { return } }
            lastLiveBoot = p.boot;lastLiveSequence = p.sequence;liveUpdated = Date();audioActive = p.microphoneActive
            audioWave = Array((audioWave + [p.peak]).suffix(128));vibrationWave = Array((vibrationWave + [p.vibrationG]).suffix(128))
        case .trainingSupport(let supported): trainingSupported = supported
        case .trainingWriteFailure(let error):
            endCapture(completed: false); trainingBusy = false; trainingExpected = nil; trainingText = error
        case .trainingData(let data): acceptFeature(data)
        case .trainingStatus(let data): acceptTrainingStatus(data)
        case .safetySupport(let supported):
            safetySupported = supported; safety = nil; safetyStale = true; safetyStream = SafetyStream()
        case .safety(let data):
            do {
                let packet = try SafetyTelemetry(data: data)
                let result = safetyStream.ingest(packet, expectedBoot: state?.snapshot.boot)
                if result == .inconsistent { safetyStream.invalidateFreshness(); safetyStale = true; message = "安全監測狀態不一致，請重新同步" }
                guard result == .accepted || result == .duplicate else { return }
                let wasLocked = safety?.isLocked == true
                safety = safetyStream.latest; safetyStale = safetyStream.isStale() || packet.boot != state?.snapshot.boot
                if packet.isLocked && !wasLocked {
                    message = "\(safetyReasonText)。計數與校正已暫停；請拔 USB 並關閉電池開關。韌體沒有切斷充電。"
                    #if os(watchOS)
                    WKInterfaceDevice.current().play(.notification)
                    #elseif os(iOS)
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                    #endif
                }
            } catch { safetyStream.invalidateFreshness(); safetyStale = true; message = "安全監測封包無效，請重新同步" }
        case .status(let text): status = text
        case .discovered(let list): devices = list
        case .identity(let id):
            identity = id
            if !connected {
                // Disk cache is display-only while offline. A new GATT identity/read
                // handshake starts a live ordering epoch; firmware restoration can
                // legitimately reuse a persisted boot/sequence pair with different data.
                sync = SnapshotSynchronizer()
                if message == "狀態不一致，請重新連線" || message == "已忽略過期狀態" { message = nil }
            }
        case .disconnected:
            resetFresh=false;queuedResetStatus=nil
            audioActive = false;lastLiveSequence = nil;liveUpdated = .distantPast
            guidedTask?.cancel(); guidedActive = false; guidedAnalyzing = false; enableAfterUpload = false; guidedPrompt = "連線中斷，請重新開始訓練"
            endCapture(completed: false); trainingBusy = false; trainingExpected = nil; trainingState = nil; trainingUpdated = .distantPast
            safetyStale = true; safetyStream.invalidateFreshness()
            connected = false; stale = true; status = "已斷線 · 保留最後估計"
            if tracker.pending != nil { message = "連線中斷，指令結果未知；重連後請核對" }
            tracker.cancel(); pending = false
        case .failure(let error): message = error
        case .state(let data):
            guard let identity else { return }
            do {
                let snapshot = try DeviceSnapshot(data: data)
                // Keep a cross-reconnect high-water mark from the app's persistent state.
                // A reset changes only the reporting offset, never this lifetime count.
                if let old=state,old.identity==identity,snapshot.counter.totalEvents<old.snapshot.counter.totalEvents {
                    stale=true;message="裝置終身累計比已保存數值小，已保留原紀錄；請檢查裝置資料";return
                }
                let wasLow = state?.snapshot.counter.isLow ?? false
                let result = sync.ingest(identity: identity, snapshot: snapshot)
                guard result == .accepted || result == .duplicate else {
                    message = result == .outdated ? "已忽略過期狀態" : "狀態不一致，請重新連線"; return
                }
                if let p = tracker.pending, snapshot.boot != p.boot { message = "裝置已重新啟動，請核對數值" }
                _ = tracker.observe(snapshot); pending = tracker.pending != nil
                if state?.identity != identity {resetStatus=nil;resetFresh=false;trainingReport=nil;audioReport=nil;reportIdentity=nil}
                if let synced=sync.state {state=DeviceState(identity:identity,snapshot:synced.snapshot,syncedAt:synced.syncedAt,resetStatus:resetStatus)}
                connected = true; stale = false; status = demoMode ? "Demo 已同步" : "XIAO 已同步"
                acceptCounterReset();restoreTrainingReport()
                if let state { do { try persistence.save(state) } catch { message = "本機狀態保存失敗" } }
                if snapshot.counter.isLow && !wasLow {
                    #if os(watchOS)
                    WKInterfaceDevice.current().play(.notification)
                    #elseif os(iOS)
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    #endif
                }
            } catch { message = "已拒絕異常 BLE 封包" }
        case .ack(let data):
            guard let ack = try? CommandAck(data: data), tracker.acknowledge(ack) else { return }
            if ack.result != .accepted { message = "裝置拒絕指令（\(ack.result)），請同步後重試" }
            if let snapshot = state?.snapshot { _ = tracker.observe(snapshot) }
            pending = tracker.pending != nil; transport?.readState()
        }
    }
    func command(_ opcode: CommandOpcode, value: Int) {
        guard opcode != .resetTotal || canResetTotal else {return}
        guard capture == nil, canCommand, let snapshot = state?.snapshot, let value = Int16(exactly: value) else { return }
        let command = DeviceCommand(opcode: opcode, value: value, requestID: UInt32.random(in: 1...UInt32.max), expectedSequence: snapshot.sequence, boot: snapshot.boot)
        guard tracker.begin(command) else { return }
        retryCount = 0; commandTicks = 0; pending = true; transport?.send(command.data)
    }
    func select(_ id: UUID) { connected = false; stale = true; tracker.cancel(); pending = false; transport?.connect(id) }
    func rescan() { transport?.stop(); transport?.start() }
    func refresh() { transport?.readState() }
    func event() { demo?.simulateEvent() }
    func toggleDemoConnection() {
        demoDisconnected.toggle()
        if demoDisconnected { demo?.stop() } else { demo?.start() }
    }
    func rebootDemo() { demo?.reboot() }
    func malformedDemo() { demo?.emitMalformed() }
    func loseAckDemo() { demo?.dropNextAck = true; command(.correction, value: -1) }
}

#if DEBUG
extension WatchStore {
    /// Runtime integration checks inside the app process, isolated from user data.
    private func runSmokeTest() {
        setDemo(true)
        var checks = [[String: Any]]()
        func check(_ name: String, _ pass: Bool) { checks.append(["name": name, "passed": pass]) }
        check("initial Demo state", connected && counter.remaining == 247)
        event(); check("event decrements estimate", counter.remaining == 246 && counter.totalEvents == 1)
        for capacity in AmmoCounter.presets + [999] {
            command(.setCapacity, value: capacity)
            check("capacity \(capacity)", counter.capacity == capacity && counter.remaining <= capacity && !pending)
        }
        command(.correction, value: -9999); check("lower clamp and low threshold", counter.remaining == 0 && counter.isLow)
        command(.correction, value: 9999); check("upper clamp", counter.remaining == 999)
        command(.correction, value: -5); command(.reload, value: 300)
        check("reload and lifetime events", counter.remaining == 300 && counter.totalEvents == 1)
        loseAckDemo(); check("application ACK required", pending && counter.remaining == 299)
        active = true; for _ in 0..<3 { tick() }
        check("lost ACK retry exactly once", !pending && counter.remaining == 299)
        toggleDemoConnection(); let last = counter.remaining
        event(); check("offline keeps last synced value", !canCommand && counter.remaining == last)
        toggleDemoConnection(); check("reconnect authoritative device state", canCommand && counter.remaining == 298)
        malformedDemo(); check("malformed packet rejected", counter.remaining == 298 && message != nil); message = nil
        rebootDemo(); check("new boot accepted", state?.snapshot.boot == 2 && counter.remaining == 298)
        command(.setCapacity, value: 0); check("invalid command rejected", counter.capacity == 300 && !pending); message = nil
        let cached = try? persistence.load()
        check("watch persistence", cached == state)
        command(.correction, value: -51)
        let beforeSafety = counter
        receive(.safetySupport(true)); check("missing safety data blocks commands", !canCommand)
        func safetyPacket(sample: UInt32, locked: Bool) -> Data {
            var bytes: [UInt8] = [1, locked ? 15:3, 10,15, locked ? 240:100,0,0,255,locked ? 1:0,0,0,0,0,0,0,0,0,0,0,0]
            for i in 0..<4 { bytes[12+i] = UInt8(truncatingIfNeeded: sample >> (8*i)); bytes[16+i] = UInt8(truncatingIfNeeded: (state?.snapshot.boot ?? 1) >> (8*i)) }
            return Data(bytes)
        }
        receive(.safety(safetyPacket(sample: 1, locked: false)))
        check("fresh safety allows commands", canCommand)
        receive(.safety(safetyPacket(sample: 2, locked: true)))
        command(.correction, value: -1)
        check("safety lock prevents app mutation", !canCommand && counter == beforeSafety)
        receive(.safety(Data([1,0])))
        check("malformed safety blocks commands", !canCommand && safetyStale)
        receive(.safetySupport(false)); message = nil
        check("legacy transport remains compatible", canCommand)
        if let old = state?.snapshot, let id = identity {
            var authoritative = old; authoritative.counter.correct(by: -1)
            receive(.state(authoritative.data))
            check("live same-sequence conflict still rejected", counter == old.counter)
            receive(.disconnected); receive(.identity(id)); receive(.state(authoritative.data))
            check("fresh connection replaces conflicting disk cache", connected && counter == authoritative.counter)
            receive(.disconnected); receive(.identity(id)); receive(.state(old.data)); message = nil
        }
        let result: [String: Any] = ["passed": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks, "remaining": counter.remaining]
        let url = ProcessInfo.processInfo.environment["AMMO_SMOKE_RESULT"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("smoke-result.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url, options: .atomic) }
    }
}
#endif

// Phone training and demo use the same strict feature/model codecs.
extension WatchStore {
    var canTrain: Bool { canCommand && trainingSupported && !trainingBusy && capture == nil && trainingState != nil && Date().timeIntervalSince(trainingUpdated) < 10 && trainingState?.mode != 1 && trainingState?.mode != 2 }
    var modelEnabled: Bool { connected && trainingState?.mode == 3 }
    var modelDescription: String {
        if audioSupported && audioReport == nil {return "請重新收錄聲音頻譜，再啟用辨識"}
        guard let s = trainingState, s.hasModel else { return "尚無模型" }
        return "\(s.isTestModel ? "桌面敲擊測試" : "設備震動模型") · \(s.mode == 3 ? "自動計數啟用" : "自動計數暫停")"
    }
    func startCapture(_ label: CaptureLabel, duration: UInt16 = 12) {
        guard canTrain, (4...20).contains(duration), let state else { return }
        captureDuration = Double(duration); captureStopRequested = false
        let request = UInt32.random(in: 1...UInt32.max-1) | 1
        let dataset = VibrationDataset(deviceID: state.identity.id, boot: state.snapshot.boot, captureID: UInt16(truncatingIfNeeded: request), label: label)
        if label == .background { backgroundCapture = nil } else { positiveCapture = nil }
        trainingReport = nil; trainingExport = nil; capture = dataset; trainingBusy = true; trainingExpected = request
        trainingDeadline = Date().addingTimeInterval(Double(duration) + 8); autoDemo = false
        trainingText = label == .background ? "背景採集 \(duration) 秒；依上方提示操作" : "目標採集最多 \(duration) 秒；依上方提示操作"
        transport?.train(TrainingCommand(opcode: label == .background ? .background:.positive, value: duration, requestID: request, boot: state.snapshot.boot).data)
    }
    func stopCapture() {
        guard connected, !captureStopRequested, let state, capture != nil else { return }
        captureStopRequested = true
        let request = UInt32.random(in: 1...UInt32.max)
        trainingExpected = request; trainingDeadline = Date().addingTimeInterval(5)
        transport?.train(TrainingCommand(opcode: .stop, requestID: request, boot: state.snapshot.boot).data)
    }
    private func acceptFeature(_ data: Data) {
        guard var dataset = capture else { return }
        do {
            let feature = try VibrationFeature(data: data)
            guard feature.captureID == dataset.captureID, feature.label == dataset.label else { return }
            if let last = dataset.features.last, feature.sequence <= last.sequence {
                if dataset.features.first(where: { $0.sequence == feature.sequence }) != feature { dataset.dropped += 1; capture = dataset }
                return
            }
            guard dataset.features.count < 600 else { return }
            let expected = (dataset.features.last?.sequence ?? 0) + 1
            dataset.dropped += Int(feature.sequence - expected); dataset.features.append(feature); capture = dataset
            if guidedActive && dataset.label == .positive && Date().timeIntervalSince(dataset.startedAt) >= 4.1,
               let backgroundCapture, let baseline = try? VibrationTrainer.calibrate(background:backgroundCapture.features),
               VibrationTrainer.events(dataset.features,threshold:baseline.onsetG).count >= 3 { stopCapture() }
        } catch { dataset.dropped += 1; capture = dataset }
    }
    private func acceptTrainingStatus(_ data: Data) {
        guard let s = try? TrainingStatus(data: data), s.boot == state?.snapshot.boot else { return }
        trainingState = s; trainingUpdated = Date()
        if let dataset = capture, s.requestID == trainingExpected {
            if s.result != 0 { endCapture(completed: false); trainingBusy = false; trainingExpected = nil; trainingText = "裝置拒絕採集（\(s.result)），請重新同步"; return }
            if s.mode == 0 { endCapture(completed: true, sent: Int(s.sent), dropped: Int(s.dropped)); trainingBusy = false; trainingExpected = nil }
            else if (s.mode == 1 && dataset.label == .background) || (s.mode == 2 && dataset.label == .positive) { trainingBusy = true }
        } else if trainingExpected == s.requestID {
            trainingBusy = false; trainingExpected = nil
            if enableAfterUpload {
                enableAfterUpload = false
                if s.result == 0 && s.hasModel && s.modelID == selectedModelID {
                    Task { @MainActor in try? await Task.sleep(nanoseconds: 200_000_000); self.setDetectorEnabled(true) }
                }
            }
            trainingText = s.result == 0 ? (s.mode == 3 ? "自動計數已啟用；請敲擊測試並核對累計數" : "裝置已確認；可啟用模型或重新採集") : "裝置拒絕模型操作（\(s.result)）"
        }
    }
    private func endCapture(completed: Bool, sent: Int = 0, dropped: Int = 0) {
        guard var dataset = capture else { return }
        dataset.duration = Date().timeIntervalSince(dataset.startedAt); dataset.completed = completed
        dataset.dropped = max(dataset.dropped, dropped + max(0,sent-dataset.features.count))
        capture = nil
        if guidedActive {
            if completed { advanceGuidedTraining(dataset) }
            else { guidedTask?.cancel(); guidedActive = false; guidedAnalyzing = false; guidedPrompt = "採集已中止；請重新開始" }
        }
        if dataset.label == .background { backgroundCapture = dataset } else { positiveCapture = dataset }
        trainingText = completed ? "採集完成：\(dataset.features.count) 個特徵視窗；遺失 \(dataset.dropped)" : "採集未完成，請重新採集"
        do {
            let folder = directory.appendingPathComponent("Captures", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(dataset).write(to: folder.appendingPathComponent(dataset.id.uuidString + ".json"), options: .atomic)
            let url = folder.appendingPathComponent(dataset.id.uuidString + ".csv")
            try dataset.csv.write(to: url, atomically: true, encoding: .utf8); trainingExport = url
        } catch { trainingText += "；本機保存失敗" }
    }
    func analyzeTraining(isTest: Bool) {
        guard !trainingBusy, let backgroundCapture, let positiveCapture else { return }
        do {
            trainingReport = try VibrationTrainer.analyze(background: backgroundCapture, positive: positiveCapture, isTest: isTest)
            saveTrainingReport()
            trainingText = "分析完成。請先上傳，再啟用自動計數。"
        } catch {
            trainingReport = nil
            switch error as? TrainingFailure {
            case .insufficientSamples: trainingText = "樣本不足：測試需至少 6 次有效敲擊與 30 個背景視窗；實體模型另需移動／碰撞樣本"
            case .notSeparable: trainingText = "目前震動太相似或敲擊變化太大，暫不允許啟用；請重新採集"
            case .poorQuality: trainingText = captureQualityDetails
            default: trainingText = "採集尚未完成或來源不一致，請重新採集兩組資料"
            }
        }
    }
    func uploadTraining() {
        guard canTrain,hasTrainingReport, let state, reportIdentity == state.identity.id else { return }
        let transfer = UInt16.random(in: 1...UInt16.max)
        trainingBusy = true; trainingExpected = UInt32(transfer); trainingDeadline = Date().addingTimeInterval(15); trainingText = "上傳模型並等待裝置保存確認…"
        if let report=audioReport {transport?.uploadProfile(report.profile.chunks(transferID:transfer))}
        else if let report=trainingReport {transport?.uploadProfile(report.profile.chunks(transferID:transfer))}
    }
    func setDetectorEnabled(_ enabled: Bool) {
        guard canTrain, let state, let s = trainingState, s.hasModel else { return }
        let request = UInt32.random(in: 65536...UInt32.max)
        trainingBusy = true; trainingExpected = request; trainingDeadline = Date().addingTimeInterval(8)
        transport?.train(TrainingCommand(opcode: enabled ? .enable:.disable, requestID: request, boot: state.snapshot.boot, modelID: s.modelID).data)
    }
}

extension WatchStore {
    func startGuidedTraining(isTest: Bool) {
        guard canTrain else { return }
        guidedTask?.cancel(); guidedBackground = []; guidedPositive = []
        guidedTest = isTest; guidedRound = 1; guidedActive = true; guidedAnalyzing = false
        trainingReport = nil;audioReport=nil; guidedPrompt = "先量底噪 4 秒：固定板子，保持桌面安靜，現在不要敲"
        startCapture(.background, duration: 4)
    }
    func stopGuidedTraining() {
        guidedTask?.cancel(); guidedActive = false; guidedAnalyzing = false; guidedPrompt = "已停止，可隨時重新開始"
        stopCapture()
    }
    private func advanceGuidedTraining(_ dataset: VibrationDataset) {
        if dataset.label == .background { guidedBackground.append(dataset) } else { guidedPositive.append(dataset) }
        guidedTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard self.guidedActive else { return }
            if dataset.label == .background {
                self.guidedPrompt = self.guidedTest ? "等 1 秒後，在板子旁敲桌面 3–5 次，每次隔約 1 秒；收足會提前結束" : "先等 1 秒，再重複目標設備震動 3–5 次，並人工核對次數"
                self.startCapture(.positive, duration: 8); return
            }
            self.guidedAnalyzing = true; self.guidedPrompt = "分析中，現在先不要敲桌面"
            do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
            guard self.guidedActive else { return }
            do {
                if self.audioSupported {
                    self.audioReport=try self.analyzeAudioCaptures()
                    self.trainingReport=try? VibrationTrainer.analyzeSeries(background:self.guidedBackground,positive:self.guidedPositive,isTest:self.guidedTest,relaxed:true)
                } else {self.trainingReport=try VibrationTrainer.analyzeSeries(background:self.guidedBackground,positive:self.guidedPositive,isTest:self.guidedTest,relaxed:true)}
                self.saveTrainingReport(); self.guidedActive = false; self.guidedAnalyzing = false
                self.guidedPrompt = self.audioReport != nil ? "聲音頻譜已收足，可以套用辨識；相似聲音仍可能誤判":"樣本已收足，可以套用；相似震動也可能被計數"; self.trainingText = "訓練完成；尚未啟用新模型"
            } catch {
                self.guidedAnalyzing = false
                let dataSummary = self.captureSummary
                if error as? TrainingFailure == .noSignal || error as? TrainingFailure == .poorQuality || self.backgroundCapture?.features.isEmpty == true || self.positiveCapture?.features.isEmpty == true {
                    self.guidedActive = false
                    self.guidedPrompt = error as? TrainingFailure == .noSignal ? (self.audioSupported ? "沒有找到高於底噪的敲擊聲，請在 XIAO 麥克風附近敲桌面後重試":"沒有找到高於底噪的敲擊。請固定板邊、USB 線留鬆弛，在板子旁敲桌面後重試") : "採集品質未通過：\(self.captureQualityDetails)"
                    self.trainingText = dataSummary; return
                }
                guard self.guidedRound < 6 else {
                    self.guidedActive = false; self.guidedPrompt = "6 輪仍未取得足夠有效樣本，已停止。請調整固定方式或敲擊力道後重試"; return
                }
                self.guidedRound += 1
                self.guidedPrompt = "已保留底噪，再補敲幾次：等 1 秒後，每秒敲桌面一次"
                self.startCapture(.positive, duration: 8)
            }
        }
    }
    func applyAndEnableTraining() { guard !audioSupported || audioReport != nil else{return};guard canTrain, hasTrainingReport else { return }; enableAfterUpload = true; uploadTraining() }
}

#if DEBUG
extension WatchStore { func setDemoTrainingSignal(scale: Double) { demo?.trainingSignalScale = scale } }
#endif

extension WatchStore {
    var captureQualityDetails: String {
        [backgroundCapture,positiveCapture].compactMap { d -> String? in
            guard let d else{return nil}
            let stable=d.features.filter{$0.flags&8==0}
            let gaps=stable.filter{$0.flags&4 != 0}.count,clips=stable.filter{$0.flags&2 != 0}.count
            let name=d.label == .background ? "背景":"敲擊"
            return "\(name)：收到 \(d.features.count) 包，穩定視窗 \(stable.count)，間隙 \(gaps)，飽和 \(clips)，遺失 \(d.dropped)"
        }.joined(separator:"\n")
    }
    var captureSummary: String {
        let d = capture ?? positiveCapture ?? backgroundCapture
        guard let d else { return "尚未收到 IMU 特徵" }
        let good = d.features.filter(\.usable), gaps = d.features.filter { $0.flags & 4 != 0 }.count
        let peak = good.map(\.peakG).max() ?? 0
        let baseline = backgroundCapture.flatMap { try? VibrationTrainer.calibrate(background:$0.features) }
        let events = baseline.map { VibrationTrainer.events(d.features,threshold:$0.onsetG).count } ?? 0
        let threshold = baseline.map { String(format:"%.3fg",$0.onsetG) } ?? "量測中"
        return "收到 \(d.features.count) 包 · 有效視窗 \(good.count) · 遺失 \(d.dropped) · 間隙 \(gaps)\n峰值 \(String(format:"%.3fg",peak)) · 門檻 \(threshold) · 敲擊峰值 \(events) 次"
    }
}

extension WatchStore {
    func setLiveMonitor(_ enabled: Bool) {
        liveMonitorEnabled = enabled
        if enabled { sendLiveLease() }
        else if connected, liveSupported, let s = state { transport?.train(TrainingCommand(opcode:.stopPreview,requestID:UInt32.random(in:1...UInt32.max),boot:s.snapshot.boot).data);audioActive = false }
    }
    private func sendLiveLease() {
        guard liveMonitorEnabled, liveSupported, canCommand, capture == nil, let s = state else { return }
        transport?.train(TrainingCommand(opcode:.preview,value:20,requestID:UInt32.random(in:1...UInt32.max),boot:s.snapshot.boot).data)
    }
}

#if DEBUG
extension WatchStore {
    private func printCaptureAudit() {
        let folder = directory.appendingPathComponent("Captures")
        let files = (try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []
        let datasets = files.filter{$0.pathExtension=="json"}.compactMap { try? JSONDecoder().decode(VibrationDataset.self,from:Data(contentsOf:$0)) }.sorted{$0.startedAt > $1.startedAt}
        var summaries = [[String:Any]]()
        for d in datasets.prefix(14) {
            let stable = d.features.filter{$0.flags & 8 == 0}
            let bad = stable.filter{!$0.usable}
            let peaks = d.features.filter(\.usable).map(\.peakG).sorted()
            summaries.append(["label":d.label.rawValue,"duration":d.duration,"completed":d.completed,"frames":d.features.count,"dropped":d.dropped,"gapFrames":d.features.filter{$0.flags&4 != 0}.count,"clipFrames":d.features.filter{$0.flags&2 != 0}.count,"settlingFrames":d.features.filter{$0.flags&8 != 0}.count,"stable":stable.count,"badStable":bad.count,"maxPeak":peaks.max() ?? 0,"medianPeak":peaks.isEmpty ? 0:peaks[peaks.count/2],"started":d.startedAt.timeIntervalSince1970])
        }
        var outcome = "missing datasets"
        if let background=datasets.first(where:{$0.label == .background}) {
            let positives = datasets.filter{$0.label == .positive && $0.startedAt > background.startedAt && $0.boot == background.boot}.reversed()
            do { _ = try VibrationTrainer.analyzeSeries(background:[background],positive:Array(positives.suffix(6)),isTest:true,relaxed:true);outcome="accepted" }
            catch {outcome=String(describing:error)}
        }
        let result:[String:Any] = ["datasets":summaries,"latestAnalysis":outcome]
        if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8){print("AMMO_CAPTURE_AUDIT "+text);fflush(stdout)}
    }
}
#endif

extension WatchStore {
    private func acceptCounterReset() {
        guard let reset=queuedResetStatus,let current=state,reset.boot==current.snapshot.boot else {return}
        guard reset.baseline<=current.snapshot.counter.totalEvents else {transport?.readState();return}
        if let old=resetStatus {
            guard reset.generation>=old.generation else {return}
            guard reset.generation != old.generation || reset.baseline==old.baseline else {message="累計重置紀錄不一致，保留原值";return}
            guard reset.baseline>=old.baseline else {message="累計重置基準過期，保留原值";return}
        }
        resetStatus=reset;resetFresh=true;queuedResetStatus=nil
        let next=DeviceState(identity:current.identity,snapshot:current.snapshot,syncedAt:current.syncedAt,resetStatus:reset)
        do {try persistence.save(next);state=next} catch {message="累計重置狀態保存失敗，請同步"}
    }
    private var reportURL: URL? {
        guard let state else{return nil}
        return directory.appendingPathComponent("training-report-"+String(state.identity.id,radix:16)+".json")
    }
    private func saveTrainingReport() {
        guard let url=reportURL,let state else{return}
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            if let report=trainingReport {try JSONEncoder().encode(report).write(to:url,options:.atomic)}
            if let report=audioReport {try JSONEncoder().encode(report).write(to:url.appendingPathExtension("audio"),options:.atomic)}
            reportIdentity=state.identity.id
        } catch {trainingText="模型本機保存失敗，請重新採集"}
    }
    private func restoreTrainingReport() {
        guard reportIdentity != state?.identity.id,let url=reportURL else{return}
        if let data=try? Data(contentsOf:url.appendingPathExtension("audio")),let report=try? JSONDecoder().decode(AudioTrainingReport.self,from:data),(try? AudioProfile(data:report.profile.data)) != nil {audioReport=report;reportIdentity=state?.identity.id}
        if let data=try? Data(contentsOf:url),let report=try? JSONDecoder().decode(TrainingReport.self,from:data),(try? DetectorProfile(data:report.profile.data)) != nil {trainingReport=report;sensitiveThresholdG=min(0.05,max(0.002,report.profile.onsetG));reportIdentity=state?.identity.id}
    }
    private func analyzeAudioCaptures() throws -> AudioTrainingReport {
        for d in guidedBackground+guidedPositive {
            let frames=d.audioFeatures ?? [],lost=d.audioDropped ?? 0,stable=frames.filter{$0.flags&8==0}
            guard !frames.isEmpty,Double(lost)/Double(max(1,frames.count+lost))<=0.05,Double(stable.filter{!$0.usable}.count)/Double(max(1,stable.count))<=0.1 else {throw TrainingFailure.poorQuality}
        }
        return try AudioTrainer.analyze(background:guidedBackground.flatMap{$0.audioFeatures ?? []},positive:guidedPositive.flatMap{$0.audioFeatures ?? []},isTest:guidedTest)
    }

    func enableSensitiveTrigger() {
        guard !audioSupported else {trainingText="請重新收錄聲音頻譜";return}
        guard canTrain,let state else{return}
        do {
            if trainingReport == nil {
                let folder=directory.appendingPathComponent("Captures")
                let files=(try? FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)) ?? []
                let datasets=files.filter{$0.pathExtension=="json"}.compactMap{try? JSONDecoder().decode(VibrationDataset.self,from:Data(contentsOf:$0))}.filter{$0.deviceID==state.identity.id && $0.completed}.sorted{$0.startedAt<$1.startedAt}
                guard let background=datasets.last(where:{$0.label == .background}),let positive=datasets.last(where:{$0.label == .positive && $0.boot==background.boot && $0.startedAt>background.startedAt}) else {trainingText="請先按開始訓練，完成一次靜置與敲擊採集";return}
                trainingReport=try VibrationTrainer.analyze(background:background,positive:positive,isTest:true,relaxed:true)
            }
            trainingReport=try trainingReport?.withSensitiveTrigger(onsetG:sensitiveThresholdG);saveTrainingReport()
            enableAfterUpload=true;uploadTraining()
        } catch {trainingText="現有樣本無法建立高靈敏模型；請重新訓練。\(error)"}
    }
}

#if os(iOS) || os(watchOS)
import AVFoundation
import Accelerate
import CoreMotion
import WatchConnectivity

private final class LocalAudioProcessor: @unchecked Sendable {
    let queue=DispatchQueue(label:"ammo.local.dsp",qos:.userInteractive)
    var onFrame:((AudioSpectrum,Double,Double,Int)->Void)?
    var onShot:((Double)->Void)?
    var profile:AudioProfile?
    var refined:RefinedAcousticModel?
    var onDecision:((String,Double)->Void)?
    private var refinedDetector=LocalAcousticDetector()
    var triggerMode=0 // 0=spectrum, 1=spectrum+motion, 2=motion
    var motionThreshold=0.015
    var armed=false
    private var gate=LocalTriggerGate()
    private var windows:AudioWindowStream?
    private var analyzer:RealtimeSpectrumAnalyzer?
    private var motionFrames=0
    private var motionPeak=0.0,motionAt=0.0
    private let ringLock=NSLock()
    private var ring=[Float](repeating:0,count:32768)
    private var ringRead=0,ringWrite=0
    private var ringEndingAt:Double?
    private var ringDiscontinuous=false
    private var lastDecisionAt:Double = -.infinity
    private var wake:DispatchSourceUserDataAdd!
    init(){
        wake=DispatchSource.makeUserDataAddSource(queue:queue)
        wake.setEventHandler{[weak self] in self?.drain()};wake.resume()
    }
    func configure(rate:Double){queue.async {
        self.ringLock.lock();self.ringRead=0;self.ringWrite=0;self.ringEndingAt=nil;self.ringDiscontinuous=false;self.ringLock.unlock()
        self.analyzer=RealtimeSpectrumAnalyzer(sampleRate:rate)
        self.windows=self.analyzer.flatMap{AudioWindowStream(sampleRate:rate,size:$0.size)}
        self.gate=LocalTriggerGate();self.refinedDetector=LocalAcousticDetector()
    }}
    // Called by the audio IO thread: bounded copy, never waits on a lock or runs FFT.
    func ingest(_ pointer:UnsafePointer<Float>,count:Int,stride:Int,endingAt:Double){
        guard ringLock.try() else{return}
        let available=(ringRead-ringWrite+ring.count-1)%ring.count
        // If overloaded, discard the old backlog instead of joining audio across
        // a dropped buffer. Drain will reset analysis before processing fresh data.
        if count>available {ringRead=0;ringWrite=0;ringDiscontinuous=true}
        guard count<ring.count else{ringEndingAt=nil;ringLock.unlock();wake.add(data:1);return}
        for i in 0..<count {let next=(ringWrite+1)%ring.count;if next==ringRead {break};ring[ringWrite]=pointer[i*stride];ringWrite=next}
        ringEndingAt=endingAt
        ringLock.unlock();wake.add(data:1)
    }
    private func drain(){
        ringLock.lock();var chunk=[Float]();chunk.reserveCapacity((ringWrite-ringRead+ring.count)%ring.count)
        while ringRead != ringWrite {chunk.append(ring[ringRead]);ringRead=(ringRead+1)%ring.count}
        let audioEnd=ringEndingAt,discontinuous=ringDiscontinuous;ringDiscontinuous=false;ringLock.unlock()
        guard !chunk.isEmpty,windows != nil else{return}
        if discontinuous,let analyzer {
            windows=AudioWindowStream(sampleRate:analyzer.sampleRate,size:analyzer.size)
            gate=LocalTriggerGate();refinedDetector=LocalAcousticDetector()
        }
        let previousGaps=windows!.discontinuities
        guard let audioEnd else{return}
        let frames=windows!.append(chunk,endingAt:audioEnd)
        if windows!.discontinuities != previousGaps {gate=LocalTriggerGate();refinedDetector=LocalAcousticDetector()}
        for frame in frames {process(frame.samples,time:frame.endingAt)}
    }
    func motion(_ peak:Double,time:Double){queue.async {
        self.motionFrames+=1
        if time-self.motionAt>0.08 {self.motionPeak=peak}else{self.motionPeak=max(peak,self.motionPeak*0.85)};self.motionAt=time
        if self.armed && self.triggerMode==1,let model=self.refined,peak>=self.motionThreshold,self.refinedDetector.confirmMotion(time:time,refractory:Double(model.base.refractoryMs)/1000){self.onShot?(self.refinedDetector.eventTime ?? time)}
        if self.armed && self.triggerMode==2 && self.gate.update(match:peak>=self.motionThreshold,quiet:peak<self.motionThreshold*0.45,time:time){self.onShot?(time)}
    }}
    private func process(_ samples:[Float],time now:Double) {
        let analysisStarted=ProcessInfo.processInfo.systemUptime
        guard let analyzer,let spectrum=analyzer.analyze(samples,timestamp:UInt16(truncatingIfNeeded:UInt64(now*1000))) else{return}
        let movement=abs(now-motionAt)<0.15 ? motionPeak:0
        onFrame?(spectrum,movement,(ProcessInfo.processInfo.systemUptime-analysisStarted)*1000,motionFrames)
        guard armed,triggerMode != 2,let profile else{return}
        if let model=refined {
            let hit=refinedDetector.update(spectrum,time:now,model:model,needsMotion:triggerMode==1,motionOK:movement>=motionThreshold)
            if now-lastDecisionAt>=0.06 {lastDecisionAt=now;onDecision?(refinedDetector.decision.text,refinedDetector.score)}
            if hit {onShot?(refinedDetector.eventTime ?? now)};return
        }
        let match=profile.accepts(spectrum) && (triggerMode==0 || movement>=motionThreshold)
        if gate.update(match:match,quiet:spectrum.rms<profile.rearm,time:now,refractory:Double(profile.refractoryMs)/1000){onShot?(now)}
    }

}

@MainActor final class LocalAmmoStore:NSObject,ObservableObject,WCSessionDelegate {
    @Published private(set) var ledger:LocalAmmoLedger
    @Published private(set) var listening=false
    @Published private(set) var armed=false
    @Published private(set) var spectrum:AudioSpectrum?
    @Published private(set) var motionG=0.0
    @Published private(set) var motionSamples=0
    @Published private(set) var spectrumWave=[Double]()
    @Published private(set) var motionWave=[Double]()
    @Published private(set) var validating=false
    @Published private(set) var validationHits=0
    @Published private(set) var validationExpected=5
    @Published private(set) var validationURL:URL?
    @Published private(set) var maximumAnalysisMS=0.0
    private var validationFrames=[AudioSpectrum]()
    @Published private(set) var refinedReport:RefinedAcousticReport?
    @Published private(set) var decisionText="等待收錄特徵"
    @Published private(set) var matchScore=0.0
    @Published private(set) var report:AudioTrainingReport?
    @Published private(set) var training=false
    @Published private(set) var phase="待命"
    @Published private(set) var detail="先收錄特徵，再啟用本機辨識。"
    @Published private(set) var paired=false
    @Published private(set) var dualStatus="手機單端偵測 · 同一事件只入帳一次"
    @Published var triggerMode=0 {didSet {applyProcessor()}}
    @Published var motionThreshold=0.015 {didSet {applyProcessor()}}
    @Published var similarity=0.85 {didSet {applyProcessor()}}
    @Published var message:String?
    private let origin:String
    private let folder:URL
    private let processor=LocalAudioProcessor()
    private let audioEngine=AVAudioEngine()
    private let motion=CMMotionManager()
    private let motionQueue=OperationQueue()
    private var task:Task<Void,Never>?
    private var quietFrames=[AudioSpectrum](),targetFrames=[AudioSpectrum]()
    private var collectedMotion=[Double]()
    private var trainingPhase=0
    private var lastPaint=Date.distantPast
    private var session:WCSession?
    private var observation:NSObjectProtocol?
    private var sinkNode:AVAudioSinkNode?
    private var clock:SoundClockEstimate?
    private var clockTask:Task<Void,Never>?
    private var clockBusy=false
    private var sendingSounds=false
    private var dualPeer=false
    private var awaitingPhoneSnapshot=false

    private var refinedURL:URL {folder.appendingPathComponent("local-acoustic-v2.json")}
    private var modelURL:URL {folder.appendingPathComponent("local-audio-model.json")}
    private var ledgerURL:URL {folder.appendingPathComponent("local-counter.json")}
    var remaining:Int {ledger.remaining}
    var total:UInt64 {ledger.total}
    var relativeLevelText:String {
        guard let spectrum,let model=refinedReport?.model else{return "相對音量：等待收音"}
        let current=20*log10(max(0.00001,spectrum.rms)),minimum=20*log10(max(0.00001,model.minimumEventPeakRMS))
        return String(format:"相對音量 %.0f dBFS · 事件峰值下限 %.0f dBFS",current,minimum)
    }

    override init(){
        folder=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("AirsoftAmmo")
        if let saved=UserDefaults.standard.string(forKey:"local-origin") {origin=saved}else{origin=UUID().uuidString;UserDefaults.standard.set(origin,forKey:"local-origin")}
        var initial:LocalAmmoLedger?
        for url in [folder.appendingPathComponent("local-counter.json"),folder.appendingPathComponent("local-counter.json.backup")] {
            if let data=try? Data(contentsOf:url),let value=try? JSONDecoder().decode(LocalAmmoLedger.self,from:data),value.valid {if initial==nil {initial=value}else{initial?.merge(value)}}
        }
        if let initial {ledger=initial}else{
            let old=try? PersistenceService(url:folder.appendingPathComponent("watch-device.json")).load()
            let raw=UInt64(old?.snapshot.counter.totalEvents ?? 0)
            var migrated=LocalAmmoLedger(seed:raw,capacity:old?.snapshot.counter.capacity ?? 300,remaining:old?.snapshot.counter.remaining ?? 300,editor:origin)
            migrated.resetBaseline=UInt64(old?.resetStatus?.baseline ?? 0);ledger=migrated
        }
        super.init()
        #if os(watchOS)
        awaitingPhoneSnapshot = !UserDefaults.standard.bool(forKey:"watch-phone-snapshot-v1")
        #endif
        if ledger.soundFusion==nil {ledger.soundFusion=SoundFusionState(owner:origin)}
        UserDefaults.standard.set(false,forKey:"adaptive-background-enabled")
        #if DEBUG
        let arguments=ProcessInfo.processInfo.arguments
        if let index=arguments.firstIndex(of:"--legacy-lifetime-floor"),arguments.indices.contains(index+1),let value=UInt64(arguments[index+1]),ledger.resetRevision==0 {ledger.seed=max(ledger.seed,value)}
        #endif
        if let data=try? Data(contentsOf:modelURL),let saved=try? JSONDecoder().decode(AudioTrainingReport.self,from:data),(try? AudioProfile(data:saved.profile.data)) != nil {report=saved;similarity=saved.profile.minimumSimilarity}
        for file in [refinedURL,refinedURL.appendingPathExtension("backup")] {
            if let data=try? Data(contentsOf:file),let saved=try? JSONDecoder().decode(RefinedAcousticReport.self,from:data),saved.model.valid {refinedReport=saved.withoutAutomaticBackground();report=saved.legacyReport;similarity=saved.model.minimumScore;break}
        }
        processor.onDecision={[weak self] reason,score in Task{@MainActor in
            guard let self,self.listening else{return};if self.decisionText != reason || abs(self.matchScore-score)>0.03 {self.decisionText=reason;self.matchScore=score}
        }}
        processor.onFrame={[weak self] frame,peak,block,count in Task{@MainActor in self?.accept(frame,peak:peak,block:block,motionCount:count)}}
        processor.onShot={[weak self] onset in
            let wallTime=Date().timeIntervalSince1970+onset-ProcessInfo.processInfo.systemUptime
            Task{@MainActor in self?.shot(at:wallTime)}
        }
        motionQueue.maxConcurrentOperationCount=1
        if WCSession.isSupported(){let wc=WCSession.default;session=wc;wc.delegate=self;wc.activate()}
        observation=NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.stop();self?.detail="音訊被系統中斷，請再次開始監聽。"}}
        persist()
        if refinedReport != nil {
            do {try saveRefinedReport()}catch{message="主特徵已載入，但模型保存失敗；請檢查儲存空間。"}
            detail="主特徵已保留，按開始即可計數；不會自動學習背景。"
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--local-mic-smoke") {
            Task{@MainActor in
                await self.start();try? await Task.sleep(nanoseconds:4_000_000_000)
                let result:[String:Any] = ["build":"semiauto-level-20261021","listening":self.listening,"spectrumFrames":self.spectrumWave.count,"dominantHz":self.spectrum?.dominantHz ?? 0,"motionAvailable":self.motion.isDeviceMotionAvailable,"motionSamples":self.motionSamples,"pairedReachable":self.paired,"total":self.total,"lifetime":self.ledger.lifetime,"maximumRMS":self.spectrumWave.max() ?? 0,"denseFeaturesValid":self.spectrum?.dense?.valid ?? false,"maximumFFTAnalysisMS":self.maximumAnalysisMS,"refinedModelLoaded":self.refinedReport?.model.valid ?? false]
                if let data=try? JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),let text=String(data:data,encoding:.utf8){print("AMMO_LOCAL_MIC "+text);fflush(stdout)}
                self.stop()
            }
        }
        #endif
    }
    func start() async {
        guard !listening else{return}
        let permission=await withCheckedContinuation {continuation in AVAudioApplication.requestRecordPermission{continuation.resume(returning:$0)}}
        guard permission else{message="請到設定允許 Ammo Estimate 使用麥克風。";return}
        do {
            let audio=AVAudioSession.sharedInstance();try audio.setCategory(.record,mode:.measurement,options:[])
            #if os(iOS)
            try audio.setPreferredIOBufferDuration(0.005)
            #endif
            try audio.setActive(true)
            let dsp=processor
            let input=audioEngine.inputNode,format=input.outputFormat(forBus:0)
            guard format.sampleRate>0,format.channelCount>0 else{throw AmmoError.invalidValue}
            processor.configure(rate:format.sampleRate)
            guard format.commonFormat == .pcmFormatFloat32 else{throw AmmoError.invalidValue}
            let stride=format.isInterleaved ? Int(format.channelCount):1
            let rate=format.sampleRate
            let sink=AVAudioSinkNode {timestamp,count,buffers in
                let first=buffers.pointee.mBuffers
                // Carry the input buffer's clock through the queue. DSP scheduling
                // delays must not look like discontinuities in the recorded audio.
                let stamp=timestamp.pointee
                let start=stamp.mFlags.contains(.hostTimeValid) ? AVAudioTime.seconds(forHostTime:stamp.mHostTime):ProcessInfo.processInfo.systemUptime
                if let data=first.mData {dsp.ingest(data.assumingMemoryBound(to:Float.self),count:Int(count),stride:stride,endingAt:start+Double(count)/rate)}
                return noErr
            }
            sinkNode=sink;audioEngine.attach(sink);audioEngine.connect(input,to:sink,format:format)
            audioEngine.prepare();try audioEngine.start();listening=true
            if motion.isDeviceMotionAvailable {
                motion.deviceMotionUpdateInterval=0.01
                motion.startDeviceMotionUpdates(to:motionQueue){ data,_ in
                    guard let data else{return};let a=data.userAcceleration;dsp.motion(sqrt(a.x*a.x+a.y*a.y+a.z*a.z),time:data.timestamp)
                }
            }
            detail="本機即時分析中；不需 XIAO 或 BLE。";applyProcessor()
            #if os(watchOS)
            requestClock()
            clockTask?.cancel();clockTask=Task{@MainActor [weak self] in
                while !Task.isCancelled {
                    do {try await Task.sleep(nanoseconds:20_000_000_000)}catch{return}
                    guard let self,self.listening else{return};self.requestClock();self.flushSounds()
                }
            }
            #endif
        } catch {stop();message="無法啟動感測：\(error.localizedDescription)"}
    }
    func stop(){
        clockTask?.cancel();clockTask=nil
        task?.cancel();task=nil;training=false;validating=false;trainingPhase=0;armed=false;listening=false
        processor.queue.async{self.processor.armed=false}
        audioEngine.stop();if let sink=sinkNode {audioEngine.disconnectNodeInput(sink);audioEngine.detach(sink);sinkNode=nil}
        motion.stopDeviceMotionUpdates();try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation);phase="已停止"
    }
    func setActive(_ active:Bool){if !active {stop()}}
    func toggleCounting() async {
        guard !training,!validating else{return}
        if armed {stop();return}
        if !listening {await start()}
        guard listening else{return};toggleArmed()
    }
    func toggleArmed(){
        guard !validating,!training else{return}
        guard listening else{message="請先開始監聽。";return}
        guard triggerMode==2 || report != nil else{message="請先收錄聲音特徵。";return}
        #if os(watchOS)
        if !armed && clock?.valid(at:Date().timeIntervalSince1970) != true {requestClock();message="請先開啟手機新版 App，等待雙端時間對齊後再啟用計數。";return}
        #endif
        armed.toggle();if armed {ledger.claimSensor(origin:origin);persist();sync()};phase=armed ? "辨識計數中":"監看中";applyProcessor()
    }
    private func applyProcessor(){
        let profile=report.flatMap{try? AudioProfile(id:$0.profile.id,isTest:$0.profile.isTest,onset:$0.profile.onset,rearm:$0.profile.rearm,template:$0.profile.template,minimumSimilarity:similarity,refractoryMs:$0.profile.refractoryMs)}
        let enabled=(armed || validating) && !training,mode=triggerMode,threshold=motionThreshold
        var refined=refinedReport?.model;refined?.minimumScore=similarity
        let selected=refined
        processor.queue.async{
            self.processor.profile=profile;self.processor.refined=selected;self.processor.armed=enabled;self.processor.triggerMode=mode;self.processor.motionThreshold=threshold
        }
    }
    private func accept(_ frame:AudioSpectrum,peak:Double,block:Double,motionCount:Int){
        guard listening else{return}
        if block>maximumAnalysisMS {maximumAnalysisMS=block}
        // 8 seconds at roughly 94 windows/second exceeds the old 600-frame cap.
        if validating && validationFrames.count<1024 {validationFrames.append(frame)}
        if trainingPhase==1 {quietFrames.append(frame)}else if trainingPhase==2 {targetFrames.append(frame);collectedMotion.append(peak)}
        if Date().timeIntervalSince(lastPaint)>0.06 {lastPaint=Date();spectrum=frame;motionG=peak;motionSamples=motionCount;spectrumWave=Array((spectrumWave+[frame.rms]).suffix(80));motionWave=Array((motionWave+[peak]).suffix(80))}
    }
    func train(includeSpeech:Bool=false){
        guard !training,!validating else{return}
        task=Task{@MainActor in
            if !listening {await start()};guard listening else{return}
            training=true;armed=false;pausePeer();ledger.claimSensor(origin:origin);persist();sync();applyProcessor();quietFrames=[];targetFrames=[];collectedMotion=[]
            phase="安靜 3 秒，量測底噪";detail="保持手機或手錶在預定使用位置。";trainingPhase=1
            do {try await Task.sleep(nanoseconds:3_000_000_000);guard !Task.isCancelled else{return}
                trainingPhase=2;phase="收錄中：敲擊 3–5 次";detail="每次約隔一秒；收錄聲音頻譜與動作特徵。"
                try await Task.sleep(nanoseconds:6_000_000_000);guard !Task.isCancelled else{return};trainingPhase=0;phase="分析頻譜中"
                let improved=try RefinedAcousticTrainer.analyze(background:quietFrames,positive:targetFrames)
                refinedReport=improved;let result=improved.legacyReport
                report=result;similarity=improved.model.minimumScore
                try saveRefinedReport()
                let peaks=collectedMotion.filter{$0>0.001}.sorted();if !peaks.isEmpty {motionThreshold=max(0.003,min(0.2,peaks[Int(Double(peaks.count-1)*0.9)]*0.5))}
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try JSONEncoder().encode(result).write(to:modelURL,options:.atomic)
                var voiceAdded=false
                if includeSpeech {
                    targetFrames=[];trainingPhase=2;phase="正常講話 3 秒，不要敲擊";detail="正在收錄要排除的人聲；本次不增加累計。"
                    try await Task.sleep(nanoseconds:3_000_000_000);guard !Task.isCancelled else{return};trainingPhase=0
                    if let model=try? improved.model.addingBackground(targetFrames) {
                        refinedReport=RefinedAcousticReport(model:model,events:improved.events,excludedEvents:improved.excludedEvents,crossEventSimilarity:improved.crossEventSimilarity,backgroundRMS:improved.backgroundRMS)
                        try saveRefinedReport();voiceAdded=true
                    }
                }
                phase="主特徵已保存";detail=includeSpeech && !voiceAdded ? "主特徵已保存；講話樣本未加入，可在更多補收。按開始即可計數。":"按開始即可依主特徵計數；更多內可試講話與試敲。";training=false;applyProcessor()
            }catch{if Task.isCancelled {return};training=false;trainingPhase=0;phase="請重新收錄";detail=trainingErrorText(error);applyProcessor()}
        }
    }
    private func saveRefinedReport() throws {
        guard let report=refinedReport else{return}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let data=try JSONEncoder().encode(report)
        try data.write(to:refinedURL.appendingPathExtension("backup"),options:.atomic);try data.write(to:refinedURL,options:.atomic)
    }
    private func trainingErrorText(_ error:Error)->String {
        if let failure=error as? RefinedTrainingFailure {
            switch failure {
            case .insufficientEvents:return "有效敲擊不足三次。請在裝置附近分開敲 3–5 次，每次隔約一秒。"
            case .inconsistentEvents:return "這幾次敲擊差異太大；請保持裝置位置不變，使用相同方式再收一組。"
            case .noDenseFeatures:return "尚未取得完整精細頻譜，請重新開始監聽後收錄。"
            case .indistinguishableBackground:return "這份聲音與目標幾乎無法區分；請改用聲音＋震動，或收錄其他誤觸聲。"
            }
        }
        return "收錄未完成或資料無效，請重新收錄；累計已保留。"
    }
    func collectBackgroundExamples(speech:Bool=false){
        guard !training,!validating,refinedReport != nil else{message="請先收錄新版精細特徵。";return}
        task=Task{@MainActor in
            if !listening {await start()};guard listening else{return}
            training=true;armed=false;pausePeer();ledger.claimSensor(origin:origin);persist();sync();applyProcessor();targetFrames=[];trainingPhase=2
            phase=speech ? "收錄講話聲 3 秒":"補收背景 3 秒";detail=speech ? "現在正常講話，不要敲擊；這段不計入累計。":"現在製造你不想計數的雜音，先不要做目標敲擊。"
            do {
                try await Task.sleep(nanoseconds:3_000_000_000);trainingPhase=0
                guard let current=refinedReport else{return}
                let model=try current.model.addingBackground(targetFrames)
                refinedReport=RefinedAcousticReport(model:model,events:current.events,excludedEvents:current.excludedEvents,crossEventSimilarity:current.crossEventSimilarity,backgroundRMS:current.backgroundRMS)
                try saveRefinedReport();training=false;phase=speech ? "講話範本已加入":"背景範本已加入";detail="先試講話確認沒有誤觸，再試敲 5 次；兩種驗證都不增加累計。";applyProcessor()
            }catch{if Task.isCancelled{return};training=false;trainingPhase=0;phase="背景未加入";detail=trainingErrorText(error);applyProcessor()}
        }
    }
    func validateFiveTaps(){validateSession(expected:5)}
    func validateSpeech(){validateSession(expected:0)}
    private func validateSession(expected:Int){
        guard !training,!validating,let modelID=refinedReport?.model.base.id else {message="請先收錄新版精細特徵。";return}
        task=Task{@MainActor in
            if !listening {await start()};guard listening else{return}
            armed=false;pausePeer();validating=true;validationHits=0;validationExpected=expected;validationFrames=[];validationURL=nil
            ledger.claimSensor(origin:origin);persist();sync();applyProcessor()
            phase=expected==0 ? "驗證中，請正常講話":"驗證中，請敲 5 次";detail=expected==0 ? "5 秒內正常講話，不要敲擊；觀察誤觸次數，這段不計入累計。":"等一秒後，每秒敲一次；8 秒後結束。這段不計入累計。"
            let before=ledger.lifetime
            do {
                try await Task.sleep(nanoseconds:expected==0 ? 5_000_000_000:8_000_000_000);guard !Task.isCancelled else{return}
                validating=false;applyProcessor();phase=expected==0 ? "講話誤觸 \(validationHits) 次":"驗證收到 \(validationHits)／5 次"
                detail=expected==0 ? (validationHits==0 ? "本次講話未觸發；再試敲 5 次確認敲擊仍可辨識。":"仍有誤觸，請補收講話聲後重試；本次沒有增加累計。") : "請確認實際敲了 5 次；若漏算，請在相同位置重新收錄敲擊再試。驗證不增加累計。"
                let result=LocalAcousticValidation(modelID:modelID,expected:expected,detected:validationHits,lifetimeBefore:before,lifetimeAfter:ledger.lifetime,frames:validationFrames)
                let url=folder.appendingPathComponent("local-validation-"+String(Int(Date().timeIntervalSince1970))+".json")
                try JSONEncoder().encode(result).write(to:url,options:.atomic);validationURL=url
            }catch{if Task.isCancelled{return};validating=false;applyProcessor();message="驗證紀錄保存失敗；累計仍保留。"}
        }
    }
    private func shot(at time:Double){
        if validating && listening && !training {validationHits+=1;return}
        guard armed && !training && listening else{return}
        guard var state=ledger.soundFusion,state.owner==origin,state.valid else{message="事件同步紀錄無效，已暫停計數。";armed=false;applyProcessor();return}
        let previous=ledger
        #if os(iOS)
        guard let event=state.enqueue(station:.phone,time:time) else{return}
        let result=state.accept(event,now:Date().timeIntervalSince1970)
        if result == .counted {ledger.event(origin:origin)}
        state.acknowledge(through:event.sequence)
        #else
        guard let clock,clock.valid(at:Date().timeIntervalSince1970) else{armed=false;applyProcessor();requestClock();message="雙端時間需重新對齊，已暫停手錶計數。";return}
        guard state.enqueue(station:.watch,time:time+clock.offset,uncertainty:clock.uncertainty) != nil else{armed=false;applyProcessor();message="待同步事件已滿，請開啟手機同步後繼續。";return}
        #endif
        ledger.soundFusion=state
        guard persist() else{ledger=previous;armed=false;applyProcessor();return}
        #if os(iOS)
        sync();phase="已觸發 · 累計 \(total)"
        #else
        dualStatus="待手機確認 \(state.pending.count) 次";flushSounds()
        #endif
    }
    func demoShot(){ledger.event(origin:origin);persist();sync()}
    func reload(_ capacity:Int?=nil){ledger.reload(capacity:capacity,origin:origin);persist();sync()}
    func correct(_ delta:Int){ledger.correct(delta,origin:origin);persist();sync()}
    func setCapacity(_ value:Int){ledger.setCapacity(value,origin:origin);persist();sync()}
    #if os(iOS)
    func resetTotal(){ledger.resetFromPhone(origin:origin);persist();sync()}
    #endif
    @discardableResult private func persist()->Bool {
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let data=try JSONEncoder().encode(ledger)
            try data.write(to:ledgerURL.appendingPathExtension("backup"),options:.atomic)
            try data.write(to:ledgerURL,options:.atomic);return true
        }catch{message="計數保存失敗，請暫停使用並檢查儲存空間。";return false}
    }
    private func wirePayload()->[String:Any] {
        // Local receipt history/outbox stays on its owning device, below WC payload limits.
        var wire=ledger;wire.soundFusion=nil
        guard let data=try? JSONEncoder().encode(wire) else{return [:]}
        return ["localLedger":data,"soundVersion":1]
    }
    private func sync(){
        #if os(watchOS)
        guard !awaitingPhoneSnapshot else{return}
        #endif
        guard let session,session.activationState == .activated else{return}
        let payload=wirePayload();try? session.updateApplicationContext(payload)
        if session.isReachable {session.sendMessage(payload,replyHandler:nil,errorHandler:nil)}
    }
    private func receive(_ payload:[String:Any]){
        if payload["soundVersion"] as? Int == 1 {dualPeer=true}
        if payload["pauseSensor"] as? Bool == true {armed=false;applyProcessor();detail="另一端正在收錄或驗證，本機計數已暫停。"}
        guard let data=payload["localLedger"] as? Data,let incoming=try? JSONDecoder().decode(LocalAmmoLedger.self,from:data),incoming.valid else{return}
        let old=ledger
        #if os(watchOS)
        if awaitingPhoneSnapshot {
            ledger.adoptPhoneSnapshot(incoming)
            guard persist() else{ledger=old;return}
            awaitingPhoneSnapshot=false;UserDefaults.standard.set(true,forKey:"watch-phone-snapshot-v1")
        }else{ledger.merge(incoming)}
        #else
        ledger.merge(incoming)
        #endif
        if !dualPeer && ledger.sensorOwner != nil && ledger.sensorOwner != origin && armed {armed=false;applyProcessor();detail="另一台舊版裝置已接管感測；雙端功能需兩台都更新。"}
        if ledger != old {persist();sync()}
        #if os(iOS)
        dualStatus=dualPeer && paired ? "雙端已連線 · 任一符合，同聲只計一發":"手機單端偵測 · 等待手錶新版連線"
        #endif
    }
    private func pausePeer(){
        guard let session,session.activationState == .activated,session.isReachable else{return}
        session.sendMessage(["pauseSensor":true,"soundVersion":1],replyHandler:nil,errorHandler:nil)
    }
    private func requestClock(attempts:Int=3){
        #if os(watchOS)
        guard let session,session.activationState == .activated,session.isReachable,!clockBusy else{dualStatus="等待手機連線，手錶事件由手機統一入帳";return}
        clockBusy=true
        let sent=Date().timeIntervalSince1970
        session.sendMessage(["soundClock":sent,"soundVersion":1],replyHandler:{[weak self] reply in
            let returned=Date().timeIntervalSince1970
            Task{@MainActor in
                guard let self else{return};self.clockBusy=false
                guard let received=reply["clockReceived"] as? Double,let replied=reply["clockReplied"] as? Double,
                      let estimate=SoundClockEstimate(sent:sent,receivedByPhone:received,repliedByPhone:replied,returned:returned) else{
                    self.dualStatus="時間對齊中，請保持手機 App 開啟"
                    if attempts>1 {try? await Task.sleep(nanoseconds:300_000_000);self.requestClock(attempts:attempts-1)}
                    return
                }
                if self.clock?.valid(at:returned) != true || returned-(self.clock?.measuredAt ?? 0)>20 || estimate.uncertainty<(self.clock?.uncertainty ?? 1) {self.clock=estimate}
                self.dualPeer=true;self.dualStatus="雙端時間已對齊 · 同聲只計一發";self.receive(reply);self.flushSounds()
            }
        },errorHandler:{[weak self] _ in Task{@MainActor in self?.clockBusy=false;self?.dualStatus="手機暫未回應，待同步事件保留"}})
        #endif
    }
    private func flushSounds(){
        #if os(watchOS)
        guard !sendingSounds,let session,session.activationState == .activated,session.isReachable,
              let pending=ledger.soundFusion?.pending,!pending.isEmpty,
              let data=try? JSONEncoder().encode(Array(pending.prefix(32))) else{return}
        sendingSounds=true
        session.sendMessage(["soundEvents":data,"soundVersion":1],replyHandler:{[weak self] reply in Task{@MainActor in
            guard let self else{return};self.sendingSounds=false
            if reply["ackSource"] as? String == self.origin,let sequence=reply["soundAck"] as? UInt64 {
                let old=self.ledger;self.ledger.soundFusion?.acknowledge(through:sequence)
                if !self.persist(){self.ledger=old;return}
            }
            self.receive(reply)
            let count=self.ledger.soundFusion?.pending.count ?? 0
            self.dualStatus=count==0 ? "雙端已同步 · 同聲只計一發":"待手機確認 \(count) 次"
            if reply["expiredEvents"] as? Bool == true {self.message="部分事件已超過配對期限，未自動入帳；請在手機手動校正。"}
            // More than one batch drains after an advancing acknowledgment only.
            if let sequence=reply["soundAck"] as? UInt64,sequence>=(pending.first?.sequence ?? .max),count>0 {self.flushSounds()}
        }},errorHandler:{[weak self] _ in Task{@MainActor in self?.sendingSounds=false;self?.dualStatus="待同步事件保留，重新連線後重試"}})
        #endif
    }
    private func reply(to payload:[String:Any],receivedAt:Double)->[String:Any] {
        #if os(iOS)
        guard payload["soundVersion"] as? Int == 1 else{return wirePayload()}
        dualPeer=true
        if payload["soundClock"] as? Double != nil {
            var reply=wirePayload();reply["clockReceived"]=receivedAt;reply["clockReplied"]=Date().timeIntervalSince1970;return reply
        }
        if let data=payload["soundEvents"] as? Data,data.count<=32768,
           let events=try? JSONDecoder().decode([SoundObservation].self,from:data),!events.isEmpty,events.count<=32,
           events.allSatisfy({$0.valid && $0.station == .watch && $0.source==events[0].source}),
           var state=ledger.soundFusion,state.valid,state.owner==origin {
            let old=ledger;var expired=false
            for event in events.sorted(by:{$0.sequence<$1.sequence}) {
                let result=state.accept(event,now:Date().timeIntervalSince1970,counting:!training && !validating)
                if result == .counted {ledger.event(origin:origin)}
                if result == .expired {expired=true}
            }
            ledger.soundFusion=state
            guard persist() else{ledger=old;return ["soundVersion":1]}
            sync();var reply=wirePayload();reply["ackSource"]=events[0].source
            reply["soundAck"]=NSNumber(value:state.processed[events[0].source] ?? 0);reply["expiredEvents"]=expired;reply["pauseSensor"]=training || validating
            dualStatus="雙端已同步 · 任一符合，同聲只計一發";return reply
        }
        #endif
        return wirePayload()
    }
    nonisolated func session(_ session:WCSession,activationDidCompleteWith activationState:WCSessionActivationState,error:Error?){Task{@MainActor in self.paired=session.isReachable;self.sync();self.requestClock();self.flushSounds()}}
    nonisolated func sessionReachabilityDidChange(_ session:WCSession){Task{@MainActor in self.paired=session.isReachable;self.sync();self.requestClock();self.flushSounds()}}
    nonisolated func session(_ session:WCSession,didReceiveMessage message:[String:Any]){Task{@MainActor in self.receive(message)}}
    nonisolated func session(_ session:WCSession,didReceiveMessage message:[String:Any],replyHandler:@escaping ([String:Any])->Void){
        let received=Date().timeIntervalSince1970
        Task{@MainActor in replyHandler(self.reply(to:message,receivedAt:received))}
    }
    nonisolated func session(_ session:WCSession,didReceiveApplicationContext applicationContext:[String:Any]){Task{@MainActor in self.receive(applicationContext)}}
    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session:WCSession){}
    nonisolated func sessionDidDeactivate(_ session:WCSession){session.activate()}
    #endif
}
#endif
