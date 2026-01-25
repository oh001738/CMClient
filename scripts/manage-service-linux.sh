#!/usr/bin/env bash

# Interactive systemd service manager for CMClient (CallMesh APRS Gateway).
# Features:
# - Prompt for CallMesh API Key and optional CLI args
# - Install/reinstall service with autostart
# - Update API Key only
# - Start/stop/restart/status/enable/disable
# - Uninstall service and clean artifacts
set -euo pipefail

SERVICE_NAME="callmesh-client"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_DIR="/etc/callmesh"
ENV_FILE="${ENV_DIR}/callmesh.env"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="$(command -v node || true)"
REQUIRED_NODE_MAJOR=22
RUN_AS_USER="${SUDO_USER:-$(id -un)}"

log() {
  printf '[service] %s\n' "$*"
}

err() {
  printf '[service][error] %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
用法: scripts/manage-service-linux.sh [子指令]

子指令:
  install      安裝/重裝服務並設定 API Key（啟用開機自動啟動）
  set-key      重新輸入 API Key 並重啟服務
  logs [N]     顯示最近 N 行 log（預設 200）
  start        啟動服務
  stop         停止服務
  restart      重啟服務
  status       查看狀態
  enable       啟用開機自動啟動
  disable      停用開機自動啟動
  uninstall    停止並移除服務與設定
  menu         互動式選單（預設）
EOF
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    err "此腳本需要 systemd 環境。"
    exit 1
  fi
}

sudo_prefix() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo ""
  elif command -v sudo >/dev/null 2>&1; then
    echo "sudo"
  else
    err "需要 sudo 權限執行系統服務操作。"
    exit 1
  fi
}

check_node() {
  if [ -z "$NODE_BIN" ]; then
    err "找不到 node，請先安裝 Node.js ${REQUIRED_NODE_MAJOR} 或以上版本。"
    exit 1
  fi

  local major
  major="$("$NODE_BIN" -v | sed 's/^v//' | cut -d. -f1)"
  if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
    err "偵測到 Node.js v${major}，請升級到 ${REQUIRED_NODE_MAJOR} 或以上版本。"
    exit 1
  fi
}

prompt_api_key() {
  local api_key=""
  while [ -z "$api_key" ]; do
    read -r -s -p "請輸入 CallMesh API Key: " api_key
    echo
    if [ -z "$api_key" ]; then
      err "API Key 不可為空，請重新輸入。"
    fi
  done
  echo "$api_key"
}

prompt_args() {
  local args_default="${1:-}"
  echo "可選: 輸入額外 CLI 參數（例如: --host 127.0.0.1 --port 4403 --web-ui）"
  read -r -p "TMAG_ARGS (${args_default}): " extra_args
  echo "${extra_args:-$args_default}"
}

write_env_file() {
  local api_key="$1"
  local tmag_args="$2"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  $sudo_cmd mkdir -p "$ENV_DIR"
  $sudo_cmd tee "$ENV_FILE" >/dev/null <<EOF
CALLMESH_API_KEY="${api_key}"
TMAG_ARGS="${tmag_args}"
NODE_ENV=production
EOF
  $sudo_cmd chmod 600 "$ENV_FILE"
  log "已寫入 ${ENV_FILE}"
}

write_unit_file() {
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  $sudo_cmd tee "$UNIT_PATH" >/dev/null <<EOF
[Unit]
Description=CallMesh Client (APRS Gateway)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_AS_USER}
WorkingDirectory=${PROJECT_ROOT}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${PROJECT_ROOT}/src/index.js \$TMAG_ARGS
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  $sudo_cmd chmod 644 "$UNIT_PATH"
  log "已寫入 ${UNIT_PATH}"
}

install_service() {
  require_systemd
  check_node
  local api_key tmag_args existing_args=""
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    existing_args="${TMAG_ARGS:-}"
  fi
  api_key="$(prompt_api_key)"
  tmag_args="$(prompt_args "$existing_args")"
  write_env_file "$api_key" "$tmag_args"

  write_unit_file

  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  $sudo_cmd systemctl daemon-reload
  $sudo_cmd systemctl enable --now "$SERVICE_NAME"
  log "服務已啟用並開機自動啟動。"
}

set_key() {
  require_systemd
  local api_key tmag_args
  api_key="$(prompt_api_key)"
  # 保留現有 CLI 參數
  tmag_args=""
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    tmag_args="${TMAG_ARGS:-}"
  fi
  write_env_file "$api_key" "$tmag_args"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  $sudo_cmd systemctl restart "$SERVICE_NAME"
  log "已更新 API Key 並重啟服務。"
}

uninstall_service() {
  require_systemd
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  read -r -p "確定要停止並移除服務與設定檔嗎？[y/N] " ans
  case "$ans" in
    y|Y)
      $sudo_cmd systemctl disable --now "$SERVICE_NAME" || true
      $sudo_cmd rm -f "$UNIT_PATH"
      $sudo_cmd rm -f "$ENV_FILE"
      $sudo_cmd systemctl daemon-reload
      log "已移除服務與設定。"
      ;;
    *)
      log "已取消。"
      ;;
  esac
}

start_service() { require_systemd; "$(sudo_prefix)" systemctl start "$SERVICE_NAME"; }
stop_service() { require_systemd; "$(sudo_prefix)" systemctl stop "$SERVICE_NAME"; }
restart_service() { require_systemd; "$(sudo_prefix)" systemctl restart "$SERVICE_NAME"; }
status_service() { require_systemd; "$(sudo_prefix)" systemctl status --no-pager "$SERVICE_NAME" || true; }
enable_service() { require_systemd; "$(sudo_prefix)" systemctl enable "$SERVICE_NAME"; }
disable_service() { require_systemd; "$(sudo_prefix)" systemctl disable "$SERVICE_NAME"; }
logs_service() {
  require_systemd
  local lines="${1:-200}"
  "$(sudo_prefix)" journalctl -u "$SERVICE_NAME" -n "$lines" --no-pager
}

menu() {
  echo "=== CallMesh Client 服務管理 ==="
  echo "1) 安裝/重裝服務（含 API Key）"
  echo "2) 重新輸入 API Key"
  echo "3) 啟動服務"
  echo "4) 停止服務"
  echo "5) 重啟服務"
  echo "6) 查看狀態"
  echo "7) 啟用開機自動啟動"
  echo "8) 停用開機自動啟動"
  echo "9) 解除安裝"
  echo "10) 查看最近 log"
  read -r -p "選擇動作 [1-10]: " choice
  case "$choice" in
    1) install_service ;;
    2) set_key ;;
    3) start_service ;;
    4) stop_service ;;
    5) restart_service ;;
    6) status_service ;;
    7) enable_service ;;
    8) disable_service ;;
    9) uninstall_service ;;
    10) logs_service ;;
    *) err "無效選項"; exit 1 ;;
  esac
}

main() {
  local cmd="${1:-menu}"
  case "$cmd" in
    install) install_service ;;
    set-key) set_key ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    status) status_service ;;
    enable) enable_service ;;
    disable) disable_service ;;
    logs) shift || true; logs_service "$1" ;;
    uninstall) uninstall_service ;;
    menu) menu ;;
    -h|--help) usage ;;
    *) err "未知指令：$cmd"; usage; exit 1 ;;
  esac
}

main "$@"
