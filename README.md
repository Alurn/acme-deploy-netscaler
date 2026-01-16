**步驟 1: 初始化與環境變數檢查**
從 [acme.sh](http://acme.sh/) 的設定檔中讀取 **NS_IP, NS_USER, NS_PASS, USE_FULLCHAIN** 等設定。
檢查 **CERT_PATH, CERT_KEY_PATH, CA_CERT_PATH** 等核心路徑是否存在，如果不存在則終止。
打印出所有憑證路徑以供偵錯。

**步驟 2: 確定憑證物件名稱 (CERT_NAME)**
優先使用您手動指定的 **CERT_NAME**。
如果未指定，則自動從憑證檔案中讀取通用名稱 (Common Name) 作為預設值。

**步驟 3: 登入 NetScaler**
使用 NS_USER 和 NS_PASS 透過 Nitro API 進行登入，獲取後續操作所需的 Session Token。

**步驟 4: 偵測 NetScaler 韌體版本**
向 API 查詢 NetScaler 的韌體版本。
判斷版本是否高於 14.1 Build 43。如果是，則設定一個內部參數，以便在後續新增/更新憑證時，自動加入 deleteCertKeyFilesOnRemoval 選項。

**步驟 5: 取得現有憑證列表**
從 NetScaler 獲取所有已安裝的憑證列表，用於後續判斷憑證是否已存在。

**步驟 6: 選擇部署路徑 (核心邏輯)**
這是腳本的核心分歧點。它會判斷 USE_FULLCHAIN 是否設為 1 且 CERT_FULLCHAIN_PATH 檔案是否存在。

- **路徑 A: Fullchain (Bundle) 部署 (如果條件成立)**
6A-1: 直接將 fullchain 憑證包和私鑰上傳。
6A-2: 發送 API 請求，並附帶 "bundle": "yes" 參數，讓 NetScaler 自動處理憑證鏈。
此路徑會跳過獨立處理 CA 和手動 Link 的步驟。
- **路徑 B: 標準 (分離) 部署 (如果條件不成立)**
6B-1: 獨立處理 CA_CERT_PATH，檢查中繼憑證是否存在，如果不存在則上傳並新增。
6B-2: 獨立處理 CERT_PATH，檢查伺服器憑證是否存在，如果不存在則上傳並新增。
6B-3: 如果在 6B-1 或 6B-2 中有新增任何憑證，則執行 "Link" 操作，將伺服器憑證與中繼憑證關聯起來。

**步驟 7: 儲存 NetScaler 設定**
如果前面的步驟中有任何成功的變更，腳本會儲存 USE_FULLCHAIN 等設定到 [acme.sh](http://acme.sh/) 的設定檔中。
同時，發送 API 請求以儲存 NetScaler 的執行中設定 (等同於 save ns config)。

**步驟 8: 登出並清理**
登出 Nitro API Session。
