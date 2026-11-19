# HomeCam for iPhone

只裝在 iPhone 的家用攝影機 App。不需要電腦或伺服器，也不經過任何雲端。

## 功能

| | |
|---|---|
| 自動搜尋 | 掃描同一個 WiFi 網段的 RTSP / ONVIF 攝影機，點選後輸入帳密就能加入；會自動抓主碼流、子碼流和雲台 |
| 即時畫面 | 多台同時看，用硬體解碼、延遲低；可全螢幕、旋轉、雙指放大 |
| 控制 | 雲台：按住移動、放開停止，最多 2 秒自動停；可縮放、回原點、使用和儲存預置點 |
| 手機錄影 | 手動錄影或有移動才錄。移動錄影會包含觸發前約 4 秒；直接轉存不重新壓縮；App 被關掉時已錄的部分不會毀損 |
| 記憶卡回放 | 24 小時錄影存在攝影機的記憶卡，App 可從記憶卡串流回放（海康、大華/Imou/Amcrest） |
| 逐字稿 | 用 iPhone 內建語音辨識，預設只在手機上處理；台灣繁體中文；可依日期瀏覽、全文搜尋、分享 |
| 偵測與通知 | 移動偵測（可調敏感度，會忽略開關燈和夜視切換）、事件時間軸與截圖；逐字稿出現關鍵字時通知 |
| 值守模式 | App 在背景也繼續偵測、錄影、做逐字稿並發通知 |

## 隱私與安全設計

- **不連雲端**：只連你家網路內的攝影機。沒有帳號，也沒有任何統計或分析功能。
- **攝影機密碼**：存在 iOS Keychain，設為只存在這支手機（ThisDeviceOnly），不會同步到 iCloud 鑰匙圈，也不會進備份。
- **資料加密**：錄影、截圖、逐字稿用 iOS 資料保護加密，放在 App 自己的私有空間，「檔案」App 和電腦都看不到。
- **不備份**：預設不進 iCloud 備份。
- **App 鎖**：用 Face ID 或手機密碼解鎖，可以設定離開多久後要重新解鎖。
- **隱私遮罩**：切到多工畫面時遮住畫面；偵測到錄螢幕或 AirPlay 鏡像時也會遮住影像。
- **通知不露內容**：預設鎖定畫面只顯示「有新的事件」，不顯示文字和截圖。
- **語音不上傳**：預設只在手機上辨識。手機不支援離線辨識時，會直接提示，不會自動改用伺服器。
- **日誌不含帳密**：程式記錄裡不會出現帶帳號密碼的網址。
- **安全檢查**：設定頁會檢查手機密碼、App 鎖、各台攝影機的弱密碼，並列出網路安全建議。

## 只用 iPhone 安裝（不需要電腦）

程式會在 GitHub 的 Mac 雲端主機上編譯，再送到 TestFlight；iPhone 用 TestFlight 一鍵安裝。之後要更新，也是在 GitHub App 按一下就好。

**一次性設定（全部用 iPhone 的 Safari 完成，約 15 分鐘）：**

1. **建立 App 金鑰**：打開 appstoreconnect.apple.com →「使用者與存取權限」→「整合」→「App Store Connect API」→ 新增金鑰，存取權選「管理」。記下**金鑰 ID**、**Issuer ID**，然後下載 `.p8` 檔（只能下載一次）。
2. **把 .p8 轉成文字**：到「檔案」App 長按這個檔案 →「重新命名」，把副檔名改成 `.txt` → 打開後全選、拷貝。
3. **查 Team ID**：developer.apple.com/account →「會員資格詳細資訊」→「團隊 ID」。
4. **建立 App 紀錄**：App Store Connect →「App」→「＋ 新增 App」，平台選 iOS，名稱填 HomeCam（重複的話加字），套件識別碼填 `com.你的名字.homecam`。這個 App 只會在 TestFlight 內部測試使用，不會上架。
5. **在 GitHub repo 填設定**（Safari 開 repo →Settings）：
   - Secrets and variables → Actions → **Secrets**：
     - `ASC_KEY_ID`：金鑰 ID
     - `ASC_ISSUER_ID`：Issuer ID
     - `ASC_KEY_P8`：貼上 .p8 的完整內容（包含 BEGIN/END 那兩行）
   - **Variables**：
     - `TEAM_ID`：團隊 ID
     - `BUNDLE_ID`：第 4 步填的套件識別碼
6. 刪掉「檔案」App 裡的 .p8 / .txt，避免金鑰外流。
7. 打開 GitHub App → 這個 repo →「Actions」→「Build & TestFlight」→「Run workflow」。
8. 約 20–30 分鐘後，App Store 下載「TestFlight」，裡面就會出現 HomeCam，點「安裝」。

**之後更新**：程式有修改時會自動重新編譯；也可以手動按「Run workflow」。TestFlight 會通知你更新，點一下就好。

> TestFlight 版本每 90 天到期，到期前再按一次 Run workflow 就會延長。
> 私人 repo 每月有免費的 Mac 雲端時間，大約能編譯 8–10 次，個人使用很夠。

## 用 Mac 安裝（開發用）

需要：Mac + Xcode 16.3 以上、iPhone（iOS 17 以上）、Apple 開發者帳號。

```bash
brew install xcodegen
cd HomeCamiOS
xcodegen generate
open HomeCam.xcodeproj
```

1. 打開 `project.yml`，把 `PRODUCT_BUNDLE_IDENTIFIER` 改成你自己的（例如 `com.kh.homecam`），再執行一次 `xcodegen generate`
2. 在 Xcode 點 HomeCam target →「Signing & Capabilities」→ 選你的 Team
3. 第一次開啟時，Xcode 會下載 FFmpegKit（約 1.5 GB，要等一段時間）
4. 用線接上 iPhone，選擇你的 iPhone →按 ▶︎ 執行
5. 如果 iPhone 跳出提示，到「設定 → 隱私權與安全性 → 開發者模式」打開
6. App 第一次開啟時，請允許**區域網路**（必要）、**通知**、**語音辨識**

> 這個專案是在沒有 Xcode 的環境寫的。影音核心（C）已經用 FFmpeg 8 的 iOS 標頭檔通過編譯檢查並實測過，但 Swift 部分還沒編譯過。如果 Xcode 出現錯誤，把錯誤訊息貼給我就能修。

## 攝影機設定建議

1. **24 小時錄影**：在攝影機原廠 App 插入 microSD 卡，開啟「連續錄影」或「全天錄影」
2. **關閉雲端**：關閉雲端儲存、遠端存取、P2P。路由器關閉 UPnP，可以的話把攝影機放在「IoT / 訪客網路」，並封鎖它連到網際網路
3. **開啟 RTSP / ONVIF，建立攝影機帳號**
   - Tapo：App →攝影機 →設定 →進階設定 →「攝影機帳號」
   - 海康 / 螢石：帳號 `admin`，密碼是機身上的驗證碼；螢石要在 App 裡開啟 RTSP
   - Reolink / 大華 / Imou：用原廠 App 的管理員帳密
   - 小米 / 米家：多數型號不支援 RTSP/ONVIF，無法接入
4. **記憶卡回放**：海康、大華、Imou、Amcrest 可以在 HomeCam 直接回放。Tapo、Reolink 沒有開放記憶卡串流，只能在原廠 App 用「本機回放」

## 值守模式要知道的事

- 原理：App 持續播放無聲音訊，讓 iOS 不會把它暫停。這種做法只適合自己安裝使用，送 App Store 審核會被拒
- 很耗電，建議接上充電器。可以用一支舊 iPhone 當專用監看機，開啟「值守時螢幕保持開啟」
- 來電、其他 App 搶走音訊、記憶體不足或手機重開機時，iOS 仍可能停止 App。中斷結束後會自動恢復，但重開機後要手動打開 App
- 在背景時改用軟體解碼來做移動偵測（iOS 不允許背景使用硬體解碼器）
- **所以 24 小時不中斷的錄影，請一定要開啟攝影機的記憶卡錄影**

## ONVIF 多播搜尋（選用）

iOS 送出多播封包需要向 Apple 申請 `com.apple.developer.networking.multicast` 權限。沒有這個權限時，App 會改用網段掃描，通常一樣找得到攝影機。如果拿到權限，取消 `project.yml` 裡那行的註解即可。

## 專案結構

```
HomeCam/Engine/      C 影音核心（FFmpeg）：RTSP 讀取、VideoToolbox 解碼、移動偵測、錄影、音訊
HomeCam/Media/       CameraSession（每台攝影機的執行狀態）、播放聲音、語音辨識
HomeCam/Network/     ONVIF、搜尋攝影機
HomeCam/Services/    設定與儲存、Keychain、事件、通知、App 鎖
HomeCam/Views/       SwiftUI 介面
EngineTests/         影音核心的電腦端測試（make media && make test）
```

## 授權

影音處理使用 FFmpeg（透過 kingslay/FFmpegKit，GPL），只限個人使用。不要散布或上架。
