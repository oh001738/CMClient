#!/usr/bin/env bash

# Interactive systemd service manager for CMClient (CallMesh APRS Gateway).
# Features:
# - Prompt for CallMesh API Key與連線方式（TCP/IP 或 Serial 選單）
# - Install/reinstall service with autostart
# - Update API Key only
# - Start/stop/restart/status/enable/disable
# - Check/update client and manage auto-update timer
# - Uninstall service and clean artifacts
set -euo pipefail

SERVICE_NAME="callmesh-client"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
UPDATE_SERVICE_NAME="${SERVICE_NAME}-update"
UPDATE_SERVICE_PATH="/etc/systemd/system/${UPDATE_SERVICE_NAME}.service"
UPDATE_TIMER_PATH="/etc/systemd/system/${UPDATE_SERVICE_NAME}.timer"
ENV_DIR="/etc/callmesh"
ENV_FILE="${ENV_DIR}/callmesh.env"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NODE_BIN="$(command -v node || true)"
REQUIRED_NODE_MAJOR=22
RUN_AS_USER="${RUN_AS_USER:-${SUDO_USER:-$(id -un)}}"
SERVICE_USER_VALUE="${SERVICE_USER:-$RUN_AS_USER}"
UPDATE_SCHEDULE="${UPDATE_SCHEDULE:-*-*-* 04:00:00}"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

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
  check-update 檢查是否有新版（對照 origin/main）
  update       下載更新並重新安裝依賴後重啟服務（需乾淨工作目錄）
  auto-update-enable   啟用自動更新（建立 systemd timer，每天 04:00，含隨機延遲）
  auto-update-disable  停用自動更新
  auto-update-status   查看自動更新計畫
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

detect_package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  else
    echo ""
  fi
}

install_packages() {
  local pm="$1"; shift
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  case "$pm" in
    apt)
      $sudo_cmd apt-get update
      $sudo_cmd apt-get install -y "$@"
      ;;
    dnf)
      $sudo_cmd dnf install -y "$@"
      ;;
    yum)
      $sudo_cmd yum install -y "$@"
      ;;
    pacman)
      $sudo_cmd pacman -Sy --noconfirm --needed "$@"
      ;;
    zypper)
      $sudo_cmd zypper --non-interactive refresh
      $sudo_cmd zypper --non-interactive install "$@"
      ;;
    *)
      err "無法偵測可用的套件管理器，請手動安裝：$*"
      exit 1
      ;;
  esac
}

load_env_settings() {
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    SERVICE_USER_VALUE="${SERVICE_USER:-$SERVICE_USER_VALUE}"
  fi
}

load_nvm_if_available() {
  local candidates=()
  [ -n "$NVM_DIR" ] && candidates+=("$NVM_DIR")
  if [ -n "${SERVICE_USER_VALUE:-}" ]; then
    if [ "$SERVICE_USER_VALUE" = "root" ]; then
      candidates+=("/root/.nvm")
    else
      candidates+=("/home/${SERVICE_USER_VALUE}/.nvm")
    fi
  fi
  candidates+=("$HOME/.nvm" "/usr/local/nvm")
  for d in "${candidates[@]}"; do
    if [ -s "$d/nvm.sh" ]; then
      export NVM_DIR="$d"
      # shellcheck disable=SC1090
      . "$d/nvm.sh"
      return 0
    fi
  done
  return 1
}

check_node() {
  load_env_settings
  load_nvm_if_available || true
  NODE_BIN="$(command -v node || true)"
  if [ -z "$NODE_BIN" ]; then
    log "找不到 node，嘗試執行 scripts/install-linux.sh 安裝 Node.js ${REQUIRED_NODE_MAJOR}+ ..."
    if [ -x "${PROJECT_ROOT}/scripts/install-linux.sh" ]; then
      bash "${PROJECT_ROOT}/scripts/install-linux.sh"
      load_nvm_if_available || true
      NODE_BIN="$(command -v node || true)"
    fi
  fi

  local major
  if [ -n "$NODE_BIN" ]; then
    major="$("$NODE_BIN" -v | sed 's/^v//' | cut -d. -f1)"
    if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
      log "偵測到 Node.js v${major}，低於需求 (${REQUIRED_NODE_MAJOR}+)，嘗試升級..."
      if [ -x "${PROJECT_ROOT}/scripts/install-linux.sh" ]; then
        bash "${PROJECT_ROOT}/scripts/install-linux.sh"
        load_nvm_if_available || true
        NODE_BIN="$(command -v node || true)"
        major="$("$NODE_BIN" -v | sed 's/^v//' | cut -d. -f1)"
      fi
    fi
  fi

  if [ -z "$NODE_BIN" ]; then
    err "仍找不到 Node.js，請手動安裝 ${REQUIRED_NODE_MAJOR}+。"
    exit 1
  fi
  if [ "$major" -lt "$REQUIRED_NODE_MAJOR" ]; then
    err "Node.js 版本仍低於 ${REQUIRED_NODE_MAJOR}，請手動升級。"
    exit 1
  fi
}

require_git() {
  if command -v git >/dev/null 2>&1; then
    return
  fi

  log "找不到 git，嘗試自動安裝..."
  local pm
  pm="$(detect_package_manager)"
  if [ -n "$pm" ]; then
    install_packages "$pm" git
  fi

  if ! command -v git >/dev/null 2>&1; then
    err "仍找不到 git，請手動安裝後再試。"
    exit 1
  fi
}

run_as_service_user() {
  local sudo_cmd=""
  if [ "${EUID:-$(id -u)}" -eq 0 ] && [ "$SERVICE_USER_VALUE" != "root" ]; then
    sudo_cmd="sudo -u $SERVICE_USER_VALUE -H"
  fi
  if [ -n "$sudo_cmd" ]; then
    $sudo_cmd "$@"
  else
    "$@"
  fi
}

ensure_clean_worktree() {
  if ! run_as_service_user git -C "$PROJECT_ROOT" diff --quiet --ignore-submodules --; then
    err "工作目錄有尚未提交的修改，請先處理後再更新。"
    exit 1
  fi
  if ! run_as_service_user git -C "$PROJECT_ROOT" diff --cached --quiet --ignore-submodules --; then
    err "索引中有待提交變更，請先處理後再更新。"
    exit 1
  fi
}

fetch_remote() {
  run_as_service_user git -C "$PROJECT_ROOT" fetch --tags origin main
}

check_update_status() {
  require_git
  load_env_settings
  fetch_remote
  local local_head remote_head base
  local_head="$(run_as_service_user git -C "$PROJECT_ROOT" rev-parse HEAD)"
  remote_head="$(run_as_service_user git -C "$PROJECT_ROOT" rev-parse origin/main)"
  base="$(run_as_service_user git -C "$PROJECT_ROOT" merge-base HEAD origin/main)"

  if [ "$local_head" = "$remote_head" ]; then
    log "目前已是最新版本 (${local_head})."
    return 0
  fi

  if [ "$local_head" = "$base" ]; then
    log "有可用更新，最新版本 ${remote_head}。"
    return 1
  fi

  if [ "$remote_head" = "$base" ]; then
    log "本地有尚未推送的提交（local ${local_head}），請先處理。"
    return 2
  fi

  log "本地與遠端已分歧，請手動檢查。local ${local_head}, remote ${remote_head}, base ${base}"
  return 3
}

perform_update() {
  require_systemd
  require_git
  check_node
  load_env_settings
  ensure_clean_worktree
  fetch_remote

  local local_head remote_head base
  local_head="$(run_as_service_user git -C "$PROJECT_ROOT" rev-parse HEAD)"
  remote_head="$(run_as_service_user git -C "$PROJECT_ROOT" rev-parse origin/main)"
  base="$(run_as_service_user git -C "$PROJECT_ROOT" merge-base HEAD origin/main)"

  if [ "$local_head" = "$remote_head" ]; then
    log "已是最新版本。"
    return 0
  fi

  if [ "$local_head" != "$base" ]; then
    err "本地有未推送提交或分歧，為安全起見不自動更新。"
    exit 1
  fi

  log "套用更新（fast-forward）..."
  run_as_service_user git -C "$PROJECT_ROOT" pull --ff-only origin main

  log "安裝依賴..."
  run_as_service_user npm install --prefix "$PROJECT_ROOT"

  if [ "${1:-1}" -eq 1 ]; then
    log "重啟服務 ${SERVICE_NAME}..."
    local sudo_cmd
    sudo_cmd="$(sudo_prefix)"
    $sudo_cmd systemctl restart "$SERVICE_NAME"
  else
    log "更新完成，尚未重啟服務。"
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
  local existing="${1:-}"
  local default_mode="tcp"
  local default_host="127.0.0.1"
  local default_port="4403"
  local default_serial=""
  local default_baud="115200"

  # 從既有 TMAG_ARGS 嘗試抓取預設值
  if [[ "$existing" == *"serial://"* ]]; then
    default_mode="serial"
    default_serial="$(echo "$existing" | sed -n 's/.*serial:\\/\\/\\/?\\([^[:space:]]*\\).*/\\1/p')"
  fi
  local host_val port_val baud_val
  host_val="$(awk '{for(i=1;i<=NF;i++){if($i=="--host" && (i+1)<=NF){print $(i+1); exit}}}' <<<"$existing")"
  port_val="$(awk '{for(i=1;i<=NF;i++){if($i=="--port" && (i+1)<=NF){print $(i+1); exit}}}' <<<"$existing")"
  baud_val="$(awk '{for(i=1;i<=NF;i++){if($i=="--serial-baud" && (i+1)<=NF){print $(i+1); exit}}}' <<<"$existing")"
  if [ -n "$host_val" ] && [[ "$host_val" != serial://* ]]; then
    default_host="$host_val"
  fi
  if [ -n "$port_val" ]; then
    default_port="$port_val"
  fi
  if [ -n "$baud_val" ]; then
    default_baud="$baud_val"
  fi

  local filtered_extra
  filtered_extra="$(echo " $existing " | sed -E 's/ --host [^ ]+//g; s/ --port [^ ]+//g; s/ --serial-baud [^ ]+//g; s/ serial:\\/\\/[^ ]+//g' | xargs || true)"

  local default_mode_num="1"
  [ "$default_mode" = "serial" ] && default_mode_num="2"
  echo "選擇連線模式："
  echo "  1) TCP/IP (預設)"
  echo "  2) Serial（會列出 /dev/ttyUSB* / /dev/ttyACM* / /dev/ttyS* / /dev/ttyAMA*）"
  read -r -p "請輸入 1 或 2 [${default_mode_num}]: " mode_choice
  local mode="$default_mode"
  case "$mode_choice" in
    2) mode="serial" ;;
    1) mode="tcp" ;;
  esac

  local base_args extra_args=""
  if [ "$mode" = "tcp" ]; then
    read -r -p "TCP Host [${default_host}]: " host_input
    read -r -p "TCP Port [${default_port}]: " port_input
    host_input="${host_input:-$default_host}"
    port_input="${port_input:-$default_port}"
    base_args="--host ${host_input} --port ${port_input}"
  else
    echo "可用 Serial 裝置："
    local ports=()
    for pat in /dev/ttyUSB* /dev/ttyACM* /dev/ttyS* /dev/ttyAMA*; do
      for p in $pat; do
        [ -e "$p" ] && ports+=("$p")
      done
    done
    if [ "${#ports[@]}" -eq 0 ]; then
      echo "  (未找到常見裝置，請手動輸入路徑)"
    else
      local idx=1
      for p in "${ports[@]}"; do
        echo "  $idx) $p"
        idx=$((idx+1))
      done
    fi
    local serial_default_display="$default_serial"
    [ -z "$serial_default_display" ] && serial_default_display="${ports[0]:-}"
    read -r -p "選擇序號或直接輸入裝置路徑 [${serial_default_display}]: " serial_choice
    if [[ "$serial_choice" =~ ^[0-9]+$ ]] && [ "$serial_choice" -ge 1 ] && [ "$serial_choice" -le "${#ports[@]}" ]; then
      serial_choice="${ports[$((serial_choice-1))]}"
    fi
    serial_choice="${serial_choice:-$serial_default_display}"
    read -r -p "Serial 鮑率 [${default_baud}]: " baud_input
    baud_input="${baud_input:-$default_baud}"
    base_args="--host serial://${serial_choice} --serial-baud ${baud_input}"
  fi

  echo "可選: 額外 CLI 參數（例如: --web-ui），目前為: ${filtered_extra}"
  read -r -p "其他參數 (留空維持目前設定): " extra_input
  if [ -n "$extra_input" ]; then
    extra_args="$extra_input"
  elif [ -n "$filtered_extra" ]; then
    extra_args="$filtered_extra"
  fi

  echo "$(printf '%s %s' "$base_args" "$extra_args" | xargs)"
}

write_env_file() {
  local api_key="$1"
  local tmag_args="$2"
  local service_user="$3"
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  $sudo_cmd mkdir -p "$ENV_DIR"
  $sudo_cmd tee "$ENV_FILE" >/dev/null <<EOF
CALLMESH_API_KEY="${api_key}"
TMAG_ARGS="${tmag_args}"
SERVICE_USER="${service_user}"
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
User=${SERVICE_USER_VALUE}
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

write_update_units() {
  load_env_settings
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  $sudo_cmd tee "$UPDATE_SERVICE_PATH" >/dev/null <<EOF
[Unit]
Description=CallMesh Client auto updater
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=${PROJECT_ROOT}
Environment=RUN_AS_USER=${SERVICE_USER_VALUE}
Environment=SERVICE_USER=${SERVICE_USER_VALUE}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash -lc '${PROJECT_ROOT}/scripts/manage-service-linux.sh updater-task'

[Install]
WantedBy=multi-user.target
EOF

  $sudo_cmd tee "$UPDATE_TIMER_PATH" >/dev/null <<EOF
[Unit]
Description=CallMesh Client auto update timer

[Timer]
OnCalendar=${UPDATE_SCHEDULE}
RandomizedDelaySec=1800
Persistent=true
Unit=${UPDATE_SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

  $sudo_cmd chmod 644 "$UPDATE_SERVICE_PATH" "$UPDATE_TIMER_PATH"
  log "已寫入 ${UPDATE_SERVICE_PATH} 與 ${UPDATE_TIMER_PATH}"
}

install_service() {
  require_systemd
  check_node
  local api_key tmag_args existing_args="" service_user="$SERVICE_USER_VALUE"
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    existing_args="${TMAG_ARGS:-}"
    service_user="${SERVICE_USER:-$SERVICE_USER_VALUE}"
  fi
  api_key="$(prompt_api_key)"
  tmag_args="$(prompt_args "$existing_args")"
  SERVICE_USER_VALUE="$service_user"
  write_env_file "$api_key" "$tmag_args" "$SERVICE_USER_VALUE"

  write_unit_file

  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  $sudo_cmd systemctl daemon-reload
  $sudo_cmd systemctl enable --now "$SERVICE_NAME"
  log "服務已啟用並開機自動啟動。"
}

set_key() {
  require_systemd
  local api_key tmag_args service_user="$SERVICE_USER_VALUE"
  api_key="$(prompt_api_key)"
  # 保留現有 CLI 參數
  tmag_args=""
  if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    tmag_args="${TMAG_ARGS:-}"
    service_user="${SERVICE_USER:-$SERVICE_USER_VALUE}"
  fi
  write_env_file "$api_key" "$tmag_args" "$service_user"
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

auto_update_enable() {
  require_systemd
  require_git
  write_update_units
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  $sudo_cmd systemctl daemon-reload
  $sudo_cmd systemctl enable --now "$UPDATE_TIMER_PATH" >/dev/null 2>&1 || $sudo_cmd systemctl enable --now "$UPDATE_SERVICE_NAME".timer
  log "自動更新已啟用（排程：${UPDATE_SCHEDULE}，隨機延遲最多 1800 秒）。"
}

auto_update_disable() {
  require_systemd
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  $sudo_cmd systemctl disable --now "$UPDATE_SERVICE_NAME".timer || true
  $sudo_cmd systemctl stop "$UPDATE_SERVICE_NAME".service || true
  $sudo_cmd rm -f "$UPDATE_SERVICE_PATH" "$UPDATE_TIMER_PATH"
  $sudo_cmd systemctl daemon-reload
  log "已停用自動更新並移除 timer/service。"
}

auto_update_status() {
  require_systemd
  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  echo "--- ${UPDATE_SERVICE_NAME}.timer 狀態 ---"
  $sudo_cmd systemctl status --no-pager "$UPDATE_SERVICE_NAME".timer || true
  echo "--- 下一次排程 ---"
  $sudo_cmd systemctl list-timers --no-pager | grep "$UPDATE_SERVICE_NAME" || true
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
  echo "11) 檢查更新"
  echo "12) 更新並重啟服務"
  echo "13) 啟用自動更新（每日）"
  echo "14) 停用自動更新"
  echo "15) 查看自動更新狀態"
  read -r -p "選擇動作 [1-15]: " choice
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
    11) check_update_status ;;
    12) perform_update ;;
    13) auto_update_enable ;;
    14) auto_update_disable ;;
    15) auto_update_status ;;
    *) err "無效選項"; exit 1 ;;
  esac
}

main() {
  local cmd="${1:-menu}"
  case "$cmd" in
    install) install_service ;;
    set-key) set_key ;;
    check-update) check_update_status ;;
    update) perform_update ;;
    auto-update-enable) auto_update_enable ;;
    auto-update-disable) auto_update_disable ;;
    auto-update-status) auto_update_status ;;
    start) start_service ;;
    stop) stop_service ;;
    restart) restart_service ;;
    status) status_service ;;
    enable) enable_service ;;
    disable) disable_service ;;
    logs) shift || true; logs_service "$1" ;;
    uninstall) uninstall_service ;;
    updater-task) perform_update ;;
    menu) menu ;;
    -h|--help) usage ;;
    *) err "未知指令：$cmd"; usage; exit 1 ;;
  esac
}

main "$@"
