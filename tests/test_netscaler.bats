#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  TEST_WORKDIR="${BATS_TEST_TMPDIR}/work"
  MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${TEST_WORKDIR}" "${MOCK_BIN}"

  export PATH="${MOCK_BIN}:${PATH}"
  export MOCK_LOG_DIR="${BATS_TEST_TMPDIR}"

  # Create mock curl
  cat <<'EOF' > "${MOCK_BIN}/curl"
#!/bin/bash
url=""
method="GET"
data=""
output_file=""

args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
  arg="${args[$i]}"
  case "$arg" in
    -X)
      i=$((i + 1))
      method="${args[$i]}"
      ;;
    -d)
      i=$((i + 1))
      data="${args[$i]}"
      ;;
    -o)
      i=$((i + 1))
      output_file="${args[$i]}"
      ;;
    http://*|https://*)
      url="$arg"
      ;;
  esac
  i=$((i + 1))
done

case "$url" in
  */nitro/v1/config/login)
    printf '{"errorcode":0,"sessionid":"mock-token-123"}\n200'
    ;;
  */nitro/v1/config/nsversion)
    if [ -n "${MOCK_NSVERSION_RAW:-}" ]; then
      printf '%s\n200' "${MOCK_NSVERSION_RAW}"
    else
      printf '{"errorcode":0,"nsversion":{"version":"%s"}}\n200' "${MOCK_NS_VERSION:-NS14.1: Build 44.10.nc}"
    fi
    ;;
  */nitro/v1/config/sslcertkey)
    if [ "$method" = "GET" ]; then
      printf '{"errorcode":0,"sslcertkey":%s}\n200' "${MOCK_SSL_CERTS:-[]}"
    else
      echo "$data" >> "${MOCK_LOG_DIR}/sslcertkey_post.log"
      printf '{"errorcode":0}\n200'
    fi
    ;;
  */nitro/v1/config/sslcertkey/*)
    if [ "$output_file" = "/dev/null" ]; then
      printf '%s' "${MOCK_CERT_EXISTS_CODE:-404}"
    else
      printf '{"errorcode":0}\n200'
    fi
    ;;
  */nitro/v1/config/systemfile*)
    echo "$url" >> "${MOCK_LOG_DIR}/systemfile_calls.log"
    printf '{"errorcode":0}\n200'
    ;;
  */nitro/v1/config/nsconfig*)
    printf '{"errorcode":0}\n200'
    ;;
  */nitro/v1/config/logout)
    printf '{"errorcode":0}\n200'
    ;;
  *)
    printf '{"errorcode":0}\n200'
    ;;
esac
EOF
  chmod +x "${MOCK_BIN}/curl"

  # Generate test wildcard certificate & CA certificate
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TEST_WORKDIR}/server.key" \
    -out "${TEST_WORKDIR}/server.cer" \
    -days 1 -subj "/CN=*.example.com" -set_serial 0x1A2B3C 2>/dev/null

  cp "${TEST_WORKDIR}/server.cer" "${TEST_WORKDIR}/ca.cer"
  cat "${TEST_WORKDIR}/server.cer" "${TEST_WORKDIR}/ca.cer" > "${TEST_WORKDIR}/fullchain.cer"

  # Default environment variables for netscaler_deploy
  export NS_IP="127.0.0.1"
  export NS_USER="nsroot"
  export NS_PASS="nsroot"
  export CERT_PATH="${TEST_WORKDIR}/server.cer"
  export CERT_KEY_PATH="${TEST_WORKDIR}/server.key"
  export CA_CERT_PATH="${TEST_WORKDIR}/ca.cer"
  export CERT_FULLCHAIN_PATH="${TEST_WORKDIR}/fullchain.cer"
  export CERT_NAME=""
  export USE_FULLCHAIN="1"
  export NS_API_LOG="0"
  export NS_DEL_OLD_CERTKEY="0"
  export NS_INSTALL_NEW_CERT="0"

  cd "${TEST_WORKDIR}"
}

# ==============================================================================
# NetScaler Version Detection Tests
# ==============================================================================

@test "version: NS14.1 Build 44.10 enables deleteCertKeyFilesOnRemoval" {
  export MOCK_NS_VERSION="NS14.1: Build 44.10.nc"
  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected NetScaler version: 14.1 Build: 44.10"* ]]
  [[ "$output" == *"Version supports 'deleteCertKeyFilesOnRemoval' parameter. Flag will be added."* ]]
  grep -q '"deleteCertKeyFilesOnRemoval":"IF_EXPIRED"' "${MOCK_LOG_DIR}/sslcertkey_post.log"
}

@test "version: NS14.1 Build 43.22 does not enable deleteCertKeyFilesOnRemoval" {
  export MOCK_NS_VERSION="NS14.1: Build 43.22.nc"
  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected NetScaler version: 14.1 Build: 43.22"* ]]
  [[ "$output" == *"Version does not support 'deleteCertKeyFilesOnRemoval' parameter."* ]]
  ! grep -q 'deleteCertKeyFilesOnRemoval' "${MOCK_LOG_DIR}/sslcertkey_post.log"
}

@test "version: NS13.1 Build 50.1 does not enable deleteCertKeyFilesOnRemoval" {
  export MOCK_NS_VERSION="NS13.1: Build 50.1.nc"
  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected NetScaler version: 13.1 Build: 50.1"* ]]
  [[ "$output" == *"Version does not support 'deleteCertKeyFilesOnRemoval' parameter."* ]]
  ! grep -q 'deleteCertKeyFilesOnRemoval' "${MOCK_LOG_DIR}/sslcertkey_post.log"
}

@test "version: NS15.0 Build 1.0 enables deleteCertKeyFilesOnRemoval" {
  export MOCK_NS_VERSION="NS15.0: Build 1.0.nc"
  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Detected NetScaler version: 15.0 Build: 1.0"* ]]
  [[ "$output" == *"Version supports 'deleteCertKeyFilesOnRemoval' parameter. Flag will be added."* ]]
  grep -q '"deleteCertKeyFilesOnRemoval":"IF_EXPIRED"' "${MOCK_LOG_DIR}/sslcertkey_post.log"
}

@test "version: malformed nsversion response falls back safely" {
  export MOCK_NSVERSION_RAW='{"errorcode":0,"nsversion":{"version":"UNKNOWN_FORMAT"}}'
  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not extract version/build numbers. Assuming older version."* ]]
  ! grep -q 'deleteCertKeyFilesOnRemoval' "${MOCK_LOG_DIR}/sslcertkey_post.log"
}

# ==============================================================================
# Certificate Parsing Tests
# ==============================================================================

@test "cert: extracts CERT_NAME from wildcard certificate CN (*.example.com -> example.com)" {
  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Automatically extracted Common Name (CERT_NAME) from server certificate: example.com"* ]]
  grep -q '"certkey": "example.com"' "${MOCK_LOG_DIR}/sslcertkey_post.log"
}

@test "cert: extracts CERT_NAME from standard certificate CN (app.example.com)" {
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "${TEST_WORKDIR}/std.key" \
    -out "${TEST_WORKDIR}/std.cer" \
    -days 1 -subj "/CN=app.example.com" -set_serial 0x4D5E6F 2>/dev/null

  export CERT_PATH="${TEST_WORKDIR}/std.cer"
  export CERT_KEY_PATH="${TEST_WORKDIR}/std.key"
  export CERT_FULLCHAIN_PATH="${TEST_WORKDIR}/std.cer"

  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Automatically extracted Common Name (CERT_NAME) from server certificate: app.example.com"* ]]
  grep -q '"certkey": "app.example.com"' "${MOCK_LOG_DIR}/sslcertkey_post.log"
}

@test "cert: extracts serial number and skips upload when matching serial exists on NetScaler" {
  export MOCK_SSL_CERTS='[{"certkey":"example.com","serial":"1A2B3C"}]'
  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 0 ]
  [[ "$output" == *"Server certificate serial matches, skipping upload."* ]]
  [ ! -f "${MOCK_LOG_DIR}/sslcertkey_post.log" ]
}

@test "cert: uses last 3 hex digits of serial in uploaded cert and key filenames" {
  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 0 ]
  grep -q '_B3C\.cer"' "${MOCK_LOG_DIR}/sslcertkey_post.log"
  grep -q '_B3C\.key"' "${MOCK_LOG_DIR}/sslcertkey_post.log"
}

@test "cert: fails cleanly when certificate file has no valid CN" {
  echo "invalid cert" > "${TEST_WORKDIR}/bad.cer"
  export CERT_PATH="${TEST_WORKDIR}/bad.cer"

  # shellcheck source=deploy/netscaler.sh
  source "${REPO_ROOT}/deploy/netscaler.sh"

  run netscaler_deploy
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unable to get server certificate Common Name"* ]]
}
