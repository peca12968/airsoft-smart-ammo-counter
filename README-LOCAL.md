# Airsoft Smart Ammo · 本機感測版

原生 iPhone／Apple Watch App。使用各自麥克風的聲音強度、Hz 頻譜與動作感測器分類震動／聲音事件，數量均為推估值。

目前先使用 Apple 裝置本機感測，不需 XIAO。請閱讀 [操作與限制](docs/LOCAL-SENSORS.md)。

操作：開始監聽 → 收錄聲音與震動特徵 → 安靜3秒 → 敲擊3–5次 → 啟用計數。三種模式：聲音頻譜／聲音＋震動／震動。App 需保持前景。

更新 App、重新訓練、校正或裝填不清除累計；重置只由手機確認按鈕執行。原始錄音不存檔。

Xcode 開啟 `AirsoftSmartAmmo.xcodeproj`，選 AmmoPhone 或 AmmoWatch。58 項 Swift 測試通過，兩個裝置版本編譯通過。手機已安裝並實測本機麥克風／動作資料；手錶安裝仍遇到網路通道逾時，尚未確認實體手錶版及兩台同步。測試紀錄：`docs/validation/local-sensors-validation.json`。

專案保留先前 BLE 和韌體程式；本輪主畫面不使用這些路徑。不要把先前 XIAO 測試當成本機聲音模型的準確率證據。


## 手錶主收音、手機判斷（2026/10/21 20:58）

- 在手機開啟 Ammo Estimate，再在手錶開啟 Ammo 雙端。手機預設選擇手錶收音，按「開始」後，由手錶取得頻譜與震動特徵，手機使用手錶原有模型判斷並保存計數，回傳手錶顯示。手機麥克風不會同時增加次數；未開始手錶收音時仍可單獨使用手機。
- 手錶只收音與顯示，沒有操作按鈕。手機「更多 → 收音來源」可切換為手機收音。手機「更多 → 手錶設定」可指示手錶收錄主特徵、補收背景及調整頻譜／震動參數；兩台模型各自保留，詳細設定在所屬裝置保存。容量、裝填、校正與累計重置仍由手機原有功能操作。
- 手機選手錶來源後，按「更多 → 試敲 5 次」也經手機分析。等約一秒後以要測的速度製造五次相同機械聲，等待「手機判斷 N／5 次」。驗證不增加累計。手機及手錶都必須保持 App 前景；腕降、鎖屏或連線中斷會停止流程。
- 不傳原始錄音。每包最多 24 個特徵視窗，單一封包等待確認後才送下一包；保留音訊輸入時鐘而非網路到達時間。工作階段 ID、連續序號與重複確認保護計數，遺失／亂序或超過 256 個待送視窗會停止並提示，不能宣稱零延遲或零漏記。真實輸入間隙會重置辨識器並顯示間隙數。
- 收錄／設定指令只用即時確認訊息，不離線排隊；正在驗證或計數時不能變更設定。停止與查詢仍可用。累計檔案及模型不隨安裝重置。
- 驗證檔案 `local-validation-*.json` 保留頻譜（無原始音訊）；`local-relay-validation.json` 記錄由手機分析的結果、視窗數、間隙及前後累計，供實機診斷。

實測需分開確認：手錶快速五次、未擊發時講話／移動、計數回傳、斷線提示、重新開啟後累計保留。單元測試與編譯成功不代表這些實機情境已通過。

## 手錶變暗後持續收音（準備中，背景能力待核准）

程式已準備好區分 `.active`、`.inactive` 與 `.background`。只有已開始且仍運行的手錶音訊引擎，加上 App 宣告 `UIBackgroundModes` 的 `audio`，才會在非前景狀態繼續。未啟用這項能力、尚未開始錄音或錄音被系統中斷時，不會啟動背景收音。手機仍須保持 App 在前景處理頻譜與計數。

待核准的設定僅在 `WatchApp/Info.plist` 加入 `UIBackgroundModes = [audio]`，等同手錶 Target 的 Background Modes → Audio；目前尚未套用。Bundle Identifier、Team、Signing、Deployment Target 與手機背景能力不更動。背景錄音使用現有麥克風授權，不保存原始錄音。首次開始需要先喚醒手錶，之後手機停止控制、音訊中斷及連線失敗仍會結束收音。

變暗畫面顯示目前收音狀態，降低畫面資料更新頻率；特徵傳送與判斷頻率不變。驗證診斷另記錄 `dimmedAudioFrames` 與 `dimmedRelayAcknowledgements`，安裝啟用後需實測放下手腕、變暗期間的五次驗證與手機停止控制，不能只以螢幕仍顯示數字判定收音成功。

依據：[Apple 背景錄音](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record)、[Always On 狀態](https://developer.apple.com/documentation/watchos-apps/designing-your-app-for-the-always-on-state)、[WatchConnectivity 即時可達條件](https://developer.apple.com/documentation/watchconnectivity/wcsession/isreachable)。
