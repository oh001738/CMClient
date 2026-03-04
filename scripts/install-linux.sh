#!/usr/bin/env bash

# One-click Linux installer for CMClient with Node.js 22 via nvm.
set -euo pipefail

NODE_VERSION="${NODE_VERSION:-22}"
NVM_VERSION="${NVM_VERSION:-v0.39.7}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

log() {
  printf '[install] %s\n' "$*"
}

err() {
  printf '[install][error] %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage: scripts/install-linux.sh

Environment variables:
  NODE_VERSION   Node.js version to install (default: 22)
  NVM_VERSION    nvm version to install (default: v0.39.7)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

sudo_prefix() {
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    echo ""
  elif command -v sudo >/dev/null 2>&1; then
    echo "sudo"
  else
    err "sudo is required to install system packages. Please run as root or install sudo."
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

install_system_packages() {
  local pm="$1"
  local sudo_cmd="$2"

  case "$pm" in
    apt)
      $sudo_cmd apt-get update
      $sudo_cmd apt-get install -y curl ca-certificates git build-essential python3
      ;;
    dnf)
      $sudo_cmd dnf install -y curl ca-certificates git gcc-c++ make python3
      ;;
    yum)
      $sudo_cmd yum install -y curl ca-certificates git gcc-c++ make python3
      ;;
    pacman)
      $sudo_cmd pacman -Sy --noconfirm --needed base-devel git curl ca-certificates python3
      ;;
    zypper)
      $sudo_cmd zypper --non-interactive refresh
      $sudo_cmd zypper --non-interactive install git curl ca-certificates gcc-c++ make python3
      ;;
    *)
      err "Unsupported package manager. Please install curl, git, build tools, and python3 manually."
      exit 1
      ;;
  esac
}

ensure_prerequisites() {
  if command -v curl >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    log "System prerequisites already installed."
    return
  fi

  local pm
  pm="$(detect_package_manager)"
  if [ -z "$pm" ]; then
    err "Could not detect a supported package manager. Please install curl, git, build tools, and python3 manually."
    exit 1
  fi

  local sudo_cmd
  sudo_cmd="$(sudo_prefix)"
  log "Installing system prerequisites using $pm..."
  install_system_packages "$pm" "$sudo_cmd"
}

load_nvm() {
  export NVM_DIR
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1090
    . "$NVM_DIR/nvm.sh"
    return 0
  fi
  return 1
}

ensure_nvm() {
  if load_nvm; then
    return
  fi

  log "Installing nvm $NVM_VERSION..."
  curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash

  if ! load_nvm; then
    err "Failed to load nvm after installation."
    exit 1
  fi
}

ensure_node() {
  local current_major=""
  if command -v node >/dev/null 2>&1; then
    current_major="$(node -v | sed 's/^v//' | cut -d. -f1)"
  fi

  if [ -n "$current_major" ] && [ "$current_major" -ge 22 ]; then
    log "Detected Node.js $(node -v); skipping Node installation."
    return
  fi

  log "Installing Node.js $NODE_VERSION via nvm..."
  ensure_nvm
  nvm install "$NODE_VERSION" --latest-npm
  nvm alias default "$NODE_VERSION"
  nvm use "$NODE_VERSION"
}

install_node_dependencies() {
  log "Installing npm dependencies in $PROJECT_ROOT..."
  cd "$PROJECT_ROOT"
  npm install
}

main() {
  ensure_prerequisites
  ensure_node
  install_node_dependencies
  log "Done. You can start the CLI with: node src/index.js --help"
}

main "$@"
