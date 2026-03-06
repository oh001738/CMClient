#!/bin/bash
set -e

# --- 顏色設定 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { printf "${GREEN}[deploy]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
error() { printf "${RED}[error]${NC} %s\n" "$*" >&2; }

# --- 檢查環境 ---
if [[ $EUID -ne 0 ]]; then
   error "此腳本需要使用 sudo 權限執行。"
   exit 1
fi

if ! command -v docker &> /dev/null; then
    error "找不到 docker，請先安裝 Docker。"
    exit 1
fi

# --- 自我更新檢查 ---
check_self_update() {
    log "檢查部署腳本是否有更新..."
    if [ -d .git ]; then
        git fetch origin main >/dev/null        # 檢查本地檔案與遠端的 deploy.sh 是否不同 (不使用 HEAD 比較，避免重啟迴圈)
        if ! git diff --quiet origin/main -- deploy.sh; then
            warn "偵測到新版 deploy.sh，正在自動更新並重啟..."
            git checkout origin/main -- deploy.sh
            chmod +x "$0"  # 確保新下載的腳本擁有執行權限
            log "腳本已更新，重新啟動中..."
            exec "$0" "$@"
        fi
    fi
}

# --- 互動函式 ---
prompt_api_key() {
    local key=""
    while [[ -z "$key" ]]; do
        read -rp "請輸入 CallMesh API Key: " key
        [[ -z "$key" ]] && error "API Key 不可為空。"
    done
    echo "$key"
}

select_serial_device() {
    local devices=()
    for p in /dev/ttyACM* /dev/ttyUSB* /dev/ttyS* /dev/ttyAMA*; do
        [[ -e "$p" ]] && devices+=("$p")
    done

    if [[ ${#devices[@]} -eq 0 ]]; then
        warn "未偵測到常見的 Serial 裝置。"
        read -rp "請手動輸入裝置路徑 [例如 /dev/ttyACM0]: " selected
        echo "${selected:-/dev/ttyACM0}"
    else
        echo "偵測到以下 Serial 裝置：" >&2
        for i in "${!devices[@]}"; do
            echo "  $((i+1))) ${devices[$i]}" >&2
        done
        local choice
        read -rp "請選擇裝置編號 (預設 1): " choice
        choice=${choice:-1}
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#devices[@]} )); then
            echo "${devices[$((choice-1))]}"
        else
            echo "${devices[0]}"
        fi
    fi
}

# --- 執行自我更新 ---
check_self_update

# --- 主選單 ---
cat << "EOF"
  ____ ___  ____  _     _     ____  ____ 
 / ___|  \/  | | | |   | |   |  _ \/ ___|
| |   | |\/| | | | |   | |   | |_) \___ \
| |___| |  | | | | |___| |___|  __/ ___) |
 \____|_|  |_|_|_|_____|_____|_|   |____/ 
                                          
EOF

echo "------------------------------------------"
echo "1) 全新安裝 (清理舊資料 + 引導設定 .env + 重新編譯)"
echo "2) 更新程式碼 (同步最新 git + 重新編譯，保留資料)"
echo "3) 快速重啟 (僅套用 .env 變更，不更新程式，跳過編譯)"
echo "4) 清空應用資料 (僅刪除 Volumes，保留 .env 設定)"
echo "5) 取消"
read -rp "請選擇操作 [1-5]: " main_choice

NEED_GIT_SYNC=false
NEED_BUILD=false
NEED_RESTART=true

case $main_choice in
    1)
        log "進入全新安裝流程 (清理資料 + 設定環境)..."
        NEED_GIT_SYNC=true
        NEED_BUILD=true
        
        if [[ -f docker-compose.yml ]]; then
            warn "正在移除舊有的容器與磁碟卷 (Volumes)..."
            docker compose down -v --remove-orphans || true
        fi
        
        API_KEY=$(prompt_api_key)
        echo "請選擇 Meshtastic 連線模式："
        echo "  1) TCP 模式"
        echo "  2) Serial 模式"
        read -rp "選擇 [1-2]: " mode_choice
        
        if [[ "$mode_choice" == "2" ]]; then
            DEVICE_PATH=$(select_serial_device)
            HOST_VAL="serial:${DEVICE_PATH}"
            SERIAL_VAL="${DEVICE_PATH}"
        else
            read -rp "請輸入 Meshtastic IP/Host [預設 meshtastic.local]: " tcp_host
            HOST_VAL="${tcp_host:-meshtastic.local}"
            SERIAL_VAL="/dev/ttyACM0"
        fi

        cat > .env <<EOL
CALLMESH_API_KEY=${API_KEY}
SERIAL_DEVICE=${SERIAL_VAL}
MESHTASTIC_HOST=${HOST_VAL}
MESHTASTIC_PORT=4403
TMAG_WEB_PORT=7080
TMAG_WEB_DASHBOARD=1
TMAG_TIMEZONE=Asia/Taipei
TENMAN_DISABLE=1
AUTO_UPDATE=0
EOL
        log ".env 檔案已設定。"
        ;;
    2)
        log "進入更新程式碼流程 (保留現有資料)..."
        NEED_GIT_SYNC=true
        NEED_BUILD=true
        ;;
    3)
        log "進入快速重啟流程 (僅套用設定變更)..."
        NEED_GIT_SYNC=false
        NEED_BUILD=false
        ;;
    4)
        warn "警告：這將會永久刪除所有存儲在 Volume 中的應用資料 (monitor.json, logs 等)。"
        read -rp "確定要繼續嗎？ (y/N): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            log "正在清理資料..."
            docker compose down -v --remove-orphans || true
            log "資料已清空。"
            NEED_GIT_SYNC=false
            NEED_BUILD=false
        else
            log "已取消清理動作。"
            exit 0
        fi
        ;;
    *)
        log "已取消操作。"
        exit 0
        ;;
esac

# --- 執行任務 ---
if [ "$NEED_GIT_SYNC" = true ]; then
    log "同步程式碼 (git fetch & reset)..."
    git fetch --all
    git reset --hard origin/main
fi

if [ "$NEED_BUILD" = true ]; then
    log "正在重新建置 Docker Image..."
    docker compose up -d --build callmesh-client
else
    log "正在啟動/重啟服務 (不重新建置)..."
    docker compose up -d callmesh-client
fi

log "清理舊的 Docker 映像檔..."
docker image prune -f

echo "------------------------------------------"
log "✅ 操作完成！"
echo "您可以執行 'docker compose logs -f callmesh-client' 查看運行狀況。"
echo "------------------------------------------"
