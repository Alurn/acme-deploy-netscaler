# 功能說明

## 使用 Wrapper 腳本

本專案提供了一個強化的封裝腳本 `deploy_wrapper.sh`，可自動識別 ACME 客戶端 (Certbot 或 acme.sh) 並統一環境變數設定。

### 步驟 1. 設定連線資訊
將專案根目錄下的 `.env.example` 複製為 `.env`，並填入您的 NetScaler 連線資訊：

```bash
# 複製範本檔案
cp .env.example .env
```

接著編輯 `.env` 檔案填入連線資訊：

```env
# NetScaler 連線資訊
NS_IP="192.168.2.13"
NS_USER="nsroot"
NS_PASS="P@ssw0rd"
```

> **注意**: `.env` 檔案包含敏感密碼資訊，已被加入 `.gitignore`，請勿將其提交至 Git。

### 步驟 2. 選擇部署方式
您可以根據您的需求，選擇以下其中一種方式進行部署：

#### 在 Certbot 中使用
在 renewing 憑證時指定 `--deploy-hook`：

```bash
certbot renew --deploy-hook /path/to/acme-deploy-netscaler/deploy_wrapper.sh
```

#### 在 acme.sh 中使用
acme.sh 提供兩種方式整合本專案的腳本：

##### 方式 1：使用內建模組 (推薦)

1. **安裝 Hook**:
   將 `deploy/netscaler.sh` 複製到 acme.sh 的 `deploy` 目錄下：
   ```bash
   cp /path/to/acme-deploy-netscaler/deploy/netscaler.sh ~/.acme.sh/deploy/netscaler.sh
   ```

2. **執行部署**:
   現在您可以使用 `netscaler` 作為標準部署模組：
   ```bash
   acme.sh --deploy -d example.com --deploy-hook netscaler
   ```
   *(第一次執行後，acme.sh 會記住設定，未來 renew 時會自動觸發)*

##### 方式 2：直接調用腳本

如果您不想將腳本複製到 acme.sh 目錄，也可以直接使用 `deploy_wrapper.sh` 來部署憑證：

```bash
# 申請憑證時設定部署腳本
acme.sh --issue -d example.com --deploy-hook "/path/to/acme-deploy-netscaler/deploy_wrapper.sh"

# 或者對已存在的憑證執行部署
acme.sh --deploy -d example.com --deploy-hook "/path/to/acme-deploy-netscaler/deploy_wrapper.sh"
```

> **提示**: 設定後，acme.sh 會記住這個部署腳本，未來自動續期時會自動執行部署。

#### 手動指定憑證路徑 (Manual Usage)
如果您的憑證檔案不在標準的 ACME 目錄結構中，或者您想要手動指定特定檔案，可以使用以下參數：

```bash
./deploy_wrapper.sh \
  --cert-file /path/to/cert.pem \
  --key-file /path/to/key.pem \
  --ca-file /path/to/chain.pem
```

#### 互動模式 (Interactive Mode)
如果您直接執行腳本且未提供任何環境變數或參數，腳本將進入互動模式，提示您輸入必要的檔案路徑：

```bash
./deploy_wrapper.sh
# 腳本將會詢問您 Certificate, Private Key 和 CA Chain 的路徑
```

---

## 邏輯優先順序 (Logic Priority)

腳本會依照以下順序決定使用的憑證來源：

1.  **Certbot 環境**: 檢查是否由 Certbot 呼叫 (檢測 `RENEWED_LINEAGE`)。
2.  **acme.sh 環境**: 檢查是否由 acme.sh 呼叫 (檢測 `CERT_KEY` 和 `CERT_FULLCHAIN`)。
3.  **手動參數**: 檢查是否提供了 `--cert-file` 等命令行參數。
4.  **互動模式**: 如果以上皆非，則進入互動模式詢問使用者。

---

## 腳本詳細邏輯 (Internal Logic)

### 步驟 1: 初始化與環境變數檢查
1. 從 [acme.sh](http://acme.sh/) 的設定檔或優先環境變數中讀取 **NS_IP, NS_USER, NS_PASS, USE_FULLCHAIN** 等設定。
2. 若未設定 `NS_IP` 等連線資訊，則嘗試從腳本周邊或當前目錄的 `.env` 檔案中載入。
3. 檢查 **CERT_PATH, CERT_KEY_PATH, CA_CERT_PATH** 等核心路徑是否存在，如果不存在則終止。
4. 檢查連線參數是否齊全，不齊全則中止並顯示錯誤訊息。
5. 打印出所有憑證路徑以供偵錯。

### 步驟 2: 確定憑證物件名稱 (CERT_NAME)
優先使用您手動指定的 **CERT_NAME**。
如果未指定，則自動從憑證檔案中讀取通用名稱 (Common Name) 作為預設值。

### 步驟 3: 登入 NetScaler
使用 NS_USER 和 NS_PASS 透過 Nitro API 進行登入，獲取後續操作所需的 Session Token。

### 步驟 4: 偵測 NetScaler 韌體版本
向 API 查詢 NetScaler 的韌體版本。
判斷版本是否高於 14.1 Build 43。如果是，則設定一個內部參數，以便在後續新增/更新憑證時，自動加入 deleteCertKeyFilesOnRemoval 選項。

### 步驟 5: 取得現有憑證列表與序號比對
1. 從 NetScaler 獲取所有已安裝的憑證列表（包含其 `serial` 序號）。
2. **憑證已存在之判斷機制（使用十六進位序號）**：
   * 腳本會使用 `openssl x509 -noout -serial` 讀取本地憑證（伺服器憑證與中繼 CA 憑證）的十六進位序列號。
   * 將讀取出的序號轉換為大寫並移除冒號，接著在取得的 NetScaler 憑證列表中進行比對（如 `grep -qi "$_l_server_serial"`）。
   * 如果序號已存在於 NetScaler 中，表示該憑證已部署且最新，將會**跳過上傳與建立流程**，避免重複配置或造成不必要的服務中斷。

### 步驟 6: 選擇部署路徑 (核心邏輯)
這是腳本的核心分歧點。它會判斷 USE_FULLCHAIN 是否設為 1 且 CERT_FULLCHAIN_PATH 檔案是否存在。

- **路徑 A: Fullchain (Bundle) 部署 (如果條件成立)**
  * **6A-1**: 讀取本地憑證序列號比對，若不匹配，則上傳 fullchain 憑證包與私鑰。
  * **6A-2**: 發送 API 請求，並附帶 `"bundle": "yes"` 參數，讓 NetScaler 自動處理憑證鏈。此路徑會跳過獨立處理 CA 和手動 Link 的步驟。
- **路徑 B: 標準 (分離) 部署 (如果條件不成立)**
  * **6B-1 (中繼 CA 處理)**：讀取本地中繼憑證序列號，若 NetScaler 上無對應序號，則上傳 CA 並新增 `sslcertkey` 物件；若已有匹配序號，則直接沿用已有的 CA 物件名稱。
  * **6B-2 (伺服器證書處理)**：讀取本地伺服器憑證序列號，若不匹配，則上傳證書與私鑰，並發送 API 新增或更新（`?action=update`）憑證物件。
  * **6B-3 (連結憑證鏈)**：如果在 6B-1 或 6B-2 中有新增任何憑證，則執行 `"Link"` 操作，將伺服器憑證與中繼憑證關聯起來。

### 步驟 7: 儲存 NetScaler 設定
如果前面的步驟中有任何成功的變更，腳本會儲存 USE_FULLCHAIN 等設定到 [acme.sh](http://acme.sh/) 的設定檔中。
同時，發送 API 請求以儲存 NetScaler 的執行中設定 (等同於 save ns config)。

### 步驟 8: 登出並清理
登出 Nitro API Session。
