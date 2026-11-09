#!/bin/bash
set -euo pipefail

SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib/ci.sh
source "${SCRIPTS_DIR}/lib/ci.sh"

# No default: there is no hosted provisioning service. Relay credentials come
# from `via auth export` (tunnel-key mode) or from client-id/client-secret.
ASD_ENDPOINT="${ASD_ENDPOINT:-}"

# Mask secrets early to prevent leaking in logs
if [ -n "${INPUT_TUNNEL_KEY:-}" ]; then
  ci_mask "${INPUT_TUNNEL_KEY}"
fi
if [ -n "${ASD_API_KEY:-}" ]; then
  ci_mask "${ASD_API_KEY}"
fi
if [ -n "${INPUT_CLIENT_SECRET:-}" ]; then
  ci_mask "${INPUT_CLIENT_SECRET}"
fi

# Normalize special region values to empty (let API decide)
if [ "${REGION:-}" = "User Default" ] || [ "${REGION:-}" = "default" ]; then
  REGION=""
fi

# Validate region for safe JSON interpolation
if [ -n "${REGION:-}" ] && [[ ! "$REGION" =~ ^[a-z0-9-]*$ ]]; then
  ci_error "Invalid region '${REGION}'. Must be lowercase alphanumeric with hyphens."
  exit 1
fi

ci_group_start "Checking relay credentials"

RELAY_AUTH=""
ASD_CLIENT_ID=""
ASD_CLIENT_SECRET=""
EXPIRES_AT=""
OWNERSHIP_TYPE=""
APPEND_USER=""

if [ -n "${INPUT_TUNNEL_KEY:-}" ] || [ -n "${INPUT_TUNNEL_KEY_ID:-}" ]; then
  # === RELAY KEY MODE (recommended) ===
  # The values `via auth export` prints on a device enrolled on the relay.
  RELAY_AUTH="key"
  if [ -z "${INPUT_TUNNEL_KEY:-}" ] || [ -z "${INPUT_TUNNEL_KEY_ID:-}" ]; then
    ci_error "tunnel-key and tunnel-key-id go together. Run 'via auth export' on a device enrolled on your relay and pass both values from secrets."
    exit 1
  fi
  if [ -z "${ASD_TUNNEL_HOST:-}" ]; then
    ci_error "tunnel-host is required with tunnel-key: pass the ASD_TUNNEL_HOST value from 'via auth export'."
    exit 1
  fi
  EXPIRES_AT="N/A (relay key)"
  echo "Using relay key ${INPUT_TUNNEL_KEY_ID} on ${ASD_TUNNEL_HOST}"

elif [ -n "${INPUT_CLIENT_ID:-}" ] && [ -n "${INPUT_CLIENT_SECRET:-}" ]; then
  # === CLIENT ID / SECRET MODE ===
  # A relay client that logs in with a password instead of a key.
  RELAY_AUTH="password"
  echo "Using provided client credentials (skipping provisioning)"
  ASD_CLIENT_ID="$INPUT_CLIENT_ID"
  ASD_CLIENT_SECRET="$INPUT_CLIENT_SECRET"
  ci_mask "${ASD_CLIENT_SECRET}"
  EXPIRES_AT="N/A (pre-existing)"
  OWNERSHIP_TYPE="shared"

  # tunnel-host and tunnel-port MUST be provided with pre-existing credentials
  if [ -z "${ASD_TUNNEL_HOST:-}" ]; then
    ci_error "tunnel-host required when using pre-existing credentials"
    exit 1
  fi
  if [ -z "${ASD_TUNNEL_PORT:-}" ]; then
    ci_error "tunnel-port required when using pre-existing credentials"
    exit 1
  fi

  echo "Using pre-existing credentials: client_id=${ASD_CLIENT_ID}"

elif [ -z "${ASD_ENDPOINT}" ]; then
  ci_error "No relay credentials. On a device enrolled on your relay (via relay add '<invite link>'), run 'via auth export' and pass ASD_TUNNEL_KEY, ASD_TUNNEL_KEY_ID and ASD_TUNNEL_HOST (optionally ASD_TUNNEL_PORT) as tunnel-key, tunnel-key-id, tunnel-host and tunnel-port."
  exit 1

elif [ -n "${ASD_API_KEY:-}" ]; then
  # === LEGACY API KEY MODE (only with an explicit api-endpoint) ===
  RELAY_AUTH="password"
  # Provisions credentials via credential-provision endpoint with configurable TTL
  echo "Using API key authentication (credential-provision)"

  HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" "${ASD_ENDPOINT}/functions/v1/credential-provision" \
    -H "X-API-Key: ${ASD_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"project\": \"${CI_REPO}\",
      \"ttl_minutes\": ${TTL_MINUTES:-0},
      $([ -n "${REGION:-}" ] && printf '\"region\": \"%s\",' "$REGION")
      \"metadata\": {
        \"ci_run_id\": \"${CI_RUN_ID}\",
        \"ci_repository\": \"${CI_REPO}\",
        \"ci_platform\": \"${CI_PLATFORM}\"
      }
    }" 2>&1) || true
  HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
  RESPONSE=$(echo "$HTTP_RESPONSE" | sed '$d')

  if [ "${HTTP_CODE:-0}" -lt 200 ] 2>/dev/null || [ "${HTTP_CODE:-0}" -ge 300 ] 2>/dev/null; then
    ci_error "Failed to provision credentials via API key (HTTP ${HTTP_CODE})"
    echo "Response: $RESPONSE"
    exit 1
  fi

  if [ -z "$RESPONSE" ]; then
    ci_error "Empty response from credential-provision endpoint"
    exit 1
  fi

  # Validate response is JSON
  if ! echo "$RESPONSE" | jq -e . >/dev/null 2>&1; then
    ci_error "API returned invalid JSON. Response: ${RESPONSE:0:200}"
    exit 1
  fi

  # Check for error in response
  ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error // empty' 2>/dev/null || echo "")
  if [ -n "$ERROR_MSG" ]; then
    MSG=$(echo "$RESPONSE" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "Unknown error")
    ci_error "API error: ${ERROR_MSG} - ${MSG}"
    exit 1
  fi

  # Parse response
  ASD_CLIENT_ID=$(echo "$RESPONSE" | jq -r '.tunnel_client_id')
  ASD_CLIENT_SECRET=$(echo "$RESPONSE" | jq -r '.tunnel_client_secret')
  ci_mask "${ASD_CLIENT_SECRET}"
  EXPIRES_AT=$(echo "$RESPONSE" | jq -r '.expires_at')
  OWNERSHIP_TYPE=$(echo "$RESPONSE" | jq -r '.ownership_type // "shared"')
  APPEND_USER=$(echo "$RESPONSE" | jq -r '.append_user_to_subdomain // empty')

  if [ "$ASD_CLIENT_ID" = "null" ] || [ -z "$ASD_CLIENT_ID" ]; then
    ci_error "Invalid API response: missing tunnel_client_id"
    echo "Response: $RESPONSE"
    exit 1
  fi

  # Use FQDN for URL construction, fall back to host
  FQDN_FROM_API=$(echo "$RESPONSE" | jq -r '.tunnel_fqdn // empty')
  HOST_FROM_API=$(echo "$RESPONSE" | jq -r '.tunnel_host // empty')
  PORT_FROM_API=$(echo "$RESPONSE" | jq -r '.tunnel_port // empty')

  # Priority: explicit input > API fqdn > API host
  ASD_TUNNEL_HOST="${ASD_TUNNEL_HOST:-${FQDN_FROM_API:-$HOST_FROM_API}}"
  ASD_TUNNEL_PORT="${ASD_TUNNEL_PORT:-$PORT_FROM_API}"

  echo "Provisioned via API key: tunnel_user=${ASD_CLIENT_ID}, expires=${EXPIRES_AT}"

else
  # === LEGACY EPHEMERAL MODE (only with an explicit api-endpoint) ===
  # Unauthenticated endpoint — short-lived tokens
  RELAY_AUTH="password"
  echo "Creating ephemeral tunnel credentials..."
  ci_warning "Ephemeral tokens are short-lived. Use a relay key (tunnel-key) for longer sessions."

  HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" "${ASD_ENDPOINT}/functions/v1/create-ephemeral-token" \
    -H "Content-Type: application/json" \
    -d "{
      \"source\": \"ci-action:ci-terminal\",
      \"repo\": \"${CI_REPO:-unknown}\"
    }" 2>&1) || true
  HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -1)
  RESPONSE=$(echo "$HTTP_RESPONSE" | sed '$d')

  if [ "${HTTP_CODE:-0}" -lt 200 ] 2>/dev/null || [ "${HTTP_CODE:-0}" -ge 300 ] 2>/dev/null; then
    ci_error "Failed to create ephemeral token (HTTP ${HTTP_CODE})"
    echo "Response: $RESPONSE"
    exit 1
  fi

  if [ -z "$RESPONSE" ]; then
    ci_error "Empty response from create-ephemeral-token endpoint"
    exit 1
  fi

  # Validate response is JSON
  if ! echo "$RESPONSE" | jq -e . >/dev/null 2>&1; then
    ci_error "API returned invalid JSON. Response: ${RESPONSE:0:200}"
    exit 1
  fi

  # Check for error in response
  ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error // empty' 2>/dev/null || echo "")
  if [ -n "$ERROR_MSG" ]; then
    MSG=$(echo "$RESPONSE" | jq -r '.message // "Unknown error"' 2>/dev/null || echo "Unknown error")
    ci_error "API error: ${ERROR_MSG} - ${MSG}"
    exit 1
  fi

  # Parse response
  ASD_CLIENT_ID=$(echo "$RESPONSE" | jq -r '.tunnel_client_id')
  ASD_CLIENT_SECRET=$(echo "$RESPONSE" | jq -r '.tunnel_client_secret')
  ci_mask "${ASD_CLIENT_SECRET}"
  EXPIRES_AT=$(echo "$RESPONSE" | jq -r '.expires_at')
  OWNERSHIP_TYPE=$(echo "$RESPONSE" | jq -r '.ownership_type // "shared"')
  APPEND_USER=$(echo "$RESPONSE" | jq -r '.append_user_to_subdomain // empty')

  if [ "$ASD_CLIENT_ID" = "null" ] || [ -z "$ASD_CLIENT_ID" ]; then
    ci_error "Invalid response: missing tunnel_client_id"
    echo "Response: $RESPONSE"
    exit 1
  fi

  # Use FQDN for URL construction, fall back to host
  FQDN_FROM_API=$(echo "$RESPONSE" | jq -r '.tunnel_fqdn // empty')
  HOST_FROM_API=$(echo "$RESPONSE" | jq -r '.tunnel_host // empty')
  PORT_FROM_API=$(echo "$RESPONSE" | jq -r '.tunnel_port // empty')

  # Priority: explicit input > API fqdn > API host
  ASD_TUNNEL_HOST="${ASD_TUNNEL_HOST:-${FQDN_FROM_API:-$HOST_FROM_API}}"
  ASD_TUNNEL_PORT="${ASD_TUNNEL_PORT:-$PORT_FROM_API}"

  echo "Provisioned ephemeral: tunnel_user=${ASD_CLIENT_ID}, expires=${EXPIRES_AT}"
fi

# Validate we have tunnel server details (no defaults — must come from API or input)
if [ -z "${ASD_TUNNEL_HOST:-}" ]; then
  ci_error "No tunnel host available. API response must include tunnel_fqdn or tunnel_host, or provide tunnel-host input."
  exit 1
fi
# The port is optional with a relay key (the CLI uses 2222); a password
# login needs it spelled out.
if [ -z "${ASD_TUNNEL_PORT:-}" ] && [ "$RELAY_AUTH" != "key" ]; then
  ci_error "No tunnel port available. API response must include tunnel_port, or provide tunnel-port input."
  exit 1
fi

# Export credentials to environment for subsequent steps
ci_set_env "RELAY_AUTH" "${RELAY_AUTH}"
if [ "$RELAY_AUTH" = "key" ]; then
  ci_set_env "ASD_TUNNEL_KEY" "${INPUT_TUNNEL_KEY}"
  ci_set_env "ASD_TUNNEL_KEY_ID" "${INPUT_TUNNEL_KEY_ID}"
else
  ci_set_env "ASD_CLIENT_ID" "${ASD_CLIENT_ID}"
  ci_set_env "ASD_CLIENT_SECRET" "${ASD_CLIENT_SECRET}"
  ci_set_env "TUNNEL_OWNERSHIP" "${OWNERSHIP_TYPE}"
  ci_set_env "APPEND_USER_TO_SUBDOMAIN" "${APPEND_USER:-true}"
fi
ci_set_env "ASD_TUNNEL_HOST" "${ASD_TUNNEL_HOST}"
if [ -n "${ASD_TUNNEL_PORT:-}" ]; then
  ci_set_env "ASD_TUNNEL_PORT" "${ASD_TUNNEL_PORT}"
fi
ci_set_env "ASD_EXPIRES_AT" "${EXPIRES_AT}"

# Export API key for in-session CLI use
if [ -n "${ASD_API_KEY:-}" ]; then
  ci_set_env "ASD_API_KEY" "${ASD_API_KEY}"
fi

# Set outputs for subsequent steps
ci_set_output "client_id" "${ASD_CLIENT_ID}"
ci_set_output "expires_at" "${EXPIRES_AT}"

echo "Relay: ${ASD_TUNNEL_HOST}:${ASD_TUNNEL_PORT:-2222}"
ci_group_end
