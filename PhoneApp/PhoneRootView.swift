import SwiftUI
import AmmoCore

struct PhoneRootView: View {
    @EnvironmentObject var store: WatchStore
    var body: some View {
        TabView {
            NavigationStack { PhoneCounterView() }
                .tabItem { Label("計數", systemImage: "number.circle") }
            NavigationStack { PhoneTrainingView() }
                .tabItem { Label("採集訓練", systemImage: "waveform.path") }
            NavigationStack { PhoneDevicesView() }
                .tabItem { Label("裝置", systemImage: "sensor.tag.radiowaves.forward") }
            NavigationStack { PhoneSettingsView() }
                .tabItem { Label("設定", systemImage: "gearshape") }
        }
        .tint(.mint)
        .preferredColorScheme(.dark)
        .alert("裝置訊息", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("好") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
}

private struct PhoneCounterView: View {
    @EnvironmentObject var store: WatchStore
    @State private var reloadPrompt = false
    @State private var correctionSheet = false
    @State private var resetTotalPrompt = false
    private var countColor: Color { store.counter.isLow ? .orange : .mint }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                HStack {
                    Label(store.demoMode ? "DEMO 模擬裝置" : "XIAO 感測器", systemImage: "circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(store.connected && !store.stale ? .mint : .orange)
                    Spacer()
                    Label(store.batteryText, systemImage: "battery.75percent")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                VStack(spacing: 12) {
                    Text("估計剩餘 BB").font(.headline).foregroundStyle(.secondary)
                    Text(store.state == nil ? "—" : "\(store.counter.remaining)")
                        .font(.system(size: 112, weight: .semibold, design: .rounded))
                        .minimumScaleFactor(0.35).lineLimit(1).foregroundStyle(countColor)
                        .accessibilityIdentifier("remainingCount")
                    Text("/ \(store.counter.capacity) 發").font(.title2).foregroundStyle(.secondary)
                    ProgressView(value: store.state == nil ? 0 : store.counter.fraction).tint(countColor)
                    HStack {
                        Text(store.state == nil ? "—" : "剩餘 \(Int(store.counter.fraction * 100))%")
                        Spacer()
                        Text("累計擊發（估計） \(store.counter.totalEvents)")
                    }.font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(24).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 28))
                if store.counter.isLow {
                    Label("估計低彈量，請確認彈匣", systemImage: "exclamationmark.circle")
                        .font(.headline).foregroundStyle(.orange)
                }
                Text(store.stale ? "離線／待同步 · 顯示最後估計" : store.status)
                    .font(.subheadline).foregroundStyle(store.stale ? Color.orange : .secondary)
                if !store.demoMode {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(store.safetyText, systemImage: "thermometer.medium")
                            .foregroundStyle(store.safetyAttention ? Color.orange : .secondary)
                        Text(store.safetyDetails).font(.footnote).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if store.pending { ProgressView("等待裝置確認") }
                Button { reloadPrompt = true } label: {
                    Label("重新裝填", systemImage: "arrow.clockwise").frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(!store.canCommand)
                    .accessibilityIdentifier("reload")
                Button { correctionSheet = true } label: {
                    Label("手動校正", systemImage: "plusminus").frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.bordered).disabled(!store.canCommand)
                Button(role:.destructive) {resetTotalPrompt=true} label: {
                    Label("重置累計擊發",systemImage:"arrow.counterclockwise").frame(maxWidth:.infinity).padding(.vertical,8)
                }.buttonStyle(.bordered).disabled(!store.canResetTotal)
                Text("累計自動保存於 XIAO；更新 App、重新訓練與重新裝填都不清除。").font(.footnote).foregroundStyle(.secondary)
                if store.demoMode {
                    Button { store.event() } label: {
                        Label("模擬一個感測事件", systemImage: "waveform.path")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.bordered).disabled(!store.canCommand).accessibilityIdentifier("demoEvent")
                }
                Text("數量為推估值；震動事件不一定代表 BB 發射。")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 620).padding(24).frame(maxWidth: .infinity)
        }
        .background(Color.black).navigationTitle("Ammo Estimate").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("重新裝填為 \(store.counter.capacity) 發？", isPresented: $reloadPrompt, titleVisibility: .visible) {
            Button("確認重新裝填") { store.command(.reload, value: store.counter.capacity) }
        }
        .confirmationDialog("確定重置累計擊發？",isPresented:$resetTotalPrompt,titleVisibility:.visible) {
            Button("重置累計為 0",role:.destructive) {store.resetTotalFromPhone()}
        } message: {Text("只重置顯示累計，不變更剩餘彈數。此操作會同步到這個 XIAO 的所有新版 App。")}
        .sheet(isPresented: $correctionSheet) { NavigationStack { PhoneCorrectionView() } }
    }
}

private struct PhoneCorrectionView: View {
    @EnvironmentObject var store: WatchStore
    @Environment(\.dismiss) private var dismiss
    @State private var delta = 0
    var body: some View {
        Form {
            Section("調整估計剩餘數") {
                Text(String(format: "%+d", delta))
                    .font(.system(size: 52, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical)
                Stepper("逐發調整", value: $delta, in: -9999...9999)
                HStack {
                    ForEach([-10, -1, 1, 10], id: \.self) { value in
                        Button(String(format: "%+d", value)) { delta = min(9999, max(-9999, delta + value)) }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                    }
                }
                Text("校正後：\(min(store.counter.capacity, max(0, store.counter.remaining + delta))) 發")
            }
            Section {
                Button("套用校正") { store.command(.correction, value: delta); dismiss() }
                    .disabled(!store.canCommand || delta == 0)
            } footer: { Text("手動校正不改變累計擊發估計總數。") }
        }
        .navigationTitle("手動校正").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
    }
}

private struct PhoneSettingsView: View {
    @EnvironmentObject var store: WatchStore
    @State private var customCapacity = "300"
    private var validCapacity: Int? {
        guard let value = Int(customCapacity), (1...9999).contains(value) else { return nil }
        return value
    }
    var body: some View {
        Form {
            Section("彈匣容量") {
                ForEach(AmmoCounter.presets, id: \.self) { capacity in
                    Button { store.command(.setCapacity, value: capacity) } label: {
                        HStack { Text("\(capacity) 發"); Spacer(); if store.counter.capacity == capacity { Image(systemName: "checkmark") } }
                    }.disabled(!store.canCommand)
                }
                TextField("自訂容量 1–9999", text: $customCapacity).keyboardType(.numberPad)
                    .onChange(of: customCapacity) { _, value in customCapacity = String(value.filter(\.isNumber).prefix(4)) }
                Button("套用自訂容量") { if let value = validCapacity { store.command(.setCapacity, value: value) } }
                    .disabled(!store.canCommand || validCapacity == nil)
                Text("變更容量會限制剩餘上限；重新裝填才會補滿。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("連線") {
                Toggle("Demo 模式", isOn: Binding(get: { store.demoMode }, set: { store.setDemo($0) }))
                Button("立即同步") { store.refresh() }
            }
            if store.demoMode {
                Section("Demo 測試") {
                    Toggle("每秒模擬事件", isOn: $store.autoDemo)
                    Button(store.demoDisconnected ? "重新連線" : "模擬斷線") { store.toggleDemoConnection() }
                    Button("模擬裝置重新啟動") { store.rebootDemo() }
                    Button("模擬遺失 ACK") { store.loseAckDemo() }.disabled(!store.canCommand)
                    Button("注入異常封包") { store.malformedDemo() }
                }
            }
            Section("關於") {
                Text("Demo 資料各自保存。硬體模式下，手機與手錶可同時連接同一塊 XIAO，同步其估計計數；最多支援兩個連線。")
                Text("估計數量不能代表彈匣中的實際 BB 數量。")
            }.font(.footnote)
        }.navigationTitle("設定").onAppear { customCapacity = "\(store.counter.capacity)" }
    }
}

private struct PhoneDevicesView: View {
    @EnvironmentObject var store: WatchStore
    var body: some View {
        List {
            Section("同步狀態") {
                Label(store.status, systemImage: store.connected && !store.stale ? "checkmark.circle" : "antenna.radiowaves.left.and.right.slash")
                if let state = store.state {
                    LabeledContent("裝置 ID", value: String(state.identity.id, radix: 16).uppercased())
                    LabeledContent("重新啟動編號", value: "\(state.snapshot.boot)")
                    LabeledContent("狀態序號", value: "\(state.snapshot.sequence)")
                    LabeledContent("最後同步", value: state.syncedAt.formatted(date: .abbreviated, time: .standard))
                }
            }
            if store.demoMode {
                Section { Text("目前使用模擬裝置。請在設定關閉 Demo，才會要求藍牙權限並掃描 XIAO。") }
            } else {
                Section("附近的 XIAO") {
                    Button("重新掃描") { store.rescan() }
                    ForEach(store.devices) { device in
                        Button { store.select(device.id) } label: {
                            HStack { Text(device.name); Spacer(); Text("\(device.rssi) dBm").foregroundStyle(.secondary) }
                        }
                    }
                    if store.devices.isEmpty { Text("等待裝置廣播…").foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("裝置")
    }
}


private struct PhoneTrainingView: View {
    @EnvironmentObject var store: WatchStore
    @State private var testModel = true
    @State private var applyPrompt = false
    private var light: Color { store.guidedAnalyzing ? .red : (store.capture != nil ? .green:.gray) }
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text(store.demoMode ? "DEMO 模擬訓練" : "XIAO 震動訓練").font(.headline)
                Circle().fill(light).frame(width: 80,height: 80)
                    .overlay { Image(systemName: store.guidedAnalyzing ? "gearshape.2.fill":"waveform").font(.largeTitle).foregroundStyle(.black.opacity(0.75)) }
                    .accessibilityLabel(store.guidedAnalyzing ? "紅燈，分析中" : (store.capture != nil ? "綠燈，採集中":"待命"))
                Text(store.guidedAnalyzing ? "分析中" : (store.capture != nil ? "捕捉中":"準備訓練")).font(.title2.bold())
                Text(store.guidedPrompt).font(.title3).multilineTextAlignment(.center).frame(minHeight: 75)
                Text(store.audioSupported ? "聲音頻譜比對 · 16kHz / FFT":"等待 XIAO 聲音頻譜服務").font(.headline)
                if store.guidedActive { Text("第 \(store.guidedRound) 輪 · 綠燈採集／紅燈分析").foregroundStyle(.secondary) }
                if let capture = store.capture {
                    TimelineView(.periodic(from: .now, by: 0.25)) { context in
                        let elapsed = context.date.timeIntervalSince(capture.startedAt)
                        VStack {
                            ProgressView(value: min(store.captureDuration,max(0,elapsed)),total: store.captureDuration).tint(.green)
                            Text("約剩 \(max(0,Int(ceil(store.captureDuration-elapsed)))) 秒 · 收到 \(capture.features.count) 個視窗").font(.footnote)
                        }
                    }
                }
                if store.guidedActive {
                    Button("停止訓練",role: .destructive) { store.stopGuidedTraining() }.buttonStyle(.bordered).controlSize(.large)
                } else {
                    Button(store.hasTrainingReport ? "重新訓練":"開始訓練") { store.startGuidedTraining(isTest:testModel) }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.canTrain)
                    Toggle("桌面敲擊測試",isOn: $testModel).disabled(store.trainingBusy || store.trainingReport != nil)
                    Text(testModel ? "先用桌面練習，取得實體設備後再重新訓練。" : "快速模式也接受背景相似；請核對誤計與漏計。").font(.footnote).foregroundStyle(.secondary)
                }
                if let report=store.audioReport {
                    VStack(spacing:10) {
                        Text("聲音頻譜模型 · \(report.events) 次敲擊").font(.headline)
                        Text("頻譜比對門檻 \(report.profile.minimumSimilarity.formatted(.percent)) · 未驗證實際擊發準確率").font(.footnote)
                        Button("套用聲音頻譜並啟用") {applyPrompt=true}.buttonStyle(.borderedProminent).disabled(!store.canTrain)
                    }
                }
                if !store.audioSupported,store.audioReport == nil,let report = store.trainingReport {
                    VStack(spacing: 10) {
                        Text("已收集 \(report.positiveExamples) 次目標候選震動").font(.headline)
                        if report.profile.detectionMode == .sensitive {
                            Text("高靈敏 · 觸發門檻 \(String(format:"%.3fg",report.profile.onsetG)) · 請以實際敲擊核對").font(.footnote)
                        } else {
                        Text("保留樣本辨識率 \(report.sensitivity.formatted(.percent.precision(.fractionLength(0)))) · 背景排除率 \(report.specificity.formatted(.percent.precision(.fractionLength(0))))").font(.footnote)
                        }
                        ForEach(report.warnings,id: \.self) { Text($0).font(.footnote).foregroundStyle(.orange) }
                        Button("套用並啟用自動計數") { applyPrompt = true }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.canTrain)
                    }
                }
                Toggle("即時監看 · XIAO",isOn:Binding(get:{store.liveMonitorEnabled},set:{store.setLiveMonitor($0)}))
                VibrationLiveWaveform(features: (store.capture ?? store.positiveCapture ?? store.backgroundCapture)?.features ?? [], live: store.capture != nil, preview: store.vibrationWave)
                VStack(alignment:.leading,spacing:8) {
                    Label("即時聲音強度 · XIAO 麥克風",systemImage:"mic.fill").font(.headline)
                    SignalWaveform(values:store.audioWave,color:.purple)
                    Text(store.audioActive && Date().timeIntervalSince(store.liveUpdated)<3 ? "麥克風監看中 · 僅音量波紋，不錄音存檔":"麥克風待連線／已停止").font(.caption).foregroundStyle(.secondary)
                    Text("完成聲音頻譜訓練並啟用後，XIAO 依頻帶形狀辨識目標聲音。").font(.caption).foregroundStyle(.secondary)
                }.padding().background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:16))
                if let spectrum=store.audioSpectrum {
                    VStack(alignment:.leading,spacing:8) {
                        Text("即時頻譜 · 主峰 \(spectrum.dominantHz) Hz").font(.headline)
                        HStack(alignment:.bottom,spacing:4) {
                            ForEach(0..<8,id:\.self) { i in
                                VStack {
                                    Rectangle().fill(.cyan).frame(height:max(2,spectrum.bands[i]*160))
                                    Text(AudioSpectrum.bandLabels[i]).font(.system(size:8)).lineLimit(1).minimumScaleFactor(0.5)
                                }.frame(maxWidth:.infinity)
                            }
                        }.frame(height:115,alignment:.bottom)
                        if let profile=store.audioReport?.profile {Text("與已收錄頻譜相似度 \(profile.similarity(spectrum).formatted(.percent.precision(.fractionLength(0))))").font(.caption)}
                        Text("頻帶單位 Hz；125Hz 解析度。音量及頻譜形狀同時符合才計數。").font(.caption).foregroundStyle(.secondary)
                    }.padding().background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:16))
                }
                Text(store.captureSummary).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                Divider()
                Text(store.modelDescription).font(.headline)
                Text(store.trainingText).font(.footnote).foregroundStyle(.secondary)
                if store.modelEnabled { Button("暫停自動計數") { store.setDetectorEnabled(false) }.buttonStyle(.bordered).disabled(!store.canTrain) }
                if let url = store.trainingExport { ShareLink("匯出最近採集 CSV",item:url).font(.footnote) }
                if !store.trainingSupported { Text("請先到裝置頁連線至 XIAO；練習可開啟 Demo。日常採集不需插 USB。").font(.footnote).foregroundStyle(.orange) }
                Text("保持 App 在前景。綠燈時依文字提示動作；請敲桌面，勿敲裸露開發板。快速模式：靜置量底噪 4 秒、敲擊最多 8 秒；先完整收集再找峰值，收足 3 次且至少 4 秒便提前分析，最多 6 輪。數量為震動推估，仍可手動校正。").font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }.navigationTitle("採集訓練").navigationBarTitleDisplayMode(.inline)
        .onAppear {store.setLiveMonitor(true)}.onDisappear {store.setLiveMonitor(false)}
        .confirmationDialog("套用後，符合模型的震動會計入估計擊發數。移動／碰撞仍可能誤判，請先核對。",isPresented:$applyPrompt,titleVisibility:.visible) {
            Button("確認套用並啟用") { store.applyAndEnableTraining() }
        }
    }
}

private struct VibrationLiveWaveform: View {
    let features: [VibrationFeature]
    let live: Bool
    let preview: [Double]
    private var values: [Double] { live ? Array(features.suffix(128)).map(\.peakG):preview }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("即時震動 · XIAO",systemImage:"waveform.path").font(.headline)
                Spacer(); Text(live ? "接收中":"採集時更新").font(.caption).foregroundStyle(live ? .mint:.secondary)
            }
            SignalWaveform(values:values,color:.mint)
            Text("震動峰值 \(String(format:"%.3f",values.max() ?? 0)) g").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }.padding().background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:16))
    }
}
private struct SignalWaveform: View {
    let values: [Double]
    let color: Color
    var height:CGFloat=100
    var body: some View {
        Canvas { context,size in
            var grid = Path();grid.move(to:CGPoint(x:0,y:size.height/2));grid.addLine(to:CGPoint(x:size.width,y:size.height/2))
            context.stroke(grid,with:.color(.gray.opacity(0.35)),lineWidth:1)
            let samples = Array(values.suffix(128)), limit = max(0.005,samples.filter(\.isFinite).max() ?? 0)
            guard samples.count > 1 else { return }
            var path = Path()
            for (index,value) in samples.enumerated() {
                let x = CGFloat(index)/CGFloat(max(127,samples.count-1))*size.width
                let y = size.height*0.9 - CGFloat(min(1,max(0,value.isFinite ? value/limit:0)))*size.height*0.8
                if index==0 {path.move(to:CGPoint(x:x,y:y))}else{path.addLine(to:CGPoint(x:x,y:y))}
            }
            context.stroke(path,with:.color(color),style:StrokeStyle(lineWidth:2,lineJoin:.round))
        }.frame(height:height).accessibilityLabel("即時訊號強度曲線")
    }
}

private enum PhoneReleaseInfo {
    // Fixed for this build; this is not the time at which the app was opened.
    static let updatedAt = "2026/10/21 20:23（台灣時間）"
    static let name = "雙端主特徵版"
}

struct LocalPhoneRootView:View {
    @EnvironmentObject var store:LocalAmmoStore
    private var primaryTitle:String {
        if store.training || store.validating {return "停止"}
        if store.refinedReport == nil {return "收錄主特徵"}
        return store.armed ? "暫停":"開始"
    }
    var body:some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:20) {
                    Text("\(store.remaining)").font(.system(size:108,weight:.semibold,design:.rounded)).monospacedDigit()
                    Text("/ \(store.ledger.capacity) · \(store.remaining*100/store.ledger.capacity)% · 估計剩餘 BB").foregroundStyle(.secondary)
                    ProgressView(value:Double(store.remaining),total:Double(store.ledger.capacity)).tint(store.remaining*100<store.ledger.capacity*15 ? .orange:.mint)
                    Text("累計擊發（估計） \(store.total)").font(.title2.bold()).monospacedDigit()
                    Text(store.phase).font(.headline).foregroundStyle(store.armed ? .mint:.orange)
                    Text(store.detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button(primaryTitle) {
                            if store.training || store.validating {store.stop()}
                            else if store.refinedReport == nil {store.train()}
                            else {Task{await store.toggleCounting()}}
                        }.buttonStyle(.borderedProminent)
                        if store.refinedReport != nil {
                            Button("收錄主特徵"){store.train()}.buttonStyle(.bordered).disabled(store.training || store.validating)
                        }
                    }.controlSize(.large)
                    Button("重新裝填"){store.reload()}.buttonStyle(.bordered).controlSize(.large)
                    Label(store.dualStatus,systemImage:"waveform.path").font(.footnote).foregroundStyle(.secondary)
                    VStack(alignment:.leading,spacing:6) {
                        Text("聲音與震動").font(.caption).foregroundStyle(.secondary)
                        SignalWaveform(values:store.spectrumWave,color:.cyan,height:70)
                        SignalWaveform(values:store.motionWave,color:.mint,height:70)
                    }.padding().background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:18))
                    Text(store.paired ? "手錶已連線":"計數已保存本機").font(.footnote).foregroundStyle(.secondary)
                    Text("保持 App 在前景；不會自動學習背景。數量是推估值。").font(.caption).foregroundStyle(.secondary)
                    VStack(spacing:4) {
                        Text("版本 \(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "—") · \(PhoneReleaseInfo.name)")
                        Text("更新時間：\(PhoneReleaseInfo.updatedAt)")
                    }.font(.caption2).foregroundStyle(.secondary).padding(.top,8).accessibilityElement(children:.combine)
                }.padding(24).frame(maxWidth:620).frame(maxWidth:.infinity)
            }.background(.black).navigationTitle("Ammo")
                .toolbar {ToolbarItem(placement:.topBarTrailing){NavigationLink{LocalPhoneSettingsView()}label:{Label("更多",systemImage:"ellipsis.circle")}}}
        }.preferredColorScheme(.dark).tint(.mint)
        .alert("提示",isPresented:Binding(get:{store.message != nil},set:{if !$0 {store.message=nil}})){Button("好"){store.message=nil}}message:{Text(store.message ?? "")}
    }
}

struct LocalPhoneSettingsView:View {
    @EnvironmentObject var store:LocalAmmoStore
    @State private var resetPrompt=false
    @State private var capacityText="300"
    var body:some View {
        Form {
            Section("手動排除雜音") {
                Text("依收錄的主特徵偵測；只有你按下補收才會新增排除範本。").font(.footnote).foregroundStyle(.secondary)
                Button("補收講話聲（3 秒）"){store.collectBackgroundExamples(speech:true)}.disabled(store.training || store.validating)
                Button("補收其他背景（3 秒）"){store.collectBackgroundExamples()}.disabled(store.training || store.validating)
            }
            Section("驗證，不計入累計") {
                Button(store.validating && store.validationExpected==0 ? "講話誤觸 \(store.validationHits) 次":"試講話 5 秒"){store.validateSpeech()}.disabled(store.training || store.validating)
                Button(store.validating && store.validationExpected==5 ? "收到 \(store.validationHits)／5 次":"試敲 5 次"){store.validateFiveTaps()}.disabled(store.training || store.validating)
                Text(store.phase).font(.footnote)
                if let url=store.validationURL {ShareLink("匯出驗證特徵",item:url)}
            }
            Section("彈匣與手動校正") {
                Menu("容量 \(store.ledger.capacity)"){ForEach(AmmoCounter.presets,id:\.self){n in Button("\(n) 發"){store.setCapacity(n)}}}
                HStack {
                    TextField("自訂容量 1–9999",text:$capacityText).keyboardType(.numberPad)
                    Button("套用"){if let n=Int(capacityText),(1...9999).contains(n){store.setCapacity(n)}}
                }
                HStack {
                    Text("估計剩餘 \(store.remaining)");Spacer()
                    Button("−1"){store.correct(-1)};Button("＋1"){store.correct(1)}
                }.buttonStyle(.bordered)
                Button("手動記一發"){store.demoShot()}.disabled(store.training || store.validating)
                Button("重置累計擊發",role:.destructive){resetPrompt=true}
            }
            Section("進階辨識") {
                Picker("觸發條件",selection:$store.triggerMode){Text("聲音頻譜").tag(0);Text("聲音＋震動").tag(1);Text("震動").tag(2)}
                Text("頻譜相似度 \(Int(store.similarity*100))%")
                Slider(value:$store.similarity,in:0.65...0.98,step:0.01)
                Text("震動門檻 \(String(format:"%.3fg",store.motionThreshold))")
                Slider(value:$store.motionThreshold,in:0.003...0.2,step:0.001)
            }.disabled(store.training || store.validating)
            Section("訊號與裝置") {
                Button(store.listening ? "停止感測":"僅開啟監聽"){if store.listening{store.stop()}else{Task{await store.start()}}}
                Text(store.decisionText)
                Text("頻譜符合程度 \(Int(store.matchScore*100))% · 主峰 \(store.spectrum?.dominantHz ?? 0) Hz")
                Text(store.relativeLevelText).font(.footnote)
                Text("裝置相對音量，非校正環境分貝；手機與手錶各自收錄，改變距離後應重做驗證。").font(.footnote).foregroundStyle(.secondary)
                if let model=store.refinedReport {Text("\(model.events) 個敲擊範本 · \(model.model.negatives.count) 個手動背景")}
                if let s=store.spectrum {
                    HStack(alignment:.bottom,spacing:4){ForEach(0..<8,id:\.self){i in VStack{Rectangle().fill(.cyan).frame(height:max(2,s.bands[i]*100));Text(AudioSpectrum.bandLabels[i]).font(.system(size:8))}.frame(maxWidth:.infinity)}}.frame(height:100,alignment:.bottom)
                }
                Text(store.paired ? "手錶即時連線中":"手錶未即時連線；資料已保存本機")
                Text("兩台各自收錄特徵並開始；手錶事件由手機統一配對入帳。相似聲音仍可能誤判。").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("更多")
        .confirmationDialog("確定重置累計擊發？",isPresented:$resetPrompt,titleVisibility:.visible){Button("確認重置為 0",role:.destructive){store.resetTotal()}}
    }
}
