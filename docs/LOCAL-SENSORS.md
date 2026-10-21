# 手機與 Apple Watch 本機感測版

目前主畫面改為使用正在操作的 Apple 裝置自己的麥克風與動作感測器。App 不需要連接 XIAO；舊 BLE／韌體原始碼保留供之後使用，本輪原生功能不呼叫它們。

## 手機操作

1. 開啟「Ammo Estimate」，畫面標題為「Ammo · 本機辨識」。
2. 按「開始監聽」，允許麥克風與動作權限。可看到本機聲音強度、主峰 Hz、8 個頻帶及動作加速度。
3. 按「收錄聲音與震動特徵」。先安靜 3 秒，再依提示於 6 秒內敲擊 3–5 次，每次間隔約 1 秒。保持手機的位置與之後使用時一致。
4. 特徵保存後按「啟用計數」。預設依聲音音量與頻譜形狀比對；新一次聲音事件才增加累計，持續聲或餘響不重複增加。
5. 太容易誤觸時，提高「頻譜相似度」，或選「聲音＋震動」。混合模式要求聲音符合且附近 150ms 有高於門檻的本機動作。
6. 「震動」模式依去除重力後的加速度與回復門檻觸發；不是聲音分類。可調整震動門檻。

手錶提供相同的監聽、收錄、三種觸發模式與計數控制，使用手錶自己的麥克風與 IMU。請在手錶實際配戴位置另收錄一份樣本。ScrollView、Picker 和 Stepper 可配合 Digital Crown 操作。

## 即時處理

使用 AVAudioSinkNode 接收硬體音訊。即時音訊執行緒只將資料複製到有界 RAM ring，使用 try-lock、不等待鎖、不在音訊執行緒做 FFT、寫檔或等待無線連線。獨立 userInteractive queue 進行 Accelerate FFT。典型 48kHz 使用 1024 樣本（約21.3ms）的分析視窗；實際 I/O 時序由系統決定，不能把視窗長度當成實測端到端延遲。

頻帶為 125–250、250–500、500–1000、1–2k、2–3k、3–4k、4–6k、6–8k Hz。頻帶能量正規化後，以 cosine similarity 比對收錄範本；音量另須高於學得底噪。這是聲音頻譜範本，不是人物身分聲紋或原始音軌辨識器。

計數先在本機更新與保存，再嘗試同步，無需等手機、手錶或 BLE 回應。模型和累計保存在 App 資料夾，原始 PCM 不寫入檔案。

## 累計保存與同步

累計保留既有裝置快取中的終身計數作起點，並以各來源的單調計數合併；同一同步封包重送不重複加數。兩個原子寫入檔案保存本機資料，啟動時合併有效檔案，避免落回較舊的零值。重新裝填、調整容量、校正、重新收錄或更新 App 不會清除累計。

只有手機的「重置累計擊發」確認按鈕會變更顯示重置基準；底層終身紀錄仍保留。手錶沒有重置累計入口。

一次只在其中一台啟用感測；另一台用來顯示。配對同步採 WatchConnectivity，已收到新的感測來源接管訊息時會暫停舊來源。離線同時在兩台啟用仍可能把同一物理事件計兩次，因此不要同時啟用兩台。

**目前實機手機／手錶同步尚未驗證。** 手錶新版安裝遇到 Xcode 網路通道逾時，不能宣稱手錶已更新或兩台已實際同步。既有獨立 App 目標的 companion 配對也需在實體新版完成安裝後確認。

## 驗證與目前限制

- 58 項 Swift 測試通過，包括舊資料遷移、重送去重、雙來源合併、重新裝填、明確重置後復原及感測來源收斂。
- 生產程式使用的 FFT 以同音量 1250Hz、5000Hz 訊號測試，主峰及頻帶可分辨，模型排除不同頻率。
- iPhone、watchOS 實體裝置目的地編譯通過。
- iPhone 新版已安裝，已由真正的本機麥克風與動作回呼取得資料；詳見 `validation/local-sensors-validation.json`。
- watchOS 程式已編譯，實體安裝與感測測試仍待可用連線。
- 目前要求 App 保持前景；進入背景或發生音訊中斷會停止監聽。重新開啟後需要手動開始，避免默默監聽。
- 未實測真實 BB 擊發、全自動速率或長時間電池消耗。相似聲音、碰撞仍可能誤計，數量全部為推估，保留手動校正。

## 建置

在 Xcode 開啟 `AirsoftSmartAmmo.xcodeproj`，使用 AmmoPhone 或 AmmoWatch scheme。Swift 核心測試可執行 `swift test`。不需要 Arduino 工具鏈來建置本機感測 App。簽章沿用本機已選定的開發 Team；不包含憑證或描述檔。

Apple 參考文件：

- AVAudioSinkNode：https://developer.apple.com/documentation/avfaudio/avaudiosinknode
- AVAudioSession：https://developer.apple.com/documentation/avfaudio/avaudiosession
- WatchConnectivity：https://developer.apple.com/documentation/watchconnectivity/transferring-data-with-watch-connectivity
