# Airsoft Smart Ammo Counter · Ammo Estimate

原生 iPhone／Apple Watch SwiftUI App、CoreBluetooth 雙客戶端同步，以及 **原版 Seeed XIAO nRF52840 Sense** Arduino 韌體。所有數量皆為推估值，不宣稱量測實際 BB；裝置只記錄震動，不連接任何發射機構。

## 最新操作

手機 **採集訓練 → 開始訓練**。先靜置4秒量底噪，再依綠燈提示敲桌面3–5次；目標最多8秒、收足提前分析。紅燈分析；無訊號會解釋並停止。即時監看顯示來自XIAO的震動與內建麥克風音量波紋；只傳音量包絡，不保存音檔。詳見 [操作與新採集方法](docs/TRAINING.md)。

計數頁支援30/130/150/300與自訂1–9999、重新裝填、手動校正、低於15%提醒、累計擊發推估、電量與安全狀態。累計不因重新裝填而歸零。Demo不需硬體，包含採集、分析、模型上傳確認、啟用與持續模擬計數。

設定關閉 Demo，裝置頁選擇 XIAO Ammo Estimate。手機與手錶可以同時連接同一板子（最多2個BLE中央裝置）。電池紅線既有滑動開關維持原樣，不需改接。

## 在 Xcode 開啟與編譯

開啟 `AirsoftSmartAmmo.xcodeproj`，scheme `AmmoPhone` 或 `AmmoWatch`。使用原有開發Team；不要把別人的Team或憑證複製到你的帳號。

已使用 Xcode16.2、Swift6.0.3、iOS18.2/watchOS11.2 SDK 編譯；App最低iOS17、watchOS11。Swift Package測試最低macOS13。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project AirsoftSmartAmmo.xcodeproj -scheme AmmoPhone -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project AirsoftSmartAmmo.xcodeproj -scheme AmmoWatch -destination 'generic/platform=watchOS' CODE_SIGNING_ALLOWED=NO build
python3 scripts/generate_protocol.py --check
```

若文件夾由iCloud管理，請先確認檔案已下載，並把編譯目錄放本機暫存位置。不要把 DerivedData 或 Arduino BSP 巨量快取打包進交付檔。

## 韌體

開啟 `firmware/AmmoSensor/AmmoSensor.ino`，BSP使用 **Seeed nRF52 Boards 1.1.13（非mbed）**，board選 **Seeed XIAO nRF52840 Sense（原版，非Plus）**，Seeed Arduino LSM6DS3驅動需支援原版Sense的Wire1巨集。依賴BSP內建Bluefruit52、LittleFS、InternalFileSystem、TinyUSB。

內部IMU：LSM6DS3TR-C、Wire1、0x6A、BSP `PIN_LSM6DS3TR_C_POWER=15`（原版P1.08），416Hz、8g、2000dps。固定腳位以BSP與[官方驅動](https://github.com/Seeed-Studio/Seeed_Arduino_LSM6DS3)確認；韌體有編譯期原版board檢查，禁止套用Plus。

已燒錄對應映像位於 `firmware/prebuilt/training/`，manifest包含SHA256。只更新應用程式，未擦除bootloader。再次燒錄實體板仍須使用者授權。USB Serial115200：`?`唯讀狀態、`r/s`開始/停止原始數據、`0–3`標籤、`e`為**會改變計數**的模擬事件。不要將DFU資料送入應用程式串口。

## 架構與協定

`Sources/AmmoCore`：計數、封包、同步、持久化、Demo、安全、特徵與訓練。`WatchApp/WatchStore.swift`共用應用狀態，BLEManager處理實體BLE；PhoneApp/WatchApp各有原生UI。`Tests/AmmoCoreTests`包含計數、異常封包、同步、安全、模型與多輪資料分析。

[固定GATT定義](Protocol/gatt.json)、[封包與模型文件](Protocol/TRAINING.md)、[驗證結果](docs/validation/training-validation.json)。XIAO為計數權威來源；快取、重連、重複封包、遺失通知、命令確認、重新開機與CRC驗證皆有處理。

## 實際驗證範圍

最新狀態以 validation JSON 為準。手機已透過Wi-Fi安裝；XIAO採集韌體已透過USB燒錄、IMU就緒、計數保留。手錶編譯成功，但最新版實機安裝仍遭無線通道逾時；不宣稱已更新或已完成真實擊發辨識。

晶片溫度不等於電池溫度；軟體不會切斷充電。保持既有電池正極串聯開關時，關閉開關會斷開電池，插USB仍開機但不能替已斷開的電池充電。沒有Wi-Fi，也尚未實作BLE韌體OTA；訓練模型可透過BLE更新。
