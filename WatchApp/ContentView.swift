import SwiftUI
import AmmoCore

struct ContentView: View {
    @EnvironmentObject var store: WatchStore
    @State private var reloadPrompt = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 4) {
                    HStack(spacing: 5) {
                        Circle().fill(store.connected && !store.stale ? Color.mint : .orange).frame(width: 6, height: 6)
                        Text(store.demoMode ? "DEMO" : "XIAO").font(.caption2.weight(.bold))
                        Spacer()
                        Image(systemName: "battery.75percent")
                        Text(store.batteryText).font(.caption2)
                    }.foregroundStyle(.secondary)
                    Text("估計剩餘").font(.caption2).foregroundStyle(.secondary)
                    VStack(spacing: -3) {
                        Text(store.state == nil ? "—" : "\(store.counter.remaining)")
                            .font(.system(size: 56, weight: .semibold, design: .rounded)).minimumScaleFactor(0.45).lineLimit(1)
                            .foregroundStyle(store.counter.isLow ? Color.orange : Color.white)
                            .accessibilityIdentifier("remainingCount")
                        Text("/ \(store.counter.capacity)").font(.title3).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine).accessibilityLabel("估計剩餘 \(store.counter.remaining)，容量 \(store.counter.capacity)")
                    ProgressView(value: store.state == nil ? 0 : store.counter.fraction).tint(store.counter.isLow ? .orange : .mint)
                    HStack {
                        Text(store.state == nil ? "—" : "\(Int(store.counter.fraction * 100))%")
                        Spacer()
                        Text("累計擊發 \(store.counter.totalEvents)")
                    }.font(.caption2).foregroundStyle(.secondary)
                    if store.counter.isLow { Label("低彈量估計", systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.caption) }
                    Text(store.stale ? "離線／待同步 · 最後估計" : store.status).font(.caption2).foregroundStyle(store.stale ? Color.orange : .secondary)
                    if !store.demoMode { Text(store.safetyText).font(.caption2).foregroundStyle(store.safetyAttention ? Color.orange : .secondary) }
                    if store.pending { ProgressView("等待裝置確認").font(.caption2) }
                    Button("重新裝填", systemImage: "arrow.clockwise") { reloadPrompt = true }
                        .tint(.mint).disabled(!store.canCommand).accessibilityIdentifier("reload")
                    NavigationLink("手動校正") { CorrectionView() }
                    NavigationLink("設定與裝置") { SettingsView() }
                    if store.demoMode {
                        Button("模擬感測器事件") { store.event() }
                            .accessibilityIdentifier("demoEvent")
                    }
                    Text("BB 數量為推估值").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 4)
            }.background(.black)
                .confirmationDialog("重新裝填為 \(store.counter.capacity) 發？", isPresented: $reloadPrompt, titleVisibility: .visible) {
                    Button("確認重新裝填") { store.command(.reload, value: store.counter.capacity) }
                }
                .alert("裝置訊息", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                    Button("好") { store.message = nil }
                } message: { Text(store.message ?? "") }
        }.tint(.mint).preferredColorScheme(.dark)
    }
}
struct CorrectionView: View {
    @EnvironmentObject var store: WatchStore
    @State private var delta = 0.0
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text("調整估計剩餘數").font(.headline)
                Text(String(format: "%+.0f", delta)).font(.system(size: 40, weight: .semibold, design: .rounded))
                    .focusable().digitalCrownRotation($delta, from: -9999, through: 9999, by: 1, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
                    .accessibilityLabel("校正數值，使用錶冠調整")
                Stepper("微調", value: $delta, in: -9999...9999, step: 1)
                Text("預計 \(min(store.counter.capacity, max(0, store.counter.remaining + Int(delta)))) 發").font(.caption)
                Button("套用校正") { store.command(.correction, value: Int(delta)); delta = 0 }
                    .disabled(!store.canCommand || delta == 0)
                Text("事件總數不受校正影響").font(.caption2).foregroundStyle(.secondary)
            }
        }.navigationTitle("校正")
    }
}
struct SettingsView: View {
    @EnvironmentObject var store: WatchStore
    @State private var capacity = 300.0
    var body: some View {
        Form {
            Section("彈匣容量") {
                ForEach(AmmoCounter.presets, id: \.self) { value in
                    Button("\(value) 發" + (store.counter.capacity == value ? " ✓" : "")) { store.command(.setCapacity, value: value) }
                        .disabled(!store.canCommand)
                }
                NavigationLink("自訂容量") {
                    VStack(spacing: 12) {
                        Text("\(Int(capacity)) 發").font(.title2)
                            .focusable().digitalCrownRotation($capacity, from: 1, through: 9999, by: 1, sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true)
                        Stepper("調整容量", value: $capacity, in: 1...9999, step: 1)
                        Button("套用容量") { store.command(.setCapacity, value: Int(capacity)) }.disabled(!store.canCommand)
                        Text("變更容量會限制剩餘數上限；重新裝填才會補滿。").font(.caption2)
                    }.onAppear { capacity = Double(store.counter.capacity) }
                }
            }
            Section("連線") {
                Toggle("Demo 模式", isOn: Binding(get: { store.demoMode }, set: { store.setDemo($0) }))
                NavigationLink("裝置管理") { DevicesView() }
                Button("立即同步") { store.refresh() }
            }
            if store.demoMode {
                Section("Demo 測試") {
                    Toggle("每秒模擬事件", isOn: $store.autoDemo)
                    Button(store.demoDisconnected ? "重新連線" : "模擬斷線") { store.toggleDemoConnection() }
                    Button("模擬重新啟動") { store.rebootDemo() }
                    Button("模擬遺失 ACK") { store.loseAckDemo() }.disabled(!store.canCommand)
                    Button("注入異常封包") { store.malformedDemo() }
                }
            }
            Section("關於") { Text("獨立震動感測器。震動事件不一定代表 BB 發射，請保留手動校正。").font(.caption2) }
        }.navigationTitle("設定")
    }
}
struct DevicesView: View {
    @EnvironmentObject var store: WatchStore
    var body: some View {
        List {
            Text(store.status).font(.caption)
            Text(store.safetyText).font(.caption).foregroundStyle(store.safetyAttention ? Color.orange : .secondary)
            Text(store.safetyDetails).font(.caption2)
            if let state = store.state {
                Text("ID \(String(state.identity.id, radix: 16).uppercased())").font(.caption2)
                Text("Boot \(state.snapshot.boot) · Seq \(state.snapshot.sequence)").font(.caption2)
                Text("最後同步 \(state.syncedAt.formatted(date: .omitted, time: .standard))").font(.caption2)
                Text("裝置旗標 0x\(String(state.snapshot.flags, radix: 16))").font(.caption2)
            }
            if !store.demoMode {
                Button("重新掃描") { store.rescan() }
                ForEach(store.devices) { device in
                    Button { store.select(device.id) } label: {
                        VStack(alignment: .leading) { Text(device.name); Text("\(device.rssi) dBm").font(.caption2) }
                    }
                }
                if store.devices.isEmpty { Text("等待裝置廣播…").font(.caption) }
            }
        }.navigationTitle("裝置")
    }
}

struct LocalWatchRootView:View {
    @EnvironmentObject var store:LocalAmmoStore
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    var body:some View {
        NavigationStack {
            if isLuminanceReduced {
                VStack(spacing:8) {
                    Text("估計剩餘 BB").font(.caption).foregroundStyle(.secondary)
                    Text("\(store.remaining)").font(.system(size:64,weight:.semibold,design:.rounded)).monospacedDigit()
                    Text("/ \(store.ledger.capacity)").foregroundStyle(.secondary)
                    Text("累計 \(store.total)").font(.headline).monospacedDigit()
                    Text(store.armed ? "本機計數中":(store.listening ? "收音中":"等待手機自動開始")).font(.caption2).foregroundStyle(.secondary)
                    if store.isLowAmmo {Text(store.remaining==0 ? "估計已空":"低彈量").font(.caption2).foregroundStyle(.orange)}
                    if let message=store.message {Text(message).font(.caption2).foregroundStyle(.orange)}
                }.foregroundStyle(.white).padding(.horizontal,8)
            } else {
            ScrollView {
                VStack(spacing:12) {
                    Text("\(store.remaining)").font(.system(size:64,weight:.semibold,design:.rounded)).monospacedDigit().foregroundStyle(store.isLowAmmo ? .orange:.mint)
                        .frame(maxWidth:.infinity,minHeight:76).contentShape(Rectangle())
                        .onTapGesture(count:2){store.requestWatchReload()}
                        .accessibilityAction(named:Text("重新裝填，保留累計")){store.requestWatchReload()}
                    Text(store.reloadPending ? "等待手機裝填確認…":"雙點數字裝填 · 累計保留").font(.caption2).foregroundStyle(.secondary)
                    Text("/ \(store.ledger.capacity) · 推估").foregroundStyle(.secondary)
                    ProgressView(value:Double(store.remaining),total:Double(store.ledger.capacity)).tint(store.isLowAmmo ? .orange:.mint)
                    if store.isLowAmmo {Text(store.remaining==0 ? "估計已空，請裝填":"估計剩餘低於 15%").font(.caption).foregroundStyle(.orange)}
                    Text(store.lowAlertStatus).font(.caption2).foregroundStyle(.secondary)
                    Text("累計 \(store.total)").font(.headline).monospacedDigit()
                    Text(store.phase).font(.caption).foregroundStyle(store.armed ? .mint:.orange)
                    Text(store.detail).font(.caption2)
                    Text(store.decisionText).font(.caption2).foregroundStyle(.secondary)
                    Text(store.dualStatus).font(.caption2).foregroundStyle(.secondary)
                    if let message=store.message {Text(message).font(.caption2).foregroundStyle(.orange)}
                    Text("手機開啟、手錶就緒後自動開始；設定與停止請用手機。").font(.caption2).foregroundStyle(.secondary)
                    Text(store.backgroundRecordingEnabled ? "變暗仍收音 · 手機可鎖定":"請先喚醒手錶").font(.caption2).foregroundStyle(.secondary)
                    Text("更新 \(LocalAmmoStore.buildLabel)").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal,8)
            }.navigationTitle("Ammo 雙端")
            }
        }.preferredColorScheme(.dark).tint(.mint)
        .onAppear {store.setScreenDimmed(isLuminanceReduced)}
        .onChange(of:isLuminanceReduced){_,dimmed in store.setScreenDimmed(dimmed)}
    }
}
