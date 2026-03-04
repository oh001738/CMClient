#!/usr/bin/env bash

# Bootstrap installer: clone or update CMClient, install deps, and run service setup.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/toodi0418/CMClient.git}"
BRANCH="${TMAG_BRANCH:-main}"
TARGET_DIR="${TMAG_DIR:-CMClient}"
INSTALL_SCRIPT="scripts/install-linux.sh"
SERVICE_SCRIPT="scripts/manage-service-linux.sh"

log() { printf '[bootstrap] %s\n' "$*"; }
err() { printf '[bootstrap][error] %s\n' "$*" >&2; }

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
  local sudo_cmd=""
  if [ "${EUID:-$(id -u)}" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
    sudo_cmd="sudo"
  fi
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
      err "無法偵測可用套件管理器，請手動安裝：$*"
      return 1
      ;;
  esac
}

ensure_git() {
  if command -v git >/dev/null 2>&1; then
    return
  fi
  log "找不到 git，嘗試自動安裝..."
  local pm
  pm="$(detect_package_manager)"
  if [ -n "$pm" ]; then
    install_packages "$pm" git curl ca-certificates || true
  fi
  if ! command -v git >/dev/null 2>&1; then
    err "仍找不到 git，請手動安裝後再試。"
    exit 1
  fi
}

clone_or_update_repo() {
  if [ -d "$TARGET_DIR/.git" ]; then
    log "偵測到既有倉庫 $TARGET_DIR，嘗試更新..."
    if git -C "$TARGET_DIR" rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then
      if git -C "$TARGET_DIR" diff --quiet --ignore-submodules -- && git -C "$TARGET_DIR" diff --cached --quiet --ignore-submodules --; then
        git -C "$TARGET_DIR" fetch origin "$BRANCH"
        git -C "$TARGET_DIR" checkout "$BRANCH" >/dev/null 2>&1 || true
        git -C "$TARGET_DIR" merge --ff-only "origin/$BRANCH" || log "FF 失敗，請手動檢查。"
      else
        log "工作目錄有未提交變更，跳過自動更新，沿用現有版本。"
      fi
    fi
  elif [ -d "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
    err "目錄 $TARGET_DIR 已存在且非 git 倉庫，請設 TMAG_DIR 指向其他路徑或清空該目錄。"
    exit 1
  else
    log "clone 倉庫到 $TARGET_DIR ..."
    git clone --branch "$BRANCH" "$REPO_URL" "$TARGET_DIR"
  fi
  git config --global --add safe.directory "$(cd "$TARGET_DIR" && pwd)" || true
}

run_installers() {
  cd "$TARGET_DIR"
  if [ ! -x "$INSTALL_SCRIPT" ] || [ ! -x "$SERVICE_SCRIPT" ]; then
    err "找不到必要腳本：$INSTALL_SCRIPT 或 $SERVICE_SCRIPT"
    exit 1
  fi
  bash "$INSTALL_SCRIPT"
  bash "$SERVICE_SCRIPT" install
}

main() {
  ensure_git
  clone_or_update_repo
  run_installers
  log "完成。服務已安裝，若需重設 API Key 或查看 log 請執行: bash $SERVICE_SCRIPT"
}

main "$@"
