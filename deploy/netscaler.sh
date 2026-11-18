#!/bin/bash

# ==============================================================================
# NetScaler Nitro API Deploy Hook
# ==============================================================================

# Custom settings (read from .Conf if environment variables are not provided)
if type _getdeployconf >/dev/null 2>&1; then
  _getdeployconf NS_IP
  _getdeployconf NS_USER
  _getdeployconf NS_PASS
  _getdeployconf USE_FULLCHAIN
  _getdeployconf NS_API_LOG
  _getdeployconf NS_DEL_OLD_CERTKEY
  _getdeployconf NS_INSTALL_NEW_CERT
fi

# If NetScaler connection variables are missing, attempt to load them from .env file
if [ -z "${NS_IP:-}" ] || [ -z "${NS_USER:-}" ] || [ -z "${NS_PASS:-}" ]; then
  _SCRIPT_DIR=""
  if [ -n "${BASH_SOURCE[0]-}" ]; then
    _SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi

  if [ -n "$_SCRIPT_DIR" ] && [ -f "$_SCRIPT_DIR/../.env" ]; then
    # shellcheck disable=SC1090
    . "$_SCRIPT_DIR/../.env"
  elif [ -n "$_SCRIPT_DIR" ] && [ -f "$_SCRIPT_DIR/.env" ]; then
    # shellcheck disable=SC1090
    . "$_SCRIPT_DIR/.env"
  elif [ -f "./.env" ]; then
    # shellcheck disable=SC1090
    . "./.env"
  fi
fi

# Custom settings (no default fallback values in code)
NS_IP="${NS_IP:-}"
NS_USER="${NS_USER:-}"
NS_PASS="${NS_PASS:-}"
CERT_FULLCHAIN_PATH="${CERT_FULLCHAIN_PATH:-}"
USE_FULLCHAIN="${USE_FULLCHAIN:-0}"   # Default: do not use FULLCHAIN
NS_API_LOG="${NS_API_LOG:-0}"   # Default: do not record API Log
NS_DEL_OLD_CERTKEY="${NS_DEL_OLD_CERTKEY:-0}"   # Default: do not delete old certificate files
NS_INSTALL_NEW_CERT="${NS_INSTALL_NEW_CERT:-0}"   # Default: 0 (Update mode), 1 (Install new certkey & switch VServer bindings)

# Certificate file encryption password
CERT_KEY_PASS="${CERT_KEY_PASS:-}"

# Set Log file path to current directory as required
NS_API_LOG_PATH="./ns_api.log"

# Color codes
_NS_RED='\033[1;31m'
_NS_ORANGE='\033[1;33m'
_NS_NC='\033[0m'

# Message output functions
_ns_info() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
_ns_warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_NS_ORANGE}Warning:${_NS_NC} $1"; }
_ns_error() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${_NS_RED}Error:${_NS_NC} $1"; exit 1; }

# API log recording function
_log_api_payload() {
  if [ "$NS_API_LOG" != "1" ]; then
    return
  fi
  local _endpoint=$1
  local _payload=$2
  local _response=$3
  {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] >>> API ENDPOINT: $_endpoint"
    echo "PAYLOAD: $_payload"
    echo "RESPONSE: ${_response:-<EMPTY_RESPONSE>}"
    echo "--------------------------------------------------------------------------------"
    echo "--------------------------------------------------------------------------------"
  } >> "$NS_API_LOG_PATH"
}

netscaler_deploy() {
  # --- Step 1: Initialization and environment variable check ---
  if [ -z "$CERT_PATH" ] || [ -z "$CERT_KEY_PATH" ] || [ -z "$CA_CERT_PATH" ]; then
    _ns_info "Required acme.sh path variables are missing, skipping deployment."
    _ns_info "Values: CERT_PATH='$CERT_PATH', CERT_KEY_PATH='$CERT_KEY_PATH', CA_CERT_PATH='$CA_CERT_PATH', CERT_FULLCHAIN_PATH='$CERT_FULLCHAIN_PATH'"
    return 0
  fi

  if [ -z "$NS_IP" ] || [ -z "$NS_USER" ] || [ -z "$NS_PASS" ]; then
    _ns_error "Required NetScaler connection variables (NS_IP, NS_USER, NS_PASS) are missing. Please set them in your environment or .env file."
  fi

  _ns_info "acme.sh provided certificate path: CERT_PATH='$CERT_PATH'"
  _ns_info "acme.sh provided certificate path: CERT_KEY_PATH='$CERT_KEY_PATH'"
  _ns_info "acme.sh provided certificate path: CA_CERT_PATH='$CA_CERT_PATH'"
  _ns_info "acme.sh provided certificate path: CERT_FULLCHAIN_PATH='$CERT_FULLCHAIN_PATH'"

  # --- Step 2: Determine certificate object name (CERT_NAME) ---
  if [ -z "$CERT_NAME" ]; then
    # Use OpenSSL syntax to extract subject name
    CERT_NAME=$(openssl x509 -in "$CERT_PATH" -noout -subject | sed -n 's/.*CN *= *//p' | cut -d'/' -f1 | cut -d',' -f1 | sed 's/\*\.//g' | tr -d '*' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _ns_info "Automatically extracted Common Name (CERT_NAME) from server certificate: $CERT_NAME"
  fi

  [ -z "$CERT_NAME" ] && _ns_error "Unable to get server certificate Common Name, please ensure $CERT_PATH is valid."

  _ns_info "Starting NetScaler deployment process ($CERT_NAME)..."

  _date_suffix=$(date +%Y%m%d)
  _tmp_dir="/tmp/acme_ns_$(date +%s)"
  mkdir -p "$_tmp_dir"

  # --- Function: Common API response check ---
  _check_api_response() {
    local _res=$1
    local _action_name=$2
    if [ -z "$_res" ]; then
      _ns_warn "$_action_name API returned empty response, possible timeout, attempting to continue..."
      return 0   # Empty response might indicate success
    # Compatible with spaces after colon in JSON (e.g., "errorcode": 0), and check if the last 3 characters are 200 or 201
    elif echo "$_res" | grep -q '"errorcode": *0' || [[ "${_res: -3}" == "200" ]] || [[ "${_res: -3}" == "201" ]]; then
	    return 0   # "errorcode": 0 or HTTP status code 200 or 201 indicates success
    else
      return 1
    fi
  }

  # --- Function: Nitro API Login ---
  _login_ns() {
    _ns_info "Logging into NetScaler to obtain Session..."
    _login_payload="{ \"login\": { \"username\": \"${NS_USER}\", \"password\": \"${NS_PASS}\" } }"
    _res=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
      -d "$_login_payload" \
      "https://${NS_IP}/nitro/v1/config/login")
    
    # Execute Log recording
    _log_api_payload "login" "LOGIN_ATTEMPT" "$_res"

    # Use _check_api_response to determine success or failure
    if _check_api_response "$_res" "Login"; then
      # Optimize regex to extract Token handling spaces shown in Log
      _session_token=$(echo "$_res" | grep -oP '"sessionid":\s*"\K[^"]+')
      
      if [ -z "$_session_token" ]; then
        _ns_error "Logged in successfully but unable to parse Session ID. Response: $_res"
      fi
      _ns_info "Login successful, Session ID obtained."
    else
      _ns_error "Login failed. Response: $_res"
    fi
  }

  # --- Function: Nitro API Logout ---
  _logout_ns() {
    _ns_info "Logging out from NetScaler Session..."
    _logout_payload="{ \"logout\": {} }"
    _res=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
      -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
      -d "$_logout_payload" \
      "https://${NS_IP}/nitro/v1/config/logout")
    
    _log_api_payload "logout" "$_logout_payload" "$_res"
    _ns_info "Logout completed."
  }

  # --- Function: Check NetScaler version and set API parameters ---
  _check_ns_version_and_set_param() {
    _ns_info "Checking NetScaler firmware version..."
    local _res
    _res=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X GET \
      -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
      "https://${NS_IP}/nitro/v1/config/nsversion")
    
    _log_api_payload "nsversion" "GET_VERSION" "$_res"

    if ! _check_api_response "$_res" "Get nsversion"; then
      _ns_warn "Could not retrieve NetScaler version. Assuming older version."
      return
    fi

    local version_string
    version_string=$(echo "$_res" | grep -oP '"version":\s*"\K[^"]+') # e.g., NS14.1: Build 43.22.nc

    if [ -z "$version_string" ]; then
      _ns_warn "Could not parse version string from API response. Assuming older version."
      return
    fi

    local major_version build_number
    major_version=$(echo "$version_string" | grep -o '[0-9][0-9]*\.[0-9][0-9]*' | head -n 1)
    build_number=$(echo "$version_string" | sed -n 's/.*Build \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')

    _ns_info "Detected NetScaler version: ${major_version:-N/A} Build: ${build_number:-N/A}"

    if [ -n "$major_version" ] && [ -n "$build_number" ]; then
      # Split versions for robust integer comparison
      local ver_major=${major_version%.*}
      local ver_minor=${major_version#*.}
      local build_major=${build_number%.*}

      # Check if version is 14.1 or greater, and build is > 43
      local is_supported=false
      if (( ver_major > 14 )); then
        is_supported=true
      elif (( ver_major == 14 && ver_minor >= 1 )); then
        if (( build_major > 43 )); then
          is_supported=true
        fi
      fi

      if [ "$is_supported" = true ]; then
        _ns_info "Version supports 'deleteCertKeyFilesOnRemoval' parameter. Flag will be added."
        _delete_certfile_param=',"deleteCertKeyFilesOnRemoval":"IF_EXPIRED"'
      else
        _ns_info "Version does not support 'deleteCertKeyFilesOnRemoval' parameter."
      fi
    else
      _ns_warn "Could not extract version/build numbers. Assuming older version."
    fi
  }

  # --- Step 3: Login to NetScaler and obtain Session Token ---
  _login_ns

  # --- Step 4: Detect NetScaler firmware version ---
  _delete_certfile_param=""
  _check_ns_version_and_set_param

  # Status recording variables
  _config_changed=false
  _server_cert_changed=false
  _ca_certnames=()
  _target_server_certkey="$CERT_NAME"

  # --- Function: API file upload ---
  _upload_to_ns() {
    local _local_f=$1; local _remote_f=$2
    [ ! -f "$_local_f" ] && _ns_error "Local source file not found: $_local_f"
    
    _b64_content=$(openssl base64 -A -in "$_local_f")
    _payload_file="$_tmp_dir/upload_payload.json"
    
    cat <<EOF > "$_payload_file"
{
  "systemfile": {
    "filename": "$_remote_f",
    "filecontent": "$_b64_content",
    "filelocation": "/flash/nsconfig/ssl/"
  }
}
EOF
    _res=$(curl -s -k --connect-timeout 10 -m 30 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
      -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
      -d "@$_payload_file" \
      "https://${NS_IP}/nitro/v1/config/systemfile")
    
    _log_api_payload "systemfile ($_remote_f)" "UPLOAD_FILE" "$_res"
    _check_api_response "$_res" "File upload ($_remote_f)" || _ns_error "File $_remote_f upload failed: $_res"

    sleep 1
    _ns_info "File $_remote_f upload completed."
  }

  # --- Function: Delete NetScaler file ---
  _delete_ns_file() {
    local _fname=$1
    [ -z "$_fname" ] && return
    _ns_warn "Deleting old file: $_fname"
    local _del_res
    _del_res=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X DELETE \
      -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
      "https://${NS_IP}/nitro/v1/config/systemfile?args=filename:${_fname},filelocation:%2Fflash%2Fnsconfig%2Fssl%2F")
    _log_api_payload "systemfile (DELETE $_fname)" "DELETE" "$_del_res"
  }

  # --- Function: Process Server Certificate (Add/Update) ---
  # $1: local_cert_path
  # $2: remote_cert_filename
  # $3: is_bundle ("true" or "false")
  _process_server_cert() {
    local _local_cert_path=$1
    local _remote_cert_filename=$2
    local _is_bundle=$3
    local _bundle_param=""
    local _old_cert_filename=""
    local _old_key_filename=""

    if [ "$_is_bundle" = "true" ]; then
      _ns_info "Processing Server certificate bundle ($CERT_NAME)"
    else
      _ns_info "Processing Server certificate ($CERT_NAME)"
    fi

    _l_server_serial=$(openssl x509 -in "$_local_cert_path" -noout -serial | cut -d'=' -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')
    _r_key_file="${CERT_NAME}_${_date_suffix}_${_l_server_serial: -3}.key"

    if echo "$_ns_all_certs" | grep -qi "\"serial\": *\"${_l_server_serial}\""; then
      _ns_info "Server certificate serial matches, skipping upload."
    else
      _upload_to_ns "$_local_cert_path" "$_remote_cert_filename"
      _upload_to_ns "$CERT_KEY_PATH" "$_r_key_file"

      local _method="POST"
      local _action=""

      if [ "$NS_INSTALL_NEW_CERT" = "1" ]; then
        _target_server_certkey="${CERT_NAME}_${_date_suffix}"
        local _check_new_code
        _check_new_code=$(curl -s -k --connect-timeout 10 -o /dev/null -w "%{http_code}" \
          -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
          "https://${NS_IP}/nitro/v1/config/sslcertkey/${_target_server_certkey}")
        if [ "$_check_new_code" == "200" ]; then
          _target_server_certkey="${CERT_NAME}_${_date_suffix}_${_l_server_serial: -3}"
          _ns_info "Install certkey name conflict, renamed to [$_target_server_certkey]"
        fi
        if [ "$_is_bundle" = "true" ]; then
          _bundle_param=',"bundle":"yes"'
          _ns_info "Executing Install new Server certificate bundle [$_target_server_certkey] (POST)..."
        else
          _ns_info "Executing Install new Server certificate [$_target_server_certkey] (POST)..."
        fi
      else
        _target_server_certkey="$CERT_NAME"
        _check_server_code=$(curl -s -k --connect-timeout 10 -o /dev/null -w "%{http_code}" \
          -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
          "https://${NS_IP}/nitro/v1/config/sslcertkey/${_target_server_certkey}")

        if [ "$_check_server_code" == "200" ]; then
          # If deletion of old files is enabled, fetch current certificate info
          if [ "$NS_DEL_OLD_CERTKEY" = "1" ]; then
            _ns_info "NS_DEL_OLD_CERTKEY is enabled. Fetching current cert files for potential deletion."
            local _current_cert_details
            _current_cert_details=$(curl -s -k --connect-timeout 10 -X GET \
                -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
                "https://${NS_IP}/nitro/v1/config/sslcertkey/${_target_server_certkey}")
            _old_cert_filename=$(echo "$_current_cert_details" | grep -oP '"cert":\s*"\K[^"]+')
            _old_key_filename=$(echo "$_current_cert_details" | grep -oP '"key":\s*"\K[^"]+')
          fi
          
          if [ "$_is_bundle" = "true" ]; then
            _ns_info "Executing Update Server certificate bundle (POST with action=update)..."
          else
            _ns_info "Executing Update Server certificate (POST with action=update)..."
          fi
          _action="?action=update"
        else
          if [ "$_is_bundle" = "true" ]; then
            _bundle_param=',"bundle":"yes"'
            _ns_info "Executing Add Server certificate bundle (POST)..."
          else
            _ns_info "Executing Add Server certificate (POST)..."
          fi
          _action=""
        fi
      fi

      local _certkey_pass_param=""
      if grep -q "ENCRYPTED" "$CERT_KEY_PATH"; then
        _ns_info "Private key is encrypted. Checking for CERT_KEY_PASS..."
        if [ -z "$CERT_KEY_PASS" ]; then
          _ns_error "Private key is password-protected, but CERT_KEY_PASS environment variable is not set."
        fi
        _certkey_pass_param=",\"passplain\":\"${CERT_KEY_PASS}\""
      fi

      local _payload_server="{ \"sslcertkey\": { \"certkey\": \"${_target_server_certkey}\", \"cert\": \"$_remote_cert_filename\", \"key\": \"$_r_key_file\"${_bundle_param}${_certkey_pass_param}$_delete_certfile_param } }"

      local _res_server
      _res_server=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X "$_method" -H "Content-Type: application/json" \
        -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
        -d "$_payload_server" \
        "https://${NS_IP}/nitro/v1/config/sslcertkey${_action}")
      
      if [ "$_is_bundle" = "true" ]; then
        _log_api_payload "$_method Server bundle ($_target_server_certkey $_action)" "$_payload_server" "$_res_server"
        if _check_api_response "$_res_server" "Server certificate bundle operation"; then
          _config_changed=true
          _server_cert_changed=true
          # If deletion is enabled (only in Update mode) and old file differs from new file, execute deletion
          if [ "$NS_INSTALL_NEW_CERT" != "1" ] && [ "$NS_DEL_OLD_CERTKEY" = "1" ]; then
            if [ -n "$_old_cert_filename" ] && [ "$_old_cert_filename" != "$_remote_cert_filename" ]; then
               _delete_ns_file "$_old_cert_filename"
            fi
            if [ -n "$_old_key_filename" ] && [ "$_old_key_filename" != "$_r_key_file" ]; then
               _delete_ns_file "$_old_key_filename"
            fi
          fi
        else
          _ns_error "Server certificate bundle operation failed: $_res_server"
        fi
      else
        _log_api_payload "$_method Server ($_target_server_certkey $_action)" "$_payload_server" "$_res_server"
        if _check_api_response "$_res_server" "Server certificate operation"; then
          _config_changed=true
          _server_cert_changed=true
          # If deletion is enabled (only in Update mode) and old file differs from new file, execute deletion
          if [ "$NS_INSTALL_NEW_CERT" != "1" ] && [ "$NS_DEL_OLD_CERTKEY" = "1" ]; then
            if [ -n "$_old_cert_filename" ] && [ "$_old_cert_filename" != "$_remote_cert_filename" ]; then
               _delete_ns_file "$_old_cert_filename"
            fi
            if [ -n "$_old_key_filename" ] && [ "$_old_key_filename" != "$_r_key_file" ]; then
               _delete_ns_file "$_old_key_filename"
            fi
          fi
        else
          _ns_error "Server certificate operation failed: $_res_server"
        fi
      fi
    fi
  }

  # --- Function: Query current linkcertkeyname of a certificate ---
  _get_linked_ca() {
    local _certkey=$1
    local _res
    _res=$(curl -s -k --connect-timeout 10 -X GET \
      -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
      "https://${NS_IP}/nitro/v1/config/sslcertkey/${_certkey}")
    _log_api_payload "sslcertkey (GET $_certkey)" "GET" "$_res"
    echo "$_res" | grep -oP '"linkcertkeyname":\s*"\K[^"]+' | head -n 1
  }

  # --- Function: Ensure certificate is linked to expected parent CA (unlink if mismatched) ---
  _ensure_cert_link() {
    local _child=$1
    local _expected_parent=$2
    [ -z "$_child" ] || [ -z "$_expected_parent" ] && return 0

    if [ "$_child" = "$_expected_parent" ]; then
      return 0
    fi

    local _current_parent
    _current_parent=$(_get_linked_ca "$_child")

    if [ "$_current_parent" = "$_expected_parent" ]; then
      _ns_info "Certificate [$_child] is already linked to [$_expected_parent], skipping link."
      return 0
    fi

    if [ -n "$_current_parent" ]; then
      _ns_info "Certificate [$_child] is currently linked to [$_current_parent], unlinking before re-linking to [$_expected_parent]..."
      local _payload_unlink="{ \"sslcertkey\": { \"certkey\": \"${_child}\" } }"
      local _res_unlink
      _res_unlink=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
        -d "$_payload_unlink" \
        "https://${NS_IP}/nitro/v1/config/sslcertkey?action=unlink")

      _log_api_payload "sslcertkey?action=unlink ($_child)" "$_payload_unlink" "$_res_unlink"
      if _check_api_response "$_res_unlink" "Certificate Unlink ($_child)"; then
        _config_changed=true
      else
        _ns_error "Unlink failed for $_child: $_res_unlink"
      fi
    fi

    _ns_info "Linking certificate ($_child -> $_expected_parent)..."
    local _payload_link="{ \"sslcertkey\": { \"certkey\": \"${_child}\", \"linkcertkeyname\": \"$_expected_parent\" } }"
    local _res_link
    _res_link=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
      -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
      -d "$_payload_link" \
      "https://${NS_IP}/nitro/v1/config/sslcertkey?action=link")

    _log_api_payload "sslcertkey?action=link ($_child -> $_expected_parent)" "$_payload_link" "$_res_link"
    if _check_api_response "$_res_link" "Certificate Link ($_child -> $_expected_parent)"; then
      _config_changed=true
    else
      _ns_warn "Link failed ($_child -> $_expected_parent): $_res_link"
    fi
  }

  # --- Function: Find old certkeys with same Subject CN and switch VServer bindings ---
  _switch_vserver_bindings() {
    local _raw_server_cn
    _raw_server_cn=$(openssl x509 -in "$CERT_PATH" -noout -subject | sed -n 's/.*CN *= *//p' | cut -d'/' -f1 | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$_raw_server_cn" ]; then
      _ns_warn "Unable to extract Subject CN from $CERT_PATH, skipping VServer binding switch."
      return 0
    fi

    _ns_info "Searching for old server certificates with Subject CN [$_raw_server_cn] to migrate VServer bindings to [$_target_server_certkey]..."

    local _cert_obj _obj_certkey _obj_subject _obj_cn
    while IFS= read -r _cert_obj; do
      [ -z "$_cert_obj" ] && continue
      echo "$_cert_obj" | grep -q '"SRVR_CERT"' || continue

      _obj_certkey=$(echo "$_cert_obj" | sed -n 's/.*"certkey": *"\([^"]*\)".*/\1/p' | head -n 1)
      [ -z "$_obj_certkey" ] && continue
      [ "$_obj_certkey" = "$_target_server_certkey" ] && continue

      _obj_subject=$(echo "$_cert_obj" | sed -n 's/.*"subject": *"\([^"]*\)".*/\1/p' | head -n 1)
      _obj_cn=$(echo "$_obj_subject" | sed -n 's/.*CN *= *//p' | cut -d'/' -f1 | cut -d',' -f1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      [ "$_obj_cn" = "$_raw_server_cn" ] || continue

      _ns_info "Found matching old server certificate [$_obj_certkey] (CN: $_obj_cn). Checking VServer bindings..."

      local _res_bindings
      _res_bindings=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X GET \
        -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
        "https://${NS_IP}/nitro/v1/config/sslcertkey_sslvserver_binding/${_obj_certkey}")
      _log_api_payload "sslcertkey_sslvserver_binding (GET $_obj_certkey)" "GET" "$_res_bindings"

      local _vservers
      _vservers=$(echo "$_res_bindings" | sed -E 's/\},[[:space:]]*\{/}\n{/g' | sed -n 's/.*"servername": *"\([^"]*\)".*/\1/p')
      if [ -z "$_vservers" ]; then
        _ns_info "No VServer bindings found on old certificate [$_obj_certkey]."
        continue
      fi

      local _vserver
      while IFS= read -r _vserver; do
        [ -z "$_vserver" ] && continue

        # Query VServer bindings to detect whether -SNICert is enabled for this certkey
        local _res_vs_bindings _is_sni
        _res_vs_bindings=$(curl -s -k --connect-timeout 10 -X GET \
          -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
          "https://${NS_IP}/nitro/v1/config/sslvserver_sslcertkey_binding/${_vserver}")
        _log_api_payload "sslvserver_sslcertkey_binding (GET $_vserver)" "GET" "$_res_vs_bindings"

        _is_sni=false
        if echo "$_res_vs_bindings" | sed -E 's/\},[[:space:]]*\{/}\n{/g' | grep -F "\"certkeyname\": \"$_obj_certkey\"" | grep -qi '"snicert": *true'; then
          _is_sni=true
        fi

        local _unbind_args="certkeyname:${_obj_certkey}"
        local _sni_json_param=""
        if [ "$_is_sni" = "true" ]; then
          _unbind_args="certkeyname:${_obj_certkey},snicert:true"
          _sni_json_param=',"snicert":true'
        fi

        _ns_info "Unbinding old certificate [$_obj_certkey] from VServer [$_vserver] (SNI: $_is_sni)..."
        local _res_unbind
        _res_unbind=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X DELETE \
          -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
          "https://${NS_IP}/nitro/v1/config/sslvserver_sslcertkey_binding/${_vserver}?args=${_unbind_args}")
        _log_api_payload "sslvserver_sslcertkey_binding (UNBIND $_vserver / $_obj_certkey)" "DELETE" "$_res_unbind"
        if ! _check_api_response "$_res_unbind" "Unbind $_obj_certkey from $_vserver"; then
          _ns_error "Failed to unbind [$_obj_certkey] from VServer [$_vserver]: $_res_unbind"
        fi

        _ns_info "Binding new certificate [$_target_server_certkey] to VServer [$_vserver] (SNI: $_is_sni)..."
        local _payload_bind="{ \"sslvserver_sslcertkey_binding\": { \"vservername\": \"${_vserver}\", \"certkeyname\": \"${_target_server_certkey}\"${_sni_json_param} } }"
        local _res_bind
        _res_bind=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
          -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
          -d "$_payload_bind" \
          "https://${NS_IP}/nitro/v1/config/sslvserver_sslcertkey_binding")
        _log_api_payload "sslvserver_sslcertkey_binding (BIND $_vserver / $_target_server_certkey)" "$_payload_bind" "$_res_bind"
        if _check_api_response "$_res_bind" "Bind $_target_server_certkey to $_vserver"; then
          _config_changed=true
        else
          _ns_error "Failed to bind [$_target_server_certkey] to VServer [$_vserver]: $_res_bind"
        fi
      done <<< "$_vservers"
    done <<< "$(echo "$_ns_all_certs" | sed -E 's/\},[[:space:]]*\{/}\n{/g')"
  }

  # --- Step 5: Get existing NetScaler certificate list ---
  _ns_all_certs=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X GET \
    -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
    "https://${NS_IP}/nitro/v1/config/sslcertkey")
  
  if [ -z "$_ns_all_certs" ]; then
    _ns_error "Unable to connect to NetScaler or retrieve certificate list."
  fi

  # --- Step 6: Choose deployment path (Fullchain or Standard) ---
  _srv_serial=$(openssl x509 -in "$CERT_PATH" -noout -serial | cut -d'=' -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')
  if [ "$USE_FULLCHAIN" = "1" ] && [ -n "$CERT_FULLCHAIN_PATH" ] && [ -f "$CERT_FULLCHAIN_PATH" ]; then
    # --- Path A: Fullchain (Bundle) deployment ---
    _ns_info "Using bundle deployment method."

    # --- Step 6A-1: Process server certificate bundle ---
    _r_cert_file="${CERT_NAME}_fullchain_${_date_suffix}_${_srv_serial: -3}.cer"
    _process_server_cert "$CERT_FULLCHAIN_PATH" "$_r_cert_file" "true"
    # CA and Link steps are skipped in this flow.

  else
    # --- Path B: Standard (Separate) deployment ---
    _ns_info "Using standard separate cert/ca deployment method."
    
    # --- Step 6B-1: Process CA intermediate certificates (split & check each) ---
    _ca_split_dir="$_tmp_dir/ca_split"
    mkdir -p "$_ca_split_dir"
    awk -v outdir="$_ca_split_dir" '
      /-----BEGIN CERTIFICATE-----/ { in_cert=1; idx++; fname=sprintf("%s/ca_%03d.pem", outdir, idx) }
      in_cert { print > fname }
      /-----END CERTIFICATE-----/ { close(fname); in_cert=0 }
    ' "$CA_CERT_PATH"

    for _l_path in "$_ca_split_dir"/ca_*.pem; do
      [ -f "$_l_path" ] || continue
      _l_serial=$(openssl x509 -in "$_l_path" -noout -serial | cut -d'=' -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')
      _ca_cn=$(openssl x509 -in "$_l_path" -noout -subject | sed -n 's/.*CN *= *//p' | cut -d'/' -f1 | tr -d '*' | tr ' ' '_')
      _base_ca_name="CA_${_ca_cn}"
      _r_ca_file="${_base_ca_name}_${_date_suffix}_${_l_serial: -3}.cer"
      _resolved_ca_certname=""

      # Use more precise grep syntax to find serial, and handle JSON arrays (with optional spaces between objects)
      if echo "$_ns_all_certs" | grep -qi "\"serial\": *\"${_l_serial}\""; then
        _ns_info "CA [$_base_ca_name] (serial: $_l_serial) matches, skipping upload."
        # Extract certkey name from JSON object containing serial, ensuring only the first result is taken
        _resolved_ca_certname=$(echo "$_ns_all_certs" | sed -E 's/\},[[:space:]]*\{/}\n{/g' | grep -i "\"serial\": *\"${_l_serial}\"" | sed -n 's/.*"certkey": *"\([^"]*\)".*/\1/p' | head -n 1)
        _ns_info "Found existing CA object name: [$_resolved_ca_certname]"
      else
        # CA does not exist, so we need to upload and create it
        _upload_to_ns "$_l_path" "$_r_ca_file"

        _ca_keyname="$_base_ca_name"
        # Check for name conflict
        _check_name_code=$(curl -s -k --connect-timeout 10 -o /dev/null -w "%{http_code}" \
          -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
          "https://${NS_IP}/nitro/v1/config/sslcertkey/${_ca_keyname}")

        if [ "$_check_name_code" == "200" ]; then
          _ca_keyname="${_base_ca_name}_${_date_suffix}"
          _check_name_code2=$(curl -s -k --connect-timeout 10 -o /dev/null -w "%{http_code}" \
            -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
            "https://${NS_IP}/nitro/v1/config/sslcertkey/${_ca_keyname}")
          if [ "$_check_name_code2" == "200" ]; then
            _ca_keyname="${_base_ca_name}_${_date_suffix}_${_l_serial: -3}"
          fi
          _ns_info "CA object name conflict, renamed to [$_ca_keyname]"
        fi

        _payload_ca="{ \"sslcertkey\": { \"certkey\": \"$_ca_keyname\", \"cert\": \"$_r_ca_file\"$_delete_certfile_param } }"
        _res_ca=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
          -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
          -d "$_payload_ca" \
          "https://${NS_IP}/nitro/v1/config/sslcertkey")

        _log_api_payload "Add CA ($_ca_keyname)" "$_payload_ca" "$_res_ca"

        if _check_api_response "$_res_ca" "Add CA ($_ca_keyname)"; then
          _config_changed=true
          _resolved_ca_certname="$_ca_keyname"
        else
          _ns_error "CA Add failed: $_res_ca"
        fi
      fi

      if [ -n "$_resolved_ca_certname" ]; then
        _ca_certnames+=("$_resolved_ca_certname")
      fi
    done

    if [ ${#_ca_certnames[@]} -eq 0 ]; then
      _ns_error "No valid intermediate CA certificates found in $CA_CERT_PATH."
    fi

    # --- Step 6B-2: Process server certificate ---
    _r_cert_file="${CERT_NAME}_${_date_suffix}_${_srv_serial: -3}.cer"
    _process_server_cert "$CERT_PATH" "$_r_cert_file" "false"

    # --- Step 6B-3: Verify and link certificate chain ---
    if [ "$NS_INSTALL_NEW_CERT" != "1" ] || [ "$_server_cert_changed" = "true" ]; then
      _ensure_cert_link "$_target_server_certkey" "${_ca_certnames[0]}"
    fi
    if [ ${#_ca_certnames[@]} -gt 1 ]; then
      _idx=0
      while [ $_idx -lt $(( ${#_ca_certnames[@]} - 1 )) ]; do
        _ensure_cert_link "${_ca_certnames[$_idx]}" "${_ca_certnames[$((_idx + 1))]}"
        _idx=$((_idx + 1))
      done
    fi
  fi

  # --- Step 6C: Switch VServer bindings when NS_INSTALL_NEW_CERT=1 and a new server cert was installed ---
  if [ "$NS_INSTALL_NEW_CERT" = "1" ] && [ "$_server_cert_changed" = "true" ]; then
    _switch_vserver_bindings
  fi

  # --- Step 7: Save NetScaler configuration ---
  if [ "$_config_changed" = "true" ]; then
    # Save deployment settings (if supported by acme.sh)
    if type _savedeployconf >/dev/null 2>&1; then
      _savedeployconf NS_IP "$NS_IP"
      _savedeployconf NS_USER "$NS_USER"
      _savedeployconf NS_PASS "$NS_PASS"
      _savedeployconf USE_FULLCHAIN "$USE_FULLCHAIN"
      _savedeployconf NS_API_LOG "$NS_API_LOG"
      _savedeployconf NS_DEL_OLD_CERTKEY "$NS_DEL_OLD_CERTKEY"
      _savedeployconf NS_INSTALL_NEW_CERT "$NS_INSTALL_NEW_CERT"
    fi
    _ns_info "Saving NetScaler configuration..."
    _payload_save='{"nsconfig":{}}'
    _res_save=$(curl -s -k --connect-timeout 10 -m 60 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
      -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
      -d "$_payload_save" \
      "https://${NS_IP}/nitro/v1/config/nsconfig?action=save")
    
    _log_api_payload "nsconfig (SAVE)" "$_payload_save" "$_res_save"
    _check_api_response "$_res_save" "Save configuration"
  else
    _ns_info "No configuration changes detected, skipping save action."
  fi

  # --- Step 8: Logout and cleanup ---
  _logout_ns

  rm -rf "$_tmp_dir"
  _ns_info "Deployment process completed."
}


# Define a function with the same name as the filename, format hook_name_deploy(), acme.sh will call it automatically
#netscaler_deploy
