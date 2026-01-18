#!/bin/bash
set -euo pipefail

# 判斷來源工具，RENEWED_LINEAGE是Certbot的變數
if [ -n "${RENEWED_LINEAGE-}" ]; then
    # Certbot
    CERT_KEY="$RENEWED_LINEAGE/privkey.pem"
    CERT_FILE="$RENEWED_LINEAGE/cert.pem"
    CA_FILE="$RENEWED_LINEAGE/chain.pem"
    CERT_FULLCHAIN="$RENEWED_LINEAGE/fullchain.pem"
elif [ -n "${CERT_KEY-}" ] && [ -n "${CERT_FULLCHAIN-}" ]; then
    # acme.sh
    CERT_KEY="${CERT_KEY}"
    CERT_FILE="${CERT_FILE}"
    CA_FILE="${CA_FILE}"
    CERT_FULLCHAIN="${CERT_FULLCHAIN}"
else
    echo "Error: Unknown environment, cannot detect ACME client."
    exit 1
fi

# 設置 NetScaler 連線資訊
export NS_IP="192.168.2.13"
export NS_USER="nsroot"
export NS_PASS="P@ssw0rd"

# 載入函數庫
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/deploy/netscaler.sh"

# 執行部署
netscaler_deploy


