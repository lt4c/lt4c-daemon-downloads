#!/usr/bin/env bash
set -euo pipefail

METADATA_URL="${METADATA_URL:-https://download.lt4c.io.vn/latest.json}"
BINARY_PATH="/usr/local/bin/lt4c-daemon-latest"
SERVICE_NAME="lt4c-daemon"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
STATE_DIR="/var/lib/lt4c-daemon"
TRAEFIK_DIR="/etc/lt4c-traefik"

SERVICE_UNIT_CONTENT="$(cat <<'EOF'
[Unit]
Description=LT4C container manager daemon
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
User=lt4c
Group=lt4c
Environment=LT4C_HTTP_ADDR=0.0.0.0:8080
Environment=LT4C_DB_PATH=/var/lib/lt4c-daemon/state.db
Environment=LT4C_TOKEN_PATH=/var/lib/lt4c-daemon/token
Environment=LT4C_TRAEFIK_CONFIG_DIR=/etc/lt4c-traefik
Environment=LT4C_BOXES_ROOT=/boxes/home
Environment=LT4C_BOX_MOUNT_PATH=/home
Environment=LT4C_DOCKER_HOST=unix:///var/run/docker.sock
Environment=LT4C_RECONCILE_SECONDS=30
ExecStart=/usr/local/bin/lt4c-daemon-latest daemon
Restart=always
RestartSec=5
WorkingDirectory=/var/lib/lt4c-daemon
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
)"

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root." >&2
    exit 1
  fi
}

ensure_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl ca-certificates jq
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates jq
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates jq
  else
    echo "Please install curl, jq and ca-certificates manually before running this script." >&2
    exit 1
  fi
}

create_user_and_dirs() {
  if ! id -u lt4c >/dev/null 2>&1; then
    useradd --system --home "${STATE_DIR}" --shell /usr/sbin/nologin lt4c
  fi
  install -d -o lt4c -g lt4c "${STATE_DIR}" "${TRAEFIK_DIR}" /boxes/home
}

download_binary() {
  echo "Fetching metadata from ${METADATA_URL}..."
  local latest_json
  latest_json="$(curl -fsSL "${METADATA_URL}")"

  local version download_url
  version="$(printf '%s' "${latest_json}" | jq -r '.version')"

  download_url="$(printf '%s' "${latest_json}" | jq -r '
      .artifacts[]
      | select(.os=="linux" and .arch=="amd64")
      | .url
    ')"

  if [[ -z "${download_url}" || "${download_url}" == "null" ]]; then
    echo "ERROR: Could not find Linux amd64 binary in metadata!" >&2
    exit 1
  fi

  echo "Downloading ${version} from ${download_url}..."
  local tmp
  tmp="$(mktemp -p /tmp lt4c-download.XXXXXX)"

  curl -fsSL "${download_url}" -o "${tmp}"

  install -m 0755 "${tmp}" "${BINARY_PATH}"
  ln -sf "${BINARY_PATH}" /usr/local/bin/lt4c-daemon
  rm -f "${tmp}"
}


install_service() {
  printf '%s\n' "${SERVICE_UNIT_CONTENT}" > "${SERVICE_FILE}"
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}"
}

main() {
  require_root
  ensure_deps
  create_user_and_dirs
  download_binary
  install_service
  echo "Installation complete. ${SERVICE_NAME} is running with auto-update enabled."
}

main "$@"
