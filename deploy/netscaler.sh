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
fi

# Custom settings (use default values if environment variables are not provided)
NS_IP="${NS_IP:-192.168.100.1}"
NS_USER="${NS_USER:-nsroot}"
NS_PASS="${NS_PASS:-nsroot}"
CERT_FULLCHAIN_PATH="${CERT_FULLCHAIN_PATH:-}"
USE_FULLCHAIN="${USE_FULLCHAIN:-0}"   # Default: do not use FULLCHAIN
NS_API_LOG="${NS_API_LOG:-0}"   # Default: do not record API Log
NS_DEL_OLD_CERTKEY="${NS_DEL_OLD_CERTKEY:-0}"   # Default: do not delete old certificate files

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
  _ns_info "acme.sh provided certificate path: CERT_PATH='$CERT_PATH'"
  _ns_info "acme.sh provided certificate path: CERT_KEY_PATH='$CERT_KEY_PATH'"
  _ns_info "acme.sh provided certificate path: CA_CERT_PATH='$CA_CERT_PATH'"
  _ns_info "acme.sh provided certificate path: CERT_FULLCHAIN_PATH='$CERT_FULLCHAIN_PATH'"

  # --- Step 2: Determine certificate object name (CERT_NAME) ---
  if [ -z "$CERT_NAME" ]; then
    # Use OpenSSL syntax to extract subject name
    CERT_NAME=$(openssl x509 -in "$CERT_PATH" -noout -subject | sed -n 's/.*CN = //p' | cut -d'/' -f1 | tr -d '*')
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
  _needs_link_cert=false
  _ca_added=false
  _config_changed=false
  _target_ca_certname=""

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
    local _del_res=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X DELETE \
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
      _bundle_param=',"bundle":"yes"'
      _ns_info "Processing Server certificate bundle ($CERT_NAME)"
    else
      _ns_info "Processing Server certificate ($CERT_NAME)"
    fi

    _l_server_serial=$(openssl x509 -in "$CERT_PATH" -noout -serial | cut -d'=' -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')
    _r_key_file="${CERT_NAME}_${_date_suffix}.key"

    if echo "$_ns_all_certs" | grep -qi "$_l_server_serial"; then
      _ns_info "Server certificate serial matches, skipping upload."
    else
      _upload_to_ns "$_local_cert_path" "$_remote_cert_filename"
      _upload_to_ns "$CERT_KEY_PATH" "$_r_key_file"

      _check_server_code=$(curl -s -k --connect-timeout 10 -o /dev/null -w "%{http_code}" \
        -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
        "https://${NS_IP}/nitro/v1/config/sslcertkey/${CERT_NAME}")

      local _method="POST"
      local _action=""
      if [ "$_check_server_code" == "200" ]; then
        # If deletion of old files is enabled, fetch current certificate info
        if [ "$NS_DEL_OLD_CERTKEY" = "1" ]; then
          _ns_info "NS_DEL_OLD_CERTKEY is enabled. Fetching current cert files for potential deletion."
          local _current_cert_details=$(curl -s -k --connect-timeout 10 -X GET \
              -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
              "https://${NS_IP}/nitro/v1/config/sslcertkey/${CERT_NAME}")
          _old_cert_filename=$(echo "$_current_cert_details" | grep -oP '"cert":\s*"\K[^"]+')
          _old_key_filename=$(echo "$_current_cert_details" | grep -oP '"key":\s*"\K[^"]+')
        fi
        
        if [ "$_is_bundle" = "true" ]; then
          _ns_info "Executing Update Server certificate bundle (POST with action=update)..."
        else
          _ns_info "Executing Update Server certificate (POST with action=update)..."
        fi
        _action="?action=update"
        if [ "$_is_bundle" = "false" ]; then
          _needs_link_cert=false
        fi
      else
        if [ "$_is_bundle" = "true" ]; then
          _ns_info "Executing Add Server certificate bundle (POST)..."
        else
          _ns_info "Executing Add Server certificate (POST)..."
        fi
        _action=""
        if [ "$_is_bundle" = "false" ]; then
          _needs_link_cert=true
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

      local _payload_server="{ \"sslcertkey\": { \"certkey\": \"${CERT_NAME}\", \"cert\": \"$_remote_cert_filename\", \"key\": \"$_r_key_file\"${_bundle_param}${_certkey_pass_param}$_delete_certfile_param } }"

      local _res_server
      _res_server=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X "$_method" -H "Content-Type: application/json" \
        -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
        -d "$_payload_server" \
        "https://${NS_IP}/nitro/v1/config/sslcertkey${_action}")
      
      if [ "$_is_bundle" = "true" ]; then
        _log_api_payload "$_method Server bundle ($CERT_NAME $_action)" "$_payload_server" "$_res_server"
        if _check_api_response "$_res_server" "Server certificate bundle operation"; then
          _config_changed=true
          # If deletion is enabled and old file differs from new file, execute deletion
          if [ "$NS_DEL_OLD_CERTKEY" = "1" ]; then
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
        _log_api_payload "$_method Server ($CERT_NAME $_action)" "$_payload_server" "$_res_server"
        if _check_api_response "$_res_server" "Server certificate operation"; then
          _config_changed=true
          # If deletion is enabled and old file differs from new file, execute deletion
          if [ "$NS_DEL_OLD_CERTKEY" = "1" ]; then
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

  # --- Step 5: Get existing NetScaler certificate list ---
  _ns_all_certs=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X GET \
    -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
    "https://${NS_IP}/nitro/v1/config/sslcertkey")
  
  if [ -z "$_ns_all_certs" ]; then
    _ns_error "Unable to connect to NetScaler or retrieve certificate list."
  fi

  # --- Step 6: Choose deployment path (Fullchain or Standard) ---
  if [ "$USE_FULLCHAIN" = "1" ] && [ -n "$CERT_FULLCHAIN_PATH" ] && [ -f "$CERT_FULLCHAIN_PATH" ]; then
    # --- Path A: Fullchain (Bundle) deployment ---
    _ns_info "Using bundle deployment method."

    # --- Step 6A-1: Process server certificate bundle ---
    _r_cert_file="${CERT_NAME}_fullchain_${_date_suffix}.cer"
    _process_server_cert "$CERT_FULLCHAIN_PATH" "$_r_cert_file" "true"
    # CA and Link steps are skipped in this flow.

  else
    # --- Path B: Standard (Separate) deployment ---
    _ns_info "Using standard separate cert/ca deployment method."
    
    # --- Step 6B-1: Process CA intermediate certificate ---
    _l_path="$CA_CERT_PATH"
    _l_serial=$(openssl x509 -in "$_l_path" -noout -serial | cut -d'=' -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]')
    _ca_cn=$(openssl x509 -in "$_l_path" -noout -subject | sed -n 's/.*CN = //p' | cut -d'/' -f1 | tr -d '*' | tr ' ' '_')
    _base_ca_name="CA_${_ca_cn}"
    _r_ca_file="${_base_ca_name}_${_date_suffix}.cer"

    # Use more precise grep syntax to find serial, and handle JSON arrays
    if echo "$_ns_all_certs" | grep -qi "\"serial\": *\"$_l_serial\""; then
      _ns_info "CA [$_base_ca_name] serial matches, skipping upload."
      # Extract certkey name from JSON object containing serial, ensuring only the first result is taken
      _target_ca_certname=$(echo "$_ns_all_certs" | sed 's/},{/}\n{/g' | grep -i "\"serial\": *\"$_l_serial\"" | sed -n 's/.*"certkey": *"\([^"]*\)".*/\1/p' | head -n 1)
      _ns_info "Found existing CA object name: [$_target_ca_certname]"
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
        _ns_info "CA object name conflict, renamed to [$_ca_keyname]"
      fi

      _payload_ca="{ \"sslcertkey\": { \"certkey\": \"$_ca_keyname\", \"cert\": \"$_r_ca_file\"$_delete_certfile_param } }"
      _res_ca=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
        -d "$_payload_ca" \
        "https://${NS_IP}/nitro/v1/config/sslcertkey")

      _log_api_payload "Add CA ($_ca_keyname)" "$_payload_ca" "$_res_ca"

      if _check_api_response "$_res_ca" "Add CA ($_ca_keyname)"; then
        _ca_added=true
        _config_changed=true
        # The target for linking is the one we just created
        _target_ca_certname="$_ca_keyname"
      else
        _ns_error "CA Add failed: $_res_ca"
      fi
    fi

    # --- Step 6B-2: Process server certificate ---
    _r_cert_file="${CERT_NAME}_${_date_suffix}.cer"
    _process_server_cert "$CERT_PATH" "$_r_cert_file" "false"

    # --- Step 6B-3: Link certificate chain ---
    # Ensure variable comparison is strict, and log the result
    if { [ "$_needs_link_cert" = "true" ] || [ "$_ca_added" = "true" ]; } && [ -n "$_target_ca_certname" ]; then
      _ns_info "Linking certificate ($CERT_NAME -> $_target_ca_certname)..."
      _payload_link="{ \"sslcertkey\": { \"certkey\": \"${CERT_NAME}\", \"linkcertkeyname\": \"$_target_ca_certname\" } }"
      _res_link=$(curl -s -k --connect-timeout 10 -w "\n%{http_code}" -X POST -H "Content-Type: application/json" \
        -H "Cookie: NITRO_AUTH_TOKEN=${_session_token}" \
        -d "$_payload_link" \
        "https://${NS_IP}/nitro/v1/config/sslcertkey?action=link")
      
      _log_api_payload "sslcertkey?action=link" "$_payload_link" "$_res_link"
      if _check_api_response "$_res_link" "Certificate Link"; then
        _config_changed=true
      else
        _ns_info "Link failed: $_res_link"
      fi
    else
      _ns_info "Skipping Link action (Cert Added: $_needs_link_cert, CA Added: $_ca_added)"
    fi
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
