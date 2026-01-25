# 功能說明

## 使用 Wrapper 腳本 (推薦)

本專案提供了一個強化的封裝腳本 `deploy_wrapper.sh`，可自動識別 ACME 客戶端 (Certbot 或 acme.sh) 並統一環境變數設定。

### 1. 設定連線資訊
編輯 `deploy_wrapper.sh`，在檔案中填入 NetScaler 的連線資訊：

```bash
# 設置 NetScaler 連線資訊
export NS_IP="192.168.2.13"
export NS_USER="nsroot"
export NS_PASS="P@ssw0rd"
```

### 2. 在 Certbot 中使用
在 renewing 憑證時指定 `--deploy-hook`：

```bash
certbot renew --deploy-hook /path/to/acme-deploy-netscaler/deploy_wrapper.sh
```

### 3. 在 acme.sh 中使用
雖然 acme.sh 支援內建部署 Hook，但您也可以將此 Wrapper 當作外部 Hook 使用：

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

### 4. 手動指定憑證路徑 (Manual Usage)
如果您的憑證檔案不在標準的 ACME 目錄結構中，或者您想要手動指定特定檔案，可以使用以下參數：

```bash
./deploy_wrapper.sh \
  --cert-file /path/to/cert.pem \
  --key-file /path/to/key.pem \
  --ca-file /path/to/chain.pem
```

### 5. 互動模式 (Interactive Mode)
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
從 [acme.sh](http://acme.sh/) 的設定檔中讀取 **NS_IP, NS_USER, NS_PASS, USE_FULLCHAIN** 等設定。
檢查 **CERT_PATH, CERT_KEY_PATH, CA_CERT_PATH** 等核心路徑是否存在，如果不存在則終止。
打印出所有憑證路徑以供偵錯。

### 步驟 2: 確定憑證物件名稱 (CERT_NAME)
優先使用您手動指定的 **CERT_NAME**。
如果未指定，則自動從憑證檔案中讀取通用名稱 (Common Name) 作為預設值。

### 步驟 3: 登入 NetScaler
使用 NS_USER 和 NS_PASS 透過 Nitro API 進行登入，獲取後續操作所需的 Session Token。

### 步驟 4: 偵測 NetScaler 韌體版本
向 API 查詢 NetScaler 的韌體版本。
判斷版本是否高於 14.1 Build 43。如果是，則設定一個內部參數，以便在後續新增/更新憑證時，自動加入 deleteCertKeyFilesOnRemoval 選項。

### 步驟 5: 取得現有憑證列表
從 NetScaler 獲取所有已安裝的憑證列表，用於後續判斷憑證是否已存在。

### 步驟 6: 選擇部署路徑 (核心邏輯)
這是腳本的核心分歧點。它會判斷 USE_FULLCHAIN 是否設為 1 且 CERT_FULLCHAIN_PATH 檔案是否存在。

- **路徑 A: Fullchain (Bundle) 部署 (如果條件成立)**
6A-1: 直接將 fullchain 憑證包和私鑰上傳。
6A-2: 發送 API 請求，並附帶 "bundle": "yes" 參數，讓 NetScaler 自動處理憑證鏈。
此路徑會跳過獨立處理 CA 和手動 Link 的步驟。
- **路徑 B: 標準 (分離) 部署 (如果條件不成立)**
6B-1: 獨立處理 CA_CERT_PATH，檢查中繼憑證是否存在，如果不存在則上傳並新增。
6B-2: 獨立處理 CERT_PATH，檢查伺服器憑證是否存在，如果不存在則上傳並新增。
6B-3: 如果在 6B-1 或 6B-2 中有新增任何憑證，則執行 "Link" 操作，將伺服器憑證與中繼憑證關聯起來。

### 步驟 7: 儲存 NetScaler 設定
如果前面的步驟中有任何成功的變更，腳本會儲存 USE_FULLCHAIN 等設定到 [acme.sh](http://acme.sh/) 的設定檔中。
同時，發送 API 請求以儲存 NetScaler 的執行中設定 (等同於 save ns config)。

### 步驟 8: 登出並清理
登出 Nitro API Session。
