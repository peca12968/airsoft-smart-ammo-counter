# Airsoft Smart Ammo · 本機感測版

原生 iPhone／Apple Watch App。使用各自麥克風的聲音強度、Hz 頻譜與動作感測器分類震動／聲音事件，數量均為推估值。

目前先使用 Apple 裝置本機感測，不需 XIAO。請閱讀 [操作與限制](docs/LOCAL-SENSORS.md)。

操作：開始監聽 → 收錄聲音與震動特徵 → 安靜3秒 → 敲擊3–5次 → 啟用計數。三種模式：聲音頻譜／聲音＋震動／震動。App 需保持前景。

更新 App、重新訓練、校正或裝填不清除累計；重置只由手機確認按鈕執行。原始錄音不存檔。

Xcode 開啟 `AirsoftSmartAmmo.xcodeproj`，選 AmmoPhone 或 AmmoWatch。58 項 Swift 測試通過，兩個裝置版本編譯通過。手機已安裝並實測本機麥克風／動作資料；手錶安裝仍遇到網路通道逾時，尚未確認實體手錶版及兩台同步。測試紀錄：`docs/validation/local-sensors-validation.json`。

專案保留先前 BLE 和韌體程式；本輪主畫面不使用這些路徑。不要把先前 XIAO 測試當成本機聲音模型的準確率證據。
