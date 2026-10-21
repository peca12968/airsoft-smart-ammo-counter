# GATT v1：狀態、安全與訓練延伸

`gatt.json` 是固定 UUID 與長度的唯一來源，`scripts/generate_protocol.py` 產生 Swift/C++ 常數。所有整數和 Float32 為 little endian。v1 舊有 1001–1004 封包保持相容；新增 1005–1009 為選用服務。

| 特徵 UUID 前綴 | 名稱 | 長度 | 用途 |
|---|---|---:|---|
| 7A6B1001 | identity | 9 | version u8, stable deviceID u64 |
| 7A6B1002 | state | 20 | version0, flags1, capacity u16@2, remaining u16@4, lifetime u32@6, sequence u32@10, boot u32@14, battery u8@18, zero19 |
| 7A6B1003 | command | 16 | version0, opcode1(reload1/correct2/capacity3), value i16@2, request u32@4, expectedSeq u32@8, boot u32@12 |
| 7A6B1004 | ack | 14 | version0, result1, request u32@2, boot u32@6, sequence u32@10 |
| 7A6B1005 | safety | 20 | version0, flags1, rail mV u16@2, MCU quarter-C i16@4, USB6, charge7, reason8, zero9–11, sample u32@12, boot u32@16 |
| 7A6B1006 | trainingControl | 16 | version0, opcode1, seconds u16@2, request u32@4, boot u32@8, modelID u32@12 |
| 7A6B1007 | trainingData | 20 | version0, quality flags1, capture u16@2, sequence u16@4, samples6, label7, timestamp ms u32@8, peak mg u16@12, RMS mg u16@14, gyro dps×10 u16@16, clippedCount18, zero19 |
| 7A6B1008 | profileChunk | 20 | version0, chunk index1(0–3), transferID u16@2, 16-byte payload@4 |
| 7A6B1009 | trainingStatus | 20 | version0, mode1, result2, flags3, request u32@4, modelID u32@8, sent u16@12, dropped u16@14, boot u32@16 |

完整 UUID 後綴均為 `-5C29-4B87-9E31-41AC08D2E640`，service 為 `7A6B1000-5C29-4B87-9E31-41AC08D2E640`。read/notify 與 write-with-response 屬性詳見 JSON。全部封包在 ATT MTU23 下傳送。

訓練命令：1背景、2目標、3停止、4啟用、5停用。採集秒數4–20；captureID是非零 requestID低16位。相同連線 session 的相同最後成功命令重傳不重啟採集；同request不同內容拒絕。mode：0停止、1背景、2目標、3偵測；result：0成功、1無效/過期boot、2忙碌、3安全拒絕、4保存失敗。flags：1有模型、2測試模型、4IMU就緒。封包品質 flags：1候選、2飽和、4取樣間隙、8settling；label 0背景/1目標。

手機逐包等待 profileChunk write response。四塊組成64B模型；裝置驗證 CRC、有限浮點數、特徵配置、範圍，雙槽保存後以 trainingStatus 的 request=transferID 確認。上傳不會直接啟用；後續 enable 必須指定同一 modelID 和當前 boot。進行中的上傳由連線 handle+session 擁有，5秒逾時；採集同時只允許一個owner，斷線後停止。

模型64B：magic u32@0=0x31444D41；[version1,dims3,samples16,rateCode1]@4；id u32@8；test u8@12；zero13；refractory ms u16@14；onset Float32@16；means Float32×3@20；scales×3@32；distance squared@44；minPeakG@48；rearmG@52；createdAt u32@56；CRC32 IEEE(first60)@60。rateCode1=416Hz。

state 是 XIAO 權威狀態。即使 notify 遺失，重讀 state 的 boot/sequence/lifetime 可復原；不以收到通知次數計數。手機每5秒讀取完整狀態、安全及訓練狀態。訓練特徵有獨立序號、來源與標籤；缺包會被標記且不回補為有效樣本。離線快取只顯示估計值，新 GATT identity/read 握手建立新排序區段；同一連線仍拒絕同序號不同內容。所有操作需合法資料與當前狀態，命令超時顯示結果未知。

安全欄位：rail未知FFFF、溫度未知8000、充電未知FF；flags 1溫度有效/2電壓有效/4提醒/8應用鎖定。溫度為MCU，不是電池。主命令 ACK results：accepted0/stale1/invalid2/storage3/exhausted4。主state flags：IMU1/USB錄製2/儲存錯誤4/lifetime飽和8/sequence耗盡16/模擬32。

本地BLE為開放式自訂服務，模型CRC用於完整性檢查，不提供身份驗證或加密來源證明。目前沒有無線韌體更新指令。


## 自適應模型與即時訊號延伸（2026-10-21）

新版模型允許 onset ≥0.002g（Float32容差0.0019999），由手機底噪估計。採集不能只採納韌體候選旗標；完整特徵由手機後分群。舊有64B模型與其CRC格式保持相容。

選用特徵 liveSignal：`7A6B100A-5C29-4B87-9E31-41AC08D2E640`，20B read/notify。version@0=1；flags@1(bit0麥克風有效、bit1飽和、bit2IMU就緒)；sequence u16@2（非零、模組差值判重）；timestamp ms u32@4；RMS u16@8；peak u16@10；IMU peak mg u16@12；audio sample count u16@14；boot u32@16。音量範圍0–32768，為相對數值，不是校準聲壓。無麥克風有效資料時samples/rms/peak均0。序號與boot防止重複、過期連線資料混入波紋。

trainingControl opcode6取得/續期即時監看租約，value=1–20秒；opcode7釋放該owner租約。不改動訓練requestID，不觸發計數、不啟用或停用原有模型。owner以連線handle+session隔離；採集期間優先只向採集owner通知。手機在前景每10秒續租；停止或失聯後不無限監聽。

Serial `d`：僅在未採集／偵測且安全狀態正常時執行4秒IMU+麥克風診斷，不改計數、不寫音訊或計數journal。`?`列出音訊樣本／峰值及特徵品質統計。


## 非阻塞通知傳送

採集特徵和採集完成狀態共用有界 FIFO，保持每連線順序。`sent` 記錄已成功排入傳送的特徵數；若傳送未完成，手機仍以序號及最終數量核對遺失。滿載則計入 `dropped`，不等待 BLE 連線事件阻塞 IMU。預覽可合併；session 過期資料捨棄。SoftDevice 資源不足留待下一主迴圈重試，其他傳送錯誤列入 Serial `notify_errors`。手機仍保留遺失及取樣間隙門檻，不把有波紋當成採集品質合格。
