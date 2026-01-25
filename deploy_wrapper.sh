#!/bin/bash
set -euo pipefail

# 解析命令行參數
MANUAL_CERT_FILE=""
MANUAL_KEY_FILE=""
MANUAL_CA_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --cert-file)
      MANUAL_CERT_FILE="$2"
      shift 2
      ;;
    --key-file)
      MANUAL_KEY_FILE="$2"
      shift 2
      ;;
    --ca-file)
      MANUAL_CA_FILE="$2"
      shift 2
      ;;
    *)
      # 未知參數，忽略
      shift
      ;;
  esac
done

# Logic Priority:
# 1. Certbot (RENEWED_LINEAGE)
# 2. acme.sh (CERT_KEY, CERT_FULLCHAIN)
# 3. Manual Fallback (Args or Interactive)

if [ -n "${RENEWED_LINEAGE-}" ]; then
    # 1. Certbot Environment
    echo "Detected Certbot environment."
    CERT_KEY="$RENEWED_LINEAGE/privkey.pem"
    CERT_FILE="$RENEWED_LINEAGE/cert.pem"
    CA_FILE="$RENEWED_LINEAGE/chain.pem"
    CERT_FULLCHAIN="$RENEWED_LINEAGE/fullchain.pem"

elif [ -n "${CERT_KEY-}" ] && [ -n "${CERT_FULLCHAIN-}" ]; then
    # 2. acme.sh Environment
    echo "Detected acme.sh environment."
    CERT_KEY="${CERT_KEY}"
    CERT_FILE="${CERT_FILE}"
    CA_FILE="${CA_FILE}"
    CERT_FULLCHAIN="${CERT_FULLCHAIN}"

else
    # 3. Manual Fallback
    echo "No ACME client environment detected. Checking manual arguments..."

    if [ -n "$MANUAL_CERT_FILE" ] && [ -n "$MANUAL_KEY_FILE" ] && [ -n "$MANUAL_CA_FILE" ]; then
        echo "Using manual paths provided via arguments."
        CERT_FILE="$MANUAL_CERT_FILE"
        CERT_KEY="$MANUAL_KEY_FILE"
        CA_FILE="$MANUAL_CA_FILE"
        CERT_FULLCHAIN="" 
    else
        # Interactive Mode
        echo "No manual arguments provided. Entering interactive mode."
        
        while [ -z "${CERT_FILE:-}" ]; do
            read -r -p "Please enter the path to the Certificate file (e.g., cert.pem): " CERT_FILE
        done
        
        while [ -z "${CERT_KEY:-}" ]; do
            read -r -p "Please enter the path to the Private Key file (e.g., key.pem): " CERT_KEY
        done

        while [ -z "${CA_FILE:-}" ]; do
            read -r -p "Please enter the path to the CA Chain file (e.g., chain.pem): " CA_FILE
        done

        CERT_FULLCHAIN=""
    fi
fi

# Export variables for netscaler.sh
export CERT_PATH="$CERT_FILE"
export CERT_KEY_PATH="$CERT_KEY"
export CA_CERT_PATH="$CA_FILE"
export CERT_FULLCHAIN_PATH="$CERT_FULLCHAIN"

# 設置 NetScaler 連線資訊
export NS_IP="192.168.2.13"
export NS_USER="nsroot"
export NS_PASS="P@ssw0rd"

# 載入函數庫
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/deploy/netscaler.sh"

# 執行部署
netscaler_deploy


