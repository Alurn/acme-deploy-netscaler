# 已知問題與情境分析 (Issues & Scenarios)

本文件記錄 `deploy/netscaler.sh` 在處理憑證更新、多張中繼憑證 (Intermediate CA) 以及憑證鏈結 (Link) 時的行為情境與待改進項目。

---

## 議題 1：多張中繼憑證 (Multiple Intermediate CAs) 部分更換的偵測限制

### 現況說明
在 **標準分離模式 (`USE_FULLCHAIN=0`)** 下，腳本透過以下指令解析 `CA_CERT_PATH`：
```bash
_l_serial=$(openssl x509 -in "$_l_path" -noout -serial | cut -d'=' -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')
_ca_cn=$(openssl x509 -in "$_l_path" -noout -subject | sed -n 's/.*CN = //p' | cut -d'/' -f1 | tr -d '*' | tr ' ' '_')
```

而在 **Fullchain 合併模式 (`USE_FULLCHAIN=1`)** 下，腳本僅檢查伺服器憑證 (`CERT_PATH`) 的序號：
```bash
_l_server_serial=$(openssl x509 -in "$CERT_PATH" -noout -serial | cut -d'=' -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')
```

### 問題點
1. **只讀取第一張中繼憑證**：
   `openssl x509 -in "$_l_path"` 預設只會讀取檔案中的**第一張**憑證。若 `CA_CERT_PATH` 包含兩張以上的中繼憑證（例如 `Interm1` + `Interm2`），且只有**第二張以後的中繼憑證更換**，腳本抓到的序號依然是第一張，會誤判為已存在而跳過上傳。
2. **單一 CA 物件未啟用 Bundle 或逐層拆解**：
   標準模式下建立 CA `sslcertkey` 時未帶入 `"bundle": "yes"`，也未將多張中繼憑證拆分為獨立檔案並逐層建立 Link（`Server -> Interm1 -> Interm2`），導致 NetScaler 僅載入第一張中繼憑證。
3. **Fullchain 模式下單換中繼憑證不會觸發更新**：
   若伺服器憑證本身序號未變，僅中繼憑證更換，`USE_FULLCHAIN=1` 模式會因 `_l_server_serial` 相同而直接略過上傳。

---

## 議題 2：標準模式下 CA 憑證檢查與 Link 觸發情境

### 現況說明
腳本在步驟 `6B-3` 決定是否執行 `sslcertkey?action=link` 的判斷條件為：
```bash
if { [ "$_needs_link_cert" = "true" ] || [ "$_ca_added" = "true" ]; } && [ -n "$_target_ca_certname" ]; then
```

### 各情境行為對照表

| 情境 | CA 憑證狀態 (於 NetScaler) | Server 憑證狀態 (於 NetScaler) | `_ca_added` | `_needs_link_cert` | 是否會執行 Link？ | 行為與潛在問題說明 |
| :--- | :--- | :--- | :---: | :---: | :---: | :--- |
| **情境 1：首次部署新網域** | 已存在 (`serial` 吻合) | **首次新增 (Add)** | `false` | `true` | **會 Link** | ✅ 正常：自動抓出既有 CA 物件名稱 (`_target_ca_certname`)，將新 Server 憑證綁定上去。 |
| **情境 2：一般續期 (同一張 CA)** | 已存在 (`serial` 吻合) | **更新 (Update)** | `false` | `false` | **不執行 Link** | ✅ 正常：NetScaler 的 `action=update` 會保留 Server 憑證原有的 CA Link 關係，無需重綁。 |
| **情境 3：續期時換了全新 CA** | **不存在 (新上傳並建立)** | **更新 (Update)** | `true` | `false` | **會嘗試 Link** | ⚠️ **潛在錯誤**：若該 Server 憑證原本已經綁定舊的 CA，在未先執行 `action=unlink` 的情況下直接對已綁定的憑證呼叫 `action=link`，NetScaler API 會回傳已連結錯誤。 |
| **情境 4：續期時換成另一張「NS 上已存在」的 CA** | 已存在 (`serial` 吻合) | **更新 (Update)** | `false` | `false` | **不會 Link (漏綁)** | ⚠️ **漏綁問題**：例如從原本綁定的 `CA_A` 換成早已存在於 NetScaler 上的 `CA_B`（例如其他網域先觸發上傳了 `CA_B`）。因為 CA 已存在 (`_ca_added=false`) 且 Server 憑證走更新 (`_needs_link_cert=false`)，腳本會跳過 Link，導致憑證依然綁在舊的 `CA_A`。 |

---

## 建議修正方案 (Proposed Solutions)

1. **支援多張中繼憑證拆分與逐層比對**：
   - 使用 `awk` 將 `CA_CERT_PATH` 內的所有中繼憑證拆分為獨立暫存檔（`ca_1.pem`, `ca_2.pem` ...）。
   - 依序比對每一張中繼憑證的 `serial`，不存在於 NetScaler 時自動上傳並新增對應的 `sslcertkey`。
2. **動態檢查現有 Link 狀態並支援自動 `unlink` / `link`**：
   - 無論 `_ca_added` 或 `_needs_link_cert` 為何，在步驟 `6B-3` 皆透過 Nitro API（如查詢 `/nitro/v1/config/sslcertkey/${CERT_NAME}` 的 `linkcertkeyname`）確認憑證鏈每一層目前的綁定對象：
     - 若尚未綁定：直接執行 `sslcertkey?action=link`。
     - 若已綁定的 CA 與目標 `_target_ca_certname` 一致：跳過不處理。
     - 若已綁定的 CA 與目標 `_target_ca_certname` 不同：先執行 `sslcertkey?action=unlink` 解除舊綁定，再執行 `sslcertkey?action=link` 綁定至新 CA。
