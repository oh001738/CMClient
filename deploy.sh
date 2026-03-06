#!/bin/bash
set -e

# --- 顏色設定 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

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
    # 搜尋常見的 Serial 裝置
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

# --- 主程式 ---
cat << "EOF"
  ____ ___  ____  _     _     ____  ____ 
 / ___|  \/  | | | |   | |   |  _ \/ ___|
| |   | |\/| | | | |   | |   | |_) \___ \
| |___| |  | | | | |___| |___|  __/ ___) |
 \____|_|  |_|_|_|_____|_____|_|   |____/ 
                                          
EOF

echo "------------------------------------------"
echo "1) 全新安裝 (引導設定 .env 並啟動)"
echo "2) 僅重啟服務 (修改 .env 後套用)"
echo "3) 取消"
read -rp "請選擇操作 [1-3]: " main_choice

case $main_choice in
    1)
        log "進入全新安裝流程 (將會清理舊有的容器與資料)..."

        # 0. 清理舊有內容
        if [[ -f docker-compose.yml ]]; then
            warn "正在移除舊有的容器與磁碟卷 (Volumes)..."
            docker compose down -v --remove-orphans || true
        fi
        
        # 1. 取得 API Key
        API_KEY=$(prompt_api_key)
        
        # 2. 選擇模式
        echo "請選擇 Meshtastic 連線模式："
        echo "  1) TCP 模式 (透過網路)"
        echo "  2) Serial 模式 (透過 USB 序列埠)"
        read -rp "選擇 [1-2]: " mode_choice
        
        if [[ "$mode_choice" == "2" ]]; then
            DEVICE_PATH=$(select_serial_device)
            HOST_VAL="serial:${DEVICE_PATH}"
            SERIAL_VAL="${DEVICE_PATH}"
            log "已選擇 Serial 模式: ${DEVICE_PATH}"
        else
            read -rp "請輸入 Meshtastic IP/Host [預設 meshtastic.local]: " tcp_host
            HOST_VAL="${tcp_host:-meshtastic.local}"
            SERIAL_VAL="/dev/ttyACM0" # 留作預設值
            log "已選擇 TCP 模式: ${HOST_VAL}"
        fi

        # 3. 寫入 .env
        log "正在產生 .env 檔案..."
        cat > .env <<EOL
# 必填：CallMesh API Key
CALLMESH_API_KEY=${API_KEY}

# Serial 裝置路徑 (更換 USB 埠或是裝置時，只需修改此處)
SERIAL_DEVICE=${SERIAL_VAL}

# Meshtastic 節點連線參數
MESHTASTIC_HOST=${HOST_VAL}
MESHTASTIC_PORT=4403

# Web Dashboard 設定
TMAG_WEB_PORT=7080
TMAG_WEB_DASHBOARD=1
TMAG_TIMEZONE=Asia/Taipei

# 其他設定
TENMAN_DISABLE=1
AUTO_UPDATE=0
EOL
        log ".env 檔案已更新。"
        ;;
    2)
        log "準備重新啟動服務..."
        ;;
    *)
        log "已取消操作。"
        exit 0
        ;;
esac

# --- 執行部署 ---
log "同步程式碼 (git fetch & reset)..."
git fetch --all
git reset --hard origin/main

log "正在啟動 Docker 服務 (這可能需要一點時間來編譯環境)..."
docker compose down
docker compose up -d --build callmesh-client

log "清理舊的 Docker 映像檔..."
docker image prune -f

echo "------------------------------------------"
log "✅ 部署/重啟完成！"
echo "您可以執行 'docker compose logs -f callmesh-client' 查看運行狀況。"
echo "Web Dashboard 位址: http://<您的伺服器IP>:7080"
echo "------------------------------------------"
