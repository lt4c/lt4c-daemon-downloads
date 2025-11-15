#!/usr/bin/env bash
set -euo pipefail

METADATA_URL="${METADATA_URL:-https://download.lt4c.io.vn/latest.json}"
BINARY_PATH="/usr/local/bin/lt4c-daemon"
STATE_DIR="/var/lib/lt4c-daemon"
TRAEFIK_DIR="/etc/lt4c-traefik"
PID_FILE="/var/run/lt4c-daemon.pid"
LOG_FILE="/var/log/lt4c-daemon.log"
SERVICE_FILE="/etc/systemd/system/lt4c-daemon.service"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
esac

detect_systemd() {
    if [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]; then
        return 0
    else
        return 1
    fi
}

fetch_binary() {
    echo "[INFO] Fetching metadata..."
    local json
    json="$(curl -fsSL "$METADATA_URL")"

    local url
    url="$(echo "$json" | jq -r \
        --arg arch "$ARCH" \
        '.artifacts[] | select(.os=="linux" and .arch==$arch) | .url'
    )"

    if [[ -z "$url" || "$url" == "null" ]]; then
        echo "[ERROR] No matching binary for arch=$ARCH" >&2
        exit 1
    fi

    echo "[INFO] Downloading binary: $url"
    curl -fsSL "$url" -o "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
}

create_dirs() {
    mkdir -p "$STATE_DIR" "$TRAEFIK_DIR" /boxes/home /var/run /var/log
}

install_systemd_service() {
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=LT4C container manager daemon
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
User=root
Group=root
ExecStart=${BINARY_PATH} daemon
WorkingDirectory=${STATE_DIR}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    echo "[INFO] Enabling systemd service..."
    systemctl daemon-reload
    systemctl enable --now lt4c-daemon
}

run_systemd_mode() {
    echo "[INFO] Running in SYSTEMD MODE"
    create_dirs
    fetch_binary
    install_systemd_service
    echo "[INFO] Install complete (systemd)"
}

run_no_systemd_mode() {
    echo "[INFO] Running in NO-SYSTEMD MODE"
    create_dirs
    fetch_binary

    # Stop old daemon
    if [[ -f "$PID_FILE" ]]; then
        oldpid="$(cat "$PID_FILE")"
        if kill -0 "$oldpid" 2>/dev/null; then
            echo "[INFO] Stopping old daemon PID=$oldpid"
            kill "$oldpid" || true
            sleep 1
        fi
    fi

    echo "[INFO] Starting daemon in background..."
    nohup "$BINARY_PATH" daemon \
        --http-addr 0.0.0.0:8080 \
        --db-path "$STATE_DIR/state.db" \
        --token-path "$STATE_DIR/token" \
        --traefik-config-dir "$TRAEFIK_DIR" \
        --boxes-root /boxes/home \
        --box-mount-path /home \
        > "$LOG_FILE" 2>&1 &

    echo $! > "$PID_FILE"
    echo "[INFO] Daemon started with PID $(cat "$PID_FILE")"
    echo "[INFO] Install complete (no-systemd)"
}

main() {
    if detect_systemd; then
        run_systemd_mode
    else
        run_no_systemd_mode
    fi
}

main "$@"
