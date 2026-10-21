import Foundation
import CoreBluetooth
import AmmoCore

@MainActor final class BLEManager: NSObject, DeviceTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    var onEvent: ((TransportEvent) -> Void)?
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var candidates: [UUID: CBPeripheral] = [:]
    private var devices: [DiscoveredDevice] = []
    private var characteristics: [String: CBCharacteristic] = [:]
    private var profileWrites: [Data] = []
    private var wanted = false
    private var selected: UUID?
    private var reconnect: DispatchWorkItem?
    private var timeout: DispatchWorkItem?
    private var retry = 0
    private var identityReady = false
    private var subscribed = Set<String>()
    override init() { super.init(); central = CBCentralManager(delegate: self, queue: .main) }
    func start() {
        wanted = true
        selected = UserDefaults.standard.string(forKey: "selectedPeripheral").flatMap(UUID.init(uuidString:))
        scan()
    }
    func stop() {
        wanted = false; reconnect?.cancel(); timeout?.cancel(); central.stopScan()
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        clearConnection(); onEvent?(.disconnected)
    }
    func connect(_ id: UUID) {
        guard wanted, let next = candidates[id], central.state == .poweredOn else { return }
        reconnect?.cancel(); timeout?.cancel()
        if let old = peripheral, old.identifier != id { central.cancelPeripheralConnection(old) }
        clearConnection(); selected = id; peripheral = next
        UserDefaults.standard.set(id.uuidString, forKey: "selectedPeripheral")
        central.stopScan(); onEvent?(.status("連線中…")); central.connect(next)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wanted, self.subscribed.count < 2 else { return }
            self.onEvent?(.failure("連線或服務探索逾時"))
            if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
        }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }
    func readState() {
        guard identityReady, subscribed.count == 2, let p = peripheral, p.state == .connected,
              let c = characteristics[GATT.state] else { return }
        p.readValue(for: c)
        if let safety = characteristics[GATT.safety] { p.readValue(for: safety) }
        if let training = characteristics[GATT.trainingStatus] { p.readValue(for: training) }
        if let reset = characteristics[GATT.counterReset] { p.readValue(for:reset) }
    }
    func send(_ data: Data) {
        guard subscribed.count == 2, let p = peripheral, p.state == .connected,
              let c = characteristics[GATT.command], data.count == 16 else {
            onEvent?(.failure("尚未完成 BLE 同步")); return
        }
        p.writeValue(data, for: c, type: .withResponse)
    }
    func train(_ data: Data) {
        guard identityReady, let p = peripheral, p.state == .connected, let c = characteristics[GATT.trainingControl], data.count == 16 else { onEvent?(.trainingWriteFailure("採集服務尚未就緒")); return }
        p.writeValue(data, for: c, type: .withResponse)
    }
    func uploadProfile(_ chunks: [Data]) {
        guard profileWrites.isEmpty, chunks.count == 4, chunks.allSatisfy({ $0.count == 20 }), let p = peripheral, p.state == .connected, let c = characteristics[GATT.profileChunk] else { onEvent?(.trainingWriteFailure("模型傳送尚未就緒")); return }
        profileWrites = chunks; p.writeValue(profileWrites.removeFirst(), for: c, type: .withResponse)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { if wanted { scan() } }
        else {
            clearConnection(); onEvent?(.disconnected)
            let message: String
            switch central.state {
            case .unauthorized: message = "請允許藍牙權限"
            case .poweredOff: message = "藍牙已關閉"
            case .unsupported: message = "此環境不支援 BLE，請使用 Demo"
            default: message = "藍牙準備中"
            }
            onEvent?(.status(message))
        }
    }
    private func scan() {
        guard wanted, central.state == .poweredOn else { return }
        onEvent?(.status("掃描 XIAO…"))
        central.scanForPeripherals(withServices: [CBUUID(string: GATT.service)], options: nil)
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        candidates[p.identifier] = p
        devices.removeAll { $0.id == p.identifier }
        devices.append(DiscoveredDevice(id: p.identifier, name: p.name ?? "XIAO Ammo", rssi: RSSI.intValue))
        onEvent?(.discovered(devices.sorted { $0.rssi > $1.rssi }))
        if selected == p.identifier, peripheral == nil { connect(p.identifier) }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard wanted, p.identifier == peripheral?.identifier else { central.cancelPeripheralConnection(p); return }
        p.delegate = self; p.discoverServices([CBUUID(string: GATT.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        clearConnection(); onEvent?(.disconnected); scheduleReconnect()
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        clearConnection(); onEvent?(.disconnected); scheduleReconnect()
    }
    private func clearConnection() { timeout?.cancel(); peripheral = nil; characteristics.removeAll(); profileWrites.removeAll(); subscribed.removeAll(); identityReady = false }
    private func scheduleReconnect() {
        guard wanted else { return }
        retry = min(retry + 1, 5)
        let work = DispatchWorkItem { [weak self] in self?.scan() }
        reconnect = work
        DispatchQueue.main.asyncAfter(deadline: .now() + min(30, pow(2, Double(retry))), execute: work)
    }
    private func fail(_ text: String) {
        onEvent?(.failure(text))
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        guard error == nil, let service = p.services?.first(where: { $0.uuid == CBUUID(string: GATT.service) }) else { fail("找不到計數服務"); return }
        p.discoverCharacteristics([GATT.identity, GATT.state, GATT.command, GATT.ack, GATT.safety, GATT.trainingControl, GATT.trainingData, GATT.profileChunk, GATT.trainingStatus, GATT.liveSignal, GATT.counterReset, GATT.audioSpectrum].map { CBUUID(string: $0) }, for: service)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        guard error == nil else { fail("無法讀取服務"); return }
        for c in service.characteristics ?? [] { characteristics[c.uuid.uuidString] = c }
        if let safety = characteristics[GATT.safety], !safety.properties.contains(.read) { fail("安全監測服務不相容"); return }
        onEvent?(.safetySupport(characteristics[GATT.safety] != nil))
        onEvent?(.audioSupport(characteristics[GATT.audioSpectrum]?.properties.contains([.read,.notify]) == true))
        onEvent?(.resetSupport(characteristics[GATT.counterReset]?.properties.contains([.read,.notify]) == true))
        guard let identity = characteristics[GATT.identity], identity.properties.contains(.read),
              let state = characteristics[GATT.state], state.properties.contains([.read, .notify]),
              let ack = characteristics[GATT.ack], ack.properties.contains([.read, .notify]),
              let command = characteristics[GATT.command], command.properties.contains(.write) else { fail("GATT 規格不相容"); return }
        let trainingReady = [GATT.trainingControl, GATT.profileChunk].allSatisfy { characteristics[$0]?.properties.contains(.write) == true } && [GATT.trainingData, GATT.trainingStatus].allSatisfy { characteristics[$0]?.properties.contains([.read,.notify]) == true }
        onEvent?(.trainingSupport(trainingReady))
        onEvent?(.liveSupport(characteristics[GATT.liveSignal]?.properties.contains([.read,.notify]) == true))
        p.readValue(for: identity)
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        if [GATT.safety,GATT.trainingData,GATT.trainingStatus,GATT.liveSignal,GATT.counterReset,GATT.audioSpectrum].contains(c.uuid.uuidString) {
            if error == nil { p.readValue(for: c) } // Optional notifications; periodic reads remain available.
            return
        }
        guard error == nil, c.isNotifying else { fail("無法訂閱通知"); return }
        subscribed.insert(c.uuid.uuidString)
        if subscribed.count == 2 { retry = 0; timeout?.cancel(); onEvent?(.status("讀取裝置狀態…")); readState() }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        if c.uuid == CBUUID(string: GATT.safety) {
            if identityReady { onEvent?(.safety(error == nil ? (c.value ?? Data()) : Data())) }
            return
        }
        if c.uuid.uuidString == GATT.audioSpectrum {
            if identityReady,error == nil,let data=c.value {onEvent?(.audioSpectrum(data))};return
        }
        if c.uuid.uuidString == GATT.counterReset {
            if identityReady,error == nil,let data=c.value {onEvent?(.resetStatus(data))};return
        }
        if c.uuid.uuidString == GATT.liveSignal {
            if identityReady, error == nil, let data = c.value { onEvent?(.liveSignal(data)) }; return
        }
        if c.uuid.uuidString == GATT.trainingData || c.uuid.uuidString == GATT.trainingStatus {
            if identityReady, error == nil, let data = c.value { onEvent?(c.uuid.uuidString == GATT.trainingData ? .trainingData(data):.trainingStatus(data)) }
            return
        }
        guard error == nil, let data = c.value else { onEvent?(.failure("BLE 讀取失敗")); return }
        switch c.uuid.uuidString {
        case GATT.identity:
            do {
                let identity = try DeviceIdentity(data: data); identityReady = true; onEvent?(.identity(identity))
                for uuid in [GATT.state, GATT.ack] { if let characteristic = characteristics[uuid] { p.setNotifyValue(true, for: characteristic) } }
                for uuid in [GATT.trainingData,GATT.trainingStatus,GATT.liveSignal,GATT.counterReset,GATT.audioSpectrum] {
                    if let c = characteristics[uuid] { p.setNotifyValue(true, for: c) }
                }
                if let safety = characteristics[GATT.safety] {
                    p.readValue(for: safety)
                    if safety.properties.contains(.notify) { p.setNotifyValue(true, for: safety) }
                }
            } catch { fail("協定版本或裝置識別碼不相容") }
        case GATT.state: if identityReady { onEvent?(.state(data)) }
        case GATT.ack: if identityReady { onEvent?(.ack(data)) }
        default: break
        }
    }
    func peripheral(_ p: CBPeripheral, didWriteValueFor c: CBCharacteristic, error: Error?) {
        guard p.identifier == peripheral?.identifier else { return }
        if c.uuid.uuidString == GATT.profileChunk || c.uuid.uuidString == GATT.trainingControl {
            if error != nil { profileWrites = []; onEvent?(.trainingWriteFailure("採集／模型指令傳送失敗，請重新同步")) }
            else if c.uuid.uuidString == GATT.profileChunk, !profileWrites.isEmpty { p.writeValue(profileWrites.removeFirst(), for: c, type: .withResponse) }
            return
        }
        if error != nil { onEvent?(.failure("指令傳送失敗；正在重新同步")); readState() }
    }
}
