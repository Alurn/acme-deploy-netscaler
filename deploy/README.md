# NetScaler Nitro API Deploy Hook

這是一個用於 `acme.sh` 的部署腳本，專門設計用來自動將 SSL 憑證部署到 Citrix NetScaler ADC (透過 Nitro API)。

## 功能特點

- 自動上傳憑證 (.cer) 與私鑰 (.key) 到 NetScaler。
- 支援標準憑證部署 (Server Cert + CA Cert) 與 Fullchain Bundle 部署。
- 自動偵測 NetScaler 版本，並針對支援的版本開啟 `deleteCertKeyFilesOnRemoval` 選項。
- 支援將 CA 憑證連結 (Link) 到 Server 憑證。
- 支援加密的私鑰 (需提供密碼)。
- 可選：自動刪除舊的憑證檔案以節省空間。
- 詳細的 API 請求日誌紀錄功能 (Debug 用)。

## 前置需求

- **acme.sh**: 必須已安裝並能成功簽發憑證。
- **NetScaler 帳號權限**: 需有足夠權限執行 `add ssl certKey`, `link ssl certKey`, `save ns config` 等操作。
- **工具**: 執行環境需有 `curl`, `openssl`, `grep`, `sed`。

## 安裝與設定

將 `netscaler.sh` 放置於 `acme.sh` 的 `deploy` 目錄下 (例如 `~/.acme.sh/deploy/`)。

### 環境變數設定

您可以透過匯出環境變數來設定連線資訊，或讓腳本自動儲存到 `acme.sh` 的設定檔中。

| 變數名稱 | 預設值 | 說明 |
| --- | --- | --- |
| `NS_IP` | `192.168.100.1` | NetScaler 的管理 IP 位址 |
| `NS_USER` | `nsroot` | 管理者帳號 |
| `NS_PASS` | `nsroot` | 管理者密碼 |
| `USE_FULLCHAIN` | `0` | 是否使用 Fullchain 部署 (`1`=開啟, `0`=關閉) |
| `NS_API_LOG` | `0` | 是否開啟 API 詳細日誌 (`1`=開啟)，日誌路徑 `./ns_api.log` |
| `NS_DEL_OLD_CERTKEY` | `0` | 是否在更新時刪除舊的檔案 (`1`=開啟, `0`=關閉) |
| `CERT_KEY_PASS` | (空) | 若私鑰有加密，需在此提供密碼 |

## 使用範例

假設您的網域為 `example.com`，使用以下指令進行部署：

```bash
# 1. 設定環境變數 (首次部署時需要)
export NS_IP="10.1.1.100"
export NS_USER="nsadmin"
export NS_PASS="mysecretpassword"

# 2. 執行 acme.sh 部署指令
acme.sh --deploy -d example.com --deploy-hook netscaler
```

部署成功後，`acme.sh` 會自動儲存這些設定，未來續期時無需再次匯出變數。

## 腳本邏輯流程

1. **初始化確認**: 檢查 `acme.sh` 傳入的憑證路徑變數。
2. **提取資訊**: 從憑證中自動解析 Common Name (CN) 作為 NetScaler 上的物件名稱。
3. **登入 API**: 取得 Nitro API Session Token。
4. **版本偵測**: 檢查 NetScaler 版本，決定是否使用新版參數。
5. **部署流程**:
   - **Fullchain 模式**: 上傳並更新 Bundle 憑證。
   - **標準模式**:
     - 檢查是否已有對應的 CA 憑證，若無則上傳並建立 CA物件。
     - 上傳 Server 憑證與私鑰。
     - 建立或更新 Server CertKey 物件。
     - 若為新建立，自動執行 Link 指令將 Server Cert 指向 CA。
6. **儲存設定**: 若有變更設定，執行 `save ns config`。
7. **清理**: 登出 Session 並刪除暫存檔。

## 疑難排解

若部署失敗，您可以開啟日誌功能查看詳細的 API 回應：

```bash
export NS_API_LOG=1
acme.sh --deploy -d example.com --deploy-hook netscaler
# 檢查當前目錄下的 ns_api.log
cat ns_api.log
```
