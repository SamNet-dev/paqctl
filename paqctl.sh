#!/bin/bash
#
# ╔═══════════════════════════════════════════════════════════════════╗
# ║      PAQCTL - Paqet Manager v1.0.0                                ║
# ║                                                                   ║
# ║  One-click setup for Paqet raw-socket proxy                       ║
# ║                                                                   ║
# ║  * Installs paqet binary + libpcap                                ║
# ║  * Auto-detects network config                                    ║
# ║  * Configures server or client mode                               ║
# ║  * Manages iptables rules                                         ║
# ║  * Auto-start on boot via systemd/OpenRC/SysVinit                 ║
# ║  * Easy management via CLI or interactive menu                    ║
# ║                                                                   ║
# ║  Paqet: https://github.com/SamNet-dev/paqctl                       ║
# ╚═══════════════════════════════════════════════════════════════════╝
#
# Usage:
# curl -sL https://raw.githubusercontent.com/SamNet-dev/paqctl/main/paqctl.sh | sudo bash
#
# Or: wget paqctl.sh && sudo bash paqctl.sh
#

set -eo pipefail

# Require bash
if [ -z "$BASH_VERSION" ]; then
    echo "Error: This script requires bash. Please run with: bash $0"
    exit 1
fi

VERSION="1.0.0"

# Pinned versions for stability (update these after testing new releases)
PAQET_VERSION_PINNED="v1.0.0-alpha.15"
XRAY_VERSION_PINNED="v26.2.4"
GFK_VERSION_PINNED="v1.0.0"

PAQET_REPO="hanselime/paqet"
PAQET_API_URL="https://api.github.com/repos/${PAQET_REPO}/releases/latest"
INSTALL_DIR="${INSTALL_DIR:-/opt/paqctl}"
BACKUP_DIR="$INSTALL_DIR/backups"
GFK_REPO="SamNet-dev/paqctl"
GFK_BRANCH="main"
GFK_RAW_URL="https://raw.githubusercontent.com/${GFK_REPO}/${GFK_BRANCH}/gfk"
GFK_DIR="$INSTALL_DIR/gfk"
MICROSOCKS_REPO="rofl0r/microsocks"
BACKEND="${BACKEND:-paqet}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

#═══════════════════════════════════════════════════════════════════════
# Utility Functions
#═══════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                  PAQCTL - Paqet Manager v${VERSION}                   ║"
    echo "║        Raw-socket encrypted proxy - bypass firewalls           ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

log_error() {
    echo -e "${RED}[✗]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_os() {
    OS="unknown"
    OS_VERSION="unknown"
    OS_FAMILY="unknown"
    HAS_SYSTEMD=false
    PKG_MANAGER="unknown"

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
        OS_VERSION="${VERSION_ID:-unknown}"
    elif [ -f /etc/redhat-release ]; then
        OS="rhel"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
    elif [ -f /etc/alpine-release ]; then
        OS="alpine"
    elif [ -f /etc/arch-release ]; then
        OS="arch"
    elif [ -f /etc/SuSE-release ] || [ -f /etc/SUSE-brand ]; then
        OS="opensuse"
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    fi

    case "$OS" in
        ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian)
            OS_FAMILY="debian"
            PKG_MANAGER="apt"
            ;;
        rhel|centos|fedora|rocky|almalinux|oracle|amazon|amzn)
            OS_FAMILY="rhel"
            if command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
            else
                PKG_MANAGER="yum"
            fi
            ;;
        arch|manjaro|endeavouros|garuda)
            OS_FAMILY="arch"
            PKG_MANAGER="pacman"
            ;;
        opensuse|opensuse-leap|opensuse-tumbleweed|sles)
            OS_FAMILY="suse"
            PKG_MANAGER="zypper"
            ;;
        alpine)
            OS_FAMILY="alpine"
            PKG_MANAGER="apk"
            ;;
        *)
            OS_FAMILY="unknown"
            PKG_MANAGER="unknown"
            ;;
    esac

    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        HAS_SYSTEMD=true
    fi

    log_info "Detected: $OS ($OS_FAMILY family), Package manager: $PKG_MANAGER"
}

install_package() {
    local package="$1"
    log_info "Installing $package..."

    case "$PKG_MANAGER" in
        apt)
            apt-get update -q 2>/dev/null || log_warn "apt-get update failed, attempting install anyway..."
            if apt-get install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        dnf)
            if dnf install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        yum)
            if yum install -y -q "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        pacman)
            if pacman -Sy --noconfirm "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        zypper)
            if zypper install -y -n "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        apk)
            if apk add --no-cache "$package"; then
                log_success "$package installed successfully"
            else
                log_error "Failed to install $package"
                return 1
            fi
            ;;
        *)
            log_warn "Unknown package manager. Please install $package manually."
            return 1
            ;;
    esac
}

check_dependencies() {
    if [ "$OS_FAMILY" = "alpine" ]; then
        if ! command -v bash &>/dev/null; then
            apk add --no-cache bash 2>/dev/null
        fi
    fi

    if ! command -v curl &>/dev/null; then
        install_package curl || log_warn "Could not install curl automatically"
    fi

    if ! command -v tar &>/dev/null; then
        install_package tar || log_warn "Could not install tar automatically"
    fi

    if ! command -v ip &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package iproute2 || log_warn "Could not install iproute2" ;;
            dnf|yum) install_package iproute || log_warn "Could not install iproute" ;;
            pacman) install_package iproute2 || log_warn "Could not install iproute2" ;;
            zypper) install_package iproute2 || log_warn "Could not install iproute2" ;;
            apk) install_package iproute2 || log_warn "Could not install iproute2" ;;
        esac
    fi

    if ! command -v tput &>/dev/null; then
        case "$PKG_MANAGER" in
            apt) install_package ncurses-bin || log_warn "Could not install ncurses-bin" ;;
            apk) install_package ncurses || log_warn "Could not install ncurses" ;;
            *) install_package ncurses || log_warn "Could not install ncurses" ;;
        esac
    fi

    # Firewall rules: use firewalld if active, otherwise iptables
    if _is_firewalld_active; then
        log_info "firewalld detected — will use firewall-cmd for rules"
    elif ! command -v iptables &>/dev/null; then
        log_info "Installing iptables..."
        case "$PKG_MANAGER" in
            apt) install_package iptables || log_warn "Could not install iptables - firewall rules may not work" ;;
            dnf|yum) install_package iptables || log_warn "Could not install iptables" ;;
            pacman) install_package iptables || log_warn "Could not install iptables" ;;
            zypper) install_package iptables || log_warn "Could not install iptables" ;;
            apk) install_package iptables || log_warn "Could not install iptables" ;;
            *) log_warn "Please install iptables manually for firewall rules to work" ;;
        esac
    fi

    # openssl is required for GFK certificate generation
    if ! command -v openssl &>/dev/null; then
        install_package openssl || log_warn "Could not install openssl"
    fi

    # libpcap is required by paqet
    install_libpcap
}

install_libpcap() {
    log_info "Checking for libpcap..."

    # Check if already available
    if ldconfig -p 2>/dev/null | grep -q libpcap; then
        log_success "libpcap already installed"
        return 0
    fi

    case "$PKG_MANAGER" in
        apt) install_package libpcap-dev ;;
        dnf|yum) install_package libpcap-devel ;;
        pacman) install_package libpcap ;;
        zypper) install_package libpcap-devel ;;
        apk) install_package libpcap-dev ;;
        *) log_warn "Please install libpcap manually for your distribution"; return 1 ;;
    esac

    # Fedora/RHEL: ensure libpcap.so.1 symlink exists (package may only install versioned .so)
    if [ "$PKG_MANAGER" = "dnf" ] || [ "$PKG_MANAGER" = "yum" ]; then
        if ! ldconfig -p 2>/dev/null | grep -q 'libpcap\.so\.1 '; then
            local _pcap_lib
            _pcap_lib=$(find /usr/lib64 /usr/lib /lib64 /lib -name 'libpcap.so.*' -type f 2>/dev/null | head -1)
            if [ -n "$_pcap_lib" ]; then
                local _libdir
                _libdir=$(dirname "$_pcap_lib")
                if [ ! -e "${_libdir}/libpcap.so.1" ]; then
                    log_info "Creating libpcap.so.1 symlink for Fedora/RHEL compatibility"
                    ln -sf "$_pcap_lib" "${_libdir}/libpcap.so.1"
                fi
                ldconfig 2>/dev/null || true
            fi
        fi
    fi
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7|armhf) echo "arm32" ;;
        *)
            log_error "Unsupported architecture: $arch"
            log_error "Paqet supports amd64, arm64, and arm32 only"
            exit 1
            ;;
    esac
}

#═══════════════════════════════════════════════════════════════════════
# Input Validation Functions
#═══════════════════════════════════════════════════════════════════════

_validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

_validate_ip() {
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS='.'; set -- $1
    [ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ]
}

_validate_mac() { [[ "$1" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; }

_validate_iface() { [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] && [ ${#1} -le 64 ]; }

_validate_version_tag() {
    [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]]
}

#═══════════════════════════════════════════════════════════════════════
# Binary Download & Install
#═══════════════════════════════════════════════════════════════════════

# Retry helper with exponential backoff for API requests
_curl_with_retry() {
    local url="$1"
    local max_attempts="${2:-3}"
    local attempt=1
    local delay=2
    local response=""
    while [ $attempt -le $max_attempts ]; do
        response=$(curl -s --max-time 15 "$url" 2>/dev/null)
        if [ -n "$response" ]; then
            # Check for rate limit response
            if echo "$response" | grep -q '"message".*rate limit'; then
                log_warn "GitHub API rate limited, waiting ${delay}s (attempt $attempt/$max_attempts)"
                sleep $delay
                delay=$((delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
            echo "$response"
            return 0
        fi
        [ $attempt -lt $max_attempts ] && sleep $delay
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
    return 1
}

get_latest_version() {
    local response
    response=$(_curl_with_retry "$PAQET_API_URL" 3)
    if [ -z "$response" ]; then
        log_error "Failed to query GitHub API after retries"
        return 1
    fi
    local tag
    tag=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')
    if [ -z "$tag" ]; then
        log_error "Could not determine latest paqet version"
        return 1
    fi
    if ! _validate_version_tag "$tag"; then
        log_error "Invalid version tag format: $tag"
        return 1
    fi
    echo "$tag"
}

download_paqet() {
    local version="$1"
    local arch
    arch=$(detect_arch)
    local os_name="linux"
    local ext="tar.gz"
    local filename="paqet-${os_name}-${arch}-${version}.${ext}"
    local url="https://github.com/${PAQET_REPO}/releases/download/${version}/${filename}"

    log_info "Downloading paqet ${version} for ${os_name}/${arch}..."

    if ! mkdir -p "$INSTALL_DIR/bin"; then
        log_error "Failed to create directory $INSTALL_DIR/bin"
        return 1
    fi
    local tmp_file
    tmp_file=$(mktemp "/tmp/paqet-download-XXXXXXXX.${ext}") || { log_error "Failed to create temp file"; return 1; }

    # Try curl first, fallback to wget
    local download_ok=false
    if curl -sL --max-time 180 --retry 3 --retry-delay 5 --fail -o "$tmp_file" "$url" 2>/dev/null; then
        download_ok=true
    elif command -v wget &>/dev/null; then
        log_info "curl failed, trying wget..."
        rm -f "$tmp_file"
        if wget -q --timeout=180 --tries=3 -O "$tmp_file" "$url" 2>/dev/null; then
            download_ok=true
        fi
    fi

    if [ "$download_ok" != "true" ]; then
        log_error "Failed to download: $url"
        log_error "Try manual download: wget '$url' and place binary in $INSTALL_DIR/bin/"
        rm -f "$tmp_file"
        return 1
    fi

    # Validate download
    local fsize
    fsize=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || wc -c < "$tmp_file" 2>/dev/null || echo 0)
    if [ "$fsize" -lt 1000 ]; then
        log_error "Downloaded file is too small ($fsize bytes). Download may have failed."
        rm -f "$tmp_file"
        return 1
    fi

    # Extract
    log_info "Extracting..."
    local tmp_extract
    tmp_extract=$(mktemp -d "/tmp/paqet-extract-XXXXXXXX") || { log_error "Failed to create temp file"; return 1; }
    if ! tar -xzf "$tmp_file" -C "$tmp_extract" 2>/dev/null; then
        log_error "Failed to extract archive"
        rm -f "$tmp_file"
        rm -rf "$tmp_extract"
        return 1
    fi

    # Find the binary in extracted files
    local binary_name="paqet_${os_name}_${arch}"
    local found_binary=""
    found_binary=$(find "$tmp_extract" -name "$binary_name" -type f 2>/dev/null | head -1)
    if [ -z "$found_binary" ]; then
        # Try alternate name patterns
        found_binary=$(find "$tmp_extract" -name "paqet*" -type f -executable 2>/dev/null | head -1)
    fi
    if [ -z "$found_binary" ]; then
        found_binary=$(find "$tmp_extract" -name "paqet*" -type f 2>/dev/null | head -1)
    fi

    if [ -z "$found_binary" ]; then
        log_error "Could not find paqet binary in archive"
        rm -f "$tmp_file"
        rm -rf "$tmp_extract"
        return 1
    fi

    # Stop paqet if running to avoid "Text file busy" error
    if pgrep -f "$INSTALL_DIR/bin/paqet" &>/dev/null; then
        log_info "Stopping paqet to update binary..."
        pkill -f "$INSTALL_DIR/bin/paqet" 2>/dev/null || true
        sleep 1
    fi

    if ! cp "$found_binary" "$INSTALL_DIR/bin/paqet"; then
        log_error "Failed to copy paqet binary to $INSTALL_DIR/bin/"
        rm -f "$tmp_file"
        rm -rf "$tmp_extract"
        return 1
    fi
    if ! chmod +x "$INSTALL_DIR/bin/paqet"; then
        log_error "Failed to make paqet binary executable"
        return 1
    fi

    # Copy example configs if they exist
    find "$tmp_extract" -name "*.yaml.example" -exec cp {} "$INSTALL_DIR/" \; 2>/dev/null || true

    rm -f "$tmp_file"
    rm -rf "$tmp_extract"

    # Verify binary runs
    if "$INSTALL_DIR/bin/paqet" version &>/dev/null; then
        log_success "paqet ${version} installed successfully"
    else
        log_warn "paqet binary installed but version check failed (may need libpcap)"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Network Auto-Detection
#═══════════════════════════════════════════════════════════════════════

detect_network() {
    log_info "Auto-detecting network configuration..."

    # Default interface - handle both standard "via X dev Y" and OpenVZ "dev Y scope link" formats
    # Standard: "default via 192.168.1.1 dev eth0" -> $5 = eth0
    # OpenVZ:   "default dev venet0 scope link"   -> $3 = venet0
    local _route_line
    _route_line=$(ip route show default 2>/dev/null | head -1)
    if [[ "$_route_line" == *" via "* ]]; then
        # Standard format with gateway
        DETECTED_IFACE=$(echo "$_route_line" | awk '{print $5}')
    elif [[ "$_route_line" == *" dev "* ]]; then
        # OpenVZ/direct format without gateway
        DETECTED_IFACE=$(echo "$_route_line" | awk '{print $3}')
    fi

    # Validate detected interface exists
    if [ -n "$DETECTED_IFACE" ] && ! ip link show "$DETECTED_IFACE" &>/dev/null; then
        DETECTED_IFACE=""
    fi

    if [ -z "$DETECTED_IFACE" ]; then
        # Skip loopback, docker, veth, bridge, and other virtual interfaces
        # Note: grep -v returns exit 1 if no matches, so we add || true for pipefail
        DETECTED_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{gsub(/ /,"",$2); print $2}' | { grep -vE '^(lo|docker[0-9]|br-|veth|virbr|tun|tap|wg)' || true; } | head -1)
    fi

    # Local IP - wrap entire pipeline to prevent pipefail exit
    if [ -n "$DETECTED_IFACE" ]; then
        # Note: wrap in subshell with || true to handle cases where interface is invalid or has no IP
        DETECTED_IP=$( (ip -4 addr show "$DETECTED_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | { grep -o '[0-9.]*' || true; } | head -1) || true )
    fi
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -z "$DETECTED_IP" ] && DETECTED_IP=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    fi

    # Gateway IP - only present in standard "via X" format, not in OpenVZ
    if [[ "$_route_line" == *" via "* ]]; then
        DETECTED_GATEWAY=$(echo "$_route_line" | awk '{print $3}')
    else
        DETECTED_GATEWAY=""
    fi

    # Gateway MAC
    DETECTED_GW_MAC=""
    if [ -n "$DETECTED_GATEWAY" ]; then
        # Try ip neigh first (most reliable on Linux)
        DETECTED_GW_MAC=$(ip neigh show "$DETECTED_GATEWAY" 2>/dev/null | awk '/lladdr/{print $5; exit}')
        if [ -z "$DETECTED_GW_MAC" ]; then
            # Trigger ARP resolution
            ping -c 1 -W 2 "$DETECTED_GATEWAY" &>/dev/null || true
            sleep 1
            DETECTED_GW_MAC=$(ip neigh show "$DETECTED_GATEWAY" 2>/dev/null | awk '/lladdr/{print $5; exit}')
        fi
        if [ -z "$DETECTED_GW_MAC" ] && command -v arp &>/dev/null; then
            # Fallback: parse arp output looking for MAC pattern
            # Note: grep returns exit 1 if no matches, so we add || true for pipefail
            DETECTED_GW_MAC=$(arp -n "$DETECTED_GATEWAY" 2>/dev/null | { grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' || true; } | head -1)
        fi
    fi

    log_info "Interface: ${DETECTED_IFACE:-unknown}"
    log_info "Local IP:  ${DETECTED_IP:-unknown}"
    log_info "Gateway:   ${DETECTED_GATEWAY:-unknown}"
    log_info "GW MAC:    ${DETECTED_GW_MAC:-unknown}"
}

#═══════════════════════════════════════════════════════════════════════
# Configuration Wizard
#═══════════════════════════════════════════════════════════════════════

run_config_wizard() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  PAQCTL CONFIGURATION WIZARD${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Backend selection
    echo -e "${BOLD}Select backend:${NC}"
    echo "  1. paqet       (Go/KCP, built-in SOCKS5, single binary)"
    echo "  2. gfw-knocker (Python/QUIC, port forwarding + SOCKS5)"
    echo ""
    local backend_choice
    read -p "  Enter choice [1/2]: " backend_choice < /dev/tty || true
    case "$backend_choice" in
        2) BACKEND="gfw-knocker" ;;
        *) BACKEND="paqet" ;;
    esac
    echo ""
    log_info "Selected backend: $BACKEND"
    echo ""

    # Role selection
    echo -e "${BOLD}Select role:${NC}"
    echo "  1. Server  (accept connections from clients)"
    echo "  2. Client  (connect to a server, provides SOCKS5 proxy)"
    echo ""
    local role_choice
    read -p "  Enter choice [1/2]: " role_choice < /dev/tty || true
    case "$role_choice" in
        1) ROLE="server" ;;
        2) ROLE="client" ;;
        *)
            log_warn "Invalid choice. Defaulting to server."
            ROLE="server"
            ;;
    esac
    echo ""
    log_info "Selected role: $ROLE"

    if [ "$BACKEND" = "paqet" ]; then
        _wizard_paqet
    else
        _wizard_gfk
    fi

    # Save settings
    save_settings
}

_wizard_paqet() {
    # Auto-detect network
    detect_network
    echo ""

    # Confirm/override interface
    echo -e "${BOLD}Network interface${NC} [${DETECTED_IFACE:-eth0}]:"
    read -p "  Interface: " input < /dev/tty || true
    IFACE="${input:-$DETECTED_IFACE}"
    IFACE="${IFACE:-eth0}"
    if ! _validate_iface "$IFACE"; then
        log_warn "Invalid interface name. Using eth0."
        IFACE="eth0"
    fi

    # Confirm/override local IP
    echo -e "${BOLD}Local IP${NC} [${DETECTED_IP:-auto}]:"
    read -p "  IP: " input < /dev/tty || true
    LOCAL_IP="${input:-$DETECTED_IP}"
    if [ -n "$LOCAL_IP" ] && ! _validate_ip "$LOCAL_IP"; then
        log_warn "Invalid IP format. Using detected IP."
        LOCAL_IP="$DETECTED_IP"
    fi

    # Confirm/override gateway MAC
    echo -e "${BOLD}Gateway MAC address${NC} [${DETECTED_GW_MAC:-auto}]:"
    read -p "  MAC: " input < /dev/tty || true
    GW_MAC="${input:-$DETECTED_GW_MAC}"

    if [ -z "$GW_MAC" ] || ! _validate_mac "$GW_MAC"; then
        if [ -n "$GW_MAC" ]; then
            log_warn "Invalid MAC format detected."
        else
            log_error "Could not detect gateway MAC address."
        fi
        log_error "Please enter it manually (format: aa:bb:cc:dd:ee:ff)"
        read -p "  Gateway MAC: " GW_MAC < /dev/tty || true
        if [ -z "$GW_MAC" ] || ! _validate_mac "$GW_MAC"; then
            log_error "Valid gateway MAC is required for paqet to function."
            exit 1
        fi
    fi

    if [ "$ROLE" = "server" ]; then
        echo ""
        echo -e "${BOLD}Listen port${NC} [8443]:"
        read -p "  Port: " input < /dev/tty || true
        LISTEN_PORT="${input:-8443}"
        if ! [[ "$LISTEN_PORT" =~ ^[0-9]+$ ]] || [ "$LISTEN_PORT" -lt 1 ] || [ "$LISTEN_PORT" -gt 65535 ]; then
            log_warn "Invalid port. Using default 8443."
            LISTEN_PORT=8443
        fi

        echo ""
        log_info "Generating encryption key..."
        ENCRYPTION_KEY=$("$INSTALL_DIR/bin/paqet" secret 2>/dev/null || true)
        if [ -z "$ENCRYPTION_KEY" ]; then
            log_warn "Could not auto-generate key. Using openssl fallback..."
            ENCRYPTION_KEY=$(openssl rand -base64 32 2>/dev/null | tr -d '=+/' | head -c 32 || true)
        fi
        if [ -z "$ENCRYPTION_KEY" ] || [ "${#ENCRYPTION_KEY}" -lt 16 ]; then
            log_error "Failed to generate a valid encryption key"
            return 1
        fi
        echo ""
        echo -e "${GREEN}${BOLD}  Encryption Key: ${ENCRYPTION_KEY}${NC}"
        echo ""
        echo -e "${YELLOW}  IMPORTANT: Save this key! Clients need it to connect.${NC}"
        echo ""
        SOCKS_PORT=""
    else
        echo ""
        echo -e "${BOLD}Remote server address${NC} (IP:PORT):"
        read -p "  Server: " REMOTE_SERVER < /dev/tty || true
        if [ -z "$REMOTE_SERVER" ]; then
            log_error "Remote server address is required."
            exit 1
        fi

        echo ""
        echo -e "${BOLD}Encryption key${NC} (from server setup):"
        read -p "  Key: " ENCRYPTION_KEY < /dev/tty || true
        if [ -z "$ENCRYPTION_KEY" ]; then
            log_error "Encryption key is required."
            exit 1
        fi

        echo ""
        echo -e "${BOLD}SOCKS5 listen port${NC} [1080]:"
        read -p "  SOCKS port: " input < /dev/tty || true
        SOCKS_PORT="${input:-1080}"
        if ! [[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] || [ "$SOCKS_PORT" -lt 1 ] || [ "$SOCKS_PORT" -gt 65535 ]; then
            log_warn "Invalid port. Using default 1080."
            SOCKS_PORT=1080
        fi
        LISTEN_PORT=""
    fi

    # Generate YAML config
    generate_config
}

_wizard_gfk() {
    if [ "$ROLE" = "server" ]; then
        # Server IP (this machine's public IP)
        detect_network
        echo ""
        echo -e "${BOLD}This server's public IP${NC} [${DETECTED_IP:-}]:"
        read -p "  IP: " input < /dev/tty || true
        GFK_SERVER_IP="${input:-$DETECTED_IP}"
        if [ -z "$GFK_SERVER_IP" ] || ! _validate_ip "$GFK_SERVER_IP"; then
            log_error "Valid server IP is required."
            exit 1
        fi

        # VIO TCP port (must be closed to OS, raw socket handles it)
        echo ""
        echo -e "${BOLD}VIO TCP port${NC} [45000] (raw socket port, must be blocked by firewall):"
        read -p "  Port: " input < /dev/tty || true
        GFK_VIO_PORT="${input:-45000}"
        if ! _validate_port "$GFK_VIO_PORT"; then
            log_warn "Invalid port. Using default 45000."
            GFK_VIO_PORT=45000
        fi

        # QUIC port
        echo ""
        echo -e "${BOLD}QUIC tunnel port${NC} [25000]:"
        read -p "  Port: " input < /dev/tty || true
        GFK_QUIC_PORT="${input:-25000}"
        if ! _validate_port "$GFK_QUIC_PORT"; then
            log_warn "Invalid port. Using default 25000."
            GFK_QUIC_PORT=25000
        fi

        # Auth code
        echo ""
        local auto_auth
        auto_auth=$(openssl rand -base64 16 2>/dev/null | tr -d '=+/' | head -c 16)
        echo -e "${BOLD}QUIC auth code${NC} [auto-generated]:"
        read -p "  Auth code: " input < /dev/tty || true
        GFK_AUTH_CODE="${input:-$auto_auth}"
        echo ""
        echo -e "${GREEN}${BOLD}  Auth Code: ${GFK_AUTH_CODE}${NC}"
        echo ""
        echo -e "${YELLOW}  IMPORTANT: Save this auth code! Clients need it to connect.${NC}"
        echo ""

        # Port mappings
        echo -e "${BOLD}TCP port mappings${NC} (local:remote, comma-separated) [14000:443]:"
        echo -e "  ${DIM}Example: 14000:443,15000:2096,16000:10809${NC}"
        read -p "  Mappings: " input < /dev/tty || true
        GFK_PORT_MAPPINGS="${input:-14000:443}"
        MICROSOCKS_PORT=""

    else
        # Client: server IP
        echo ""
        echo -e "${BOLD}Remote server IP${NC} (server's public IP):"
        read -p "  Server IP: " GFK_SERVER_IP < /dev/tty || true
        if [ -z "$GFK_SERVER_IP" ] || ! _validate_ip "$GFK_SERVER_IP"; then
            log_error "Valid server IP is required."
            exit 1
        fi

        # Server's VIO TCP port (what port the server is listening on)
        echo ""
        echo -e "${BOLD}Server's VIO TCP port${NC} [45000] (must match server config):"
        read -p "  Port: " input < /dev/tty || true
        GFK_VIO_PORT="${input:-45000}"
        if ! _validate_port "$GFK_VIO_PORT"; then
            log_warn "Invalid port. Using default 45000."
            GFK_VIO_PORT=45000
        fi

        # Local VIO client port (client's local binding)
        echo ""
        echo -e "${BOLD}Local VIO client port${NC} [40000]:"
        read -p "  Port: " input < /dev/tty || true
        GFK_VIO_CLIENT_PORT="${input:-40000}"
        if ! _validate_port "$GFK_VIO_CLIENT_PORT"; then
            log_warn "Invalid port. Using default 40000."
            GFK_VIO_CLIENT_PORT=40000
        fi

        # Server's QUIC port
        echo ""
        echo -e "${BOLD}Server's QUIC port${NC} [25000] (must match server config):"
        read -p "  Port: " input < /dev/tty || true
        GFK_QUIC_PORT="${input:-25000}"
        if ! _validate_port "$GFK_QUIC_PORT"; then
            log_warn "Invalid port. Using default 25000."
            GFK_QUIC_PORT=25000
        fi

        # Local QUIC client port
        echo ""
        echo -e "${BOLD}Local QUIC client port${NC} [20000]:"
        read -p "  Port: " input < /dev/tty || true
        GFK_QUIC_CLIENT_PORT="${input:-20000}"
        if ! _validate_port "$GFK_QUIC_CLIENT_PORT"; then
            log_warn "Invalid port. Using default 20000."
            GFK_QUIC_CLIENT_PORT=20000
        fi

        # Auth code (from server)
        echo ""
        echo -e "${BOLD}QUIC auth code${NC} (from server setup):"
        read -p "  Auth code: " GFK_AUTH_CODE < /dev/tty || true
        if [ -z "$GFK_AUTH_CODE" ]; then
            log_error "Auth code is required."
            exit 1
        fi

        # Port mappings (must match server)
        echo ""
        echo -e "${BOLD}TCP port mappings${NC} (must match server) [14000:443]:"
        read -p "  Mappings: " input < /dev/tty || true
        GFK_PORT_MAPPINGS="${input:-14000:443}"
    fi

    # Generate GFK config
    generate_gfk_config
}

generate_config() {
    log_info "Generating paqet configuration..."

    # Validate required fields
    if [ -z "$IFACE" ] || [ -z "$LOCAL_IP" ] || [ -z "$GW_MAC" ] || [ -z "$ENCRYPTION_KEY" ]; then
        log_error "Missing required configuration fields (interface, ip, gateway_mac, or secret)"
        return 1
    fi
    if [ "$ROLE" = "server" ]; then
        if [ -z "$LISTEN_PORT" ]; then log_error "Missing listen port"; return 1; fi
    else
        if [ -z "$REMOTE_SERVER" ] || [ -z "$SOCKS_PORT" ]; then
            log_error "Missing server address or SOCKS port"
            return 1
        fi
        local _rs_ip="${REMOTE_SERVER%:*}" _rs_port="${REMOTE_SERVER##*:}"
        if ! _validate_ip "$_rs_ip" || ! _validate_port "$_rs_port"; then
            log_error "Server address must be valid IP:PORT (e.g. 1.2.3.4:8443)"
            return 1
        fi
    fi

    # Escape YAML special characters to prevent injection
    _escape_yaml() {
        local s="$1"
        # If value contains special chars, quote it
        if [[ "$s" =~ [:\#\[\]{}\"\'\|\>\<\&\*\!\%\@\`] ]] || [[ "$s" =~ ^[[:space:]] ]] || [[ "$s" =~ [[:space:]]$ ]]; then
            s="${s//\\/\\\\}"  # Escape backslashes
            s="${s//\"/\\\"}"  # Escape double quotes
            printf '"%s"' "$s"
        else
            printf '%s' "$s"
        fi
    }

    # Ensure install directory exists
    mkdir -p "$INSTALL_DIR" || { log_error "Failed to create $INSTALL_DIR"; return 1; }

    local tmp_conf
    tmp_conf=$(mktemp "$INSTALL_DIR/config.yaml.XXXXXXXX") || { log_error "Failed to create temp file"; return 1; }
    # Set permissions on temp file before writing (fixes race condition)
    chmod 600 "$tmp_conf" 2>/dev/null

    (
    umask 077
    local _y_iface _y_ip _y_mac _y_key _y_server _y_port
    _y_iface=$(_escape_yaml "$IFACE")
    _y_ip=$(_escape_yaml "$LOCAL_IP")
    _y_mac=$(_escape_yaml "$GW_MAC")
    _y_key=$(_escape_yaml "$ENCRYPTION_KEY")
    # Build TCP flags YAML array (default: ["PA"])
    local _tcp_local_flags _tcp_remote_flags
    _tcp_local_flags=$(echo "${PAQET_TCP_LOCAL_FLAG:-PA}" | sed 's/,/", "/g; s/.*/["&"]/')
    _tcp_remote_flags=$(echo "${PAQET_TCP_REMOTE_FLAG:-PA}" | sed 's/,/", "/g; s/.*/["&"]/')

    if [ "$ROLE" = "server" ]; then
        cat > "$tmp_conf" << EOF
role: "server"

log:
  level: "info"

listen:
  addr: ":${LISTEN_PORT}"

network:
  interface: "${_y_iface}"
  ipv4:
    addr: "${_y_ip}:${LISTEN_PORT}"
    router_mac: "${_y_mac}"
  tcp:
    local_flag: ${_tcp_local_flags}
    remote_flag: ${_tcp_remote_flags}

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "${_y_key}"
EOF
    else
        local _rs_ip="${REMOTE_SERVER%:*}" _rs_port="${REMOTE_SERVER##*:}"
        _y_server=$(_escape_yaml "$REMOTE_SERVER")
        cat > "$tmp_conf" << EOF
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:${SOCKS_PORT}"

network:
  interface: "${_y_iface}"
  ipv4:
    addr: "${_y_ip}:0"
    router_mac: "${_y_mac}"
  tcp:
    local_flag: ${_tcp_local_flags}
    remote_flag: ${_tcp_remote_flags}

server:
  addr: "${_y_server}"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "${_y_key}"
EOF
    fi
    )
    if ! mv "$tmp_conf" "$INSTALL_DIR/config.yaml"; then
        log_error "Failed to save configuration file"
        rm -f "$tmp_conf"
        return 1
    fi
    # Ensure final permissions (mv preserves source permissions on most systems)
    chmod 600 "$INSTALL_DIR/config.yaml" 2>/dev/null
    log_success "Configuration saved to $INSTALL_DIR/config.yaml"
}

save_settings() {
    # Preserve existing Telegram settings if present
    local _tg_token="" _tg_chat="" _tg_interval=6 _tg_enabled=false
    local _tg_alerts=true _tg_daily=true _tg_weekly=true _tg_label="" _tg_start_hour=0
    if [ -f "$INSTALL_DIR/settings.conf" ]; then
        # Safe settings loading without eval
        while IFS='=' read -r key value; do
            [[ "$key" =~ ^[A-Z_][A-Z_0-9]*$ ]] || continue
            # Remove surrounding quotes and sanitize value
            value="${value#\"}"; value="${value%\"}"
            # Validate value doesn't contain dangerous characters
            if [[ "$value" =~ [\`\$\(] ]]; then
                continue  # Skip potentially dangerous values
            fi
            case "$key" in
                TELEGRAM_BOT_TOKEN) _tg_token="$value" ;;
                TELEGRAM_CHAT_ID) _tg_chat="$value" ;;
                TELEGRAM_INTERVAL) [[ "$value" =~ ^[0-9]+$ ]] && _tg_interval="$value" ;;
                TELEGRAM_ENABLED) _tg_enabled="$value" ;;
                TELEGRAM_ALERTS_ENABLED) _tg_alerts="$value" ;;
                TELEGRAM_DAILY_SUMMARY) _tg_daily="$value" ;;
                TELEGRAM_WEEKLY_SUMMARY) _tg_weekly="$value" ;;
                TELEGRAM_SERVER_LABEL) _tg_label="$value" ;;
                TELEGRAM_START_HOUR) [[ "$value" =~ ^[0-9]+$ ]] && _tg_start_hour="$value" ;;
            esac
        done < <(grep '^[A-Z_][A-Z_0-9]*=' "$INSTALL_DIR/settings.conf")
    fi

    # Sanitize sensitive values - remove shell metacharacters and control chars
    _sanitize_value() {
        printf '%s' "$1" | tr -d '"$`\\'\''(){}[]<>|;&!\n\r\t'
    }
    local _safe_key; _safe_key=$(_sanitize_value "${ENCRYPTION_KEY:-}")
    local _safe_auth; _safe_auth=$(_sanitize_value "${GFK_AUTH_CODE:-}")
    local _tmp
    _tmp=$(mktemp "$INSTALL_DIR/settings.conf.XXXXXXXX") || { log_error "Failed to create temp file"; return 1; }
    (
    umask 077
    cat > "$_tmp" << EOF
BACKEND="${BACKEND:-paqet}"
ROLE="${ROLE}"
PAQET_VERSION="${PAQET_VERSION:-unknown}"
PAQCTL_VERSION="${VERSION}"
LISTEN_PORT="${LISTEN_PORT:-}"
SOCKS_PORT="${SOCKS_PORT:-}"
INTERFACE="${IFACE:-}"
LOCAL_IP="${LOCAL_IP:-}"
GATEWAY_MAC="${GW_MAC:-}"
ENCRYPTION_KEY="${_safe_key}"
PAQET_TCP_LOCAL_FLAG="${PAQET_TCP_LOCAL_FLAG:-PA}"
PAQET_TCP_REMOTE_FLAG="${PAQET_TCP_REMOTE_FLAG:-PA}"
REMOTE_SERVER="${REMOTE_SERVER:-}"
GFK_VIO_PORT="${GFK_VIO_PORT:-}"
GFK_VIO_CLIENT_PORT="${GFK_VIO_CLIENT_PORT:-}"
GFK_QUIC_PORT="${GFK_QUIC_PORT:-}"
GFK_QUIC_CLIENT_PORT="${GFK_QUIC_CLIENT_PORT:-}"
GFK_AUTH_CODE="${_safe_auth}"
GFK_PORT_MAPPINGS="${GFK_PORT_MAPPINGS:-}"
GFK_SOCKS_PORT="${GFK_SOCKS_PORT:-}"
GFK_SOCKS_VIO_PORT="${GFK_SOCKS_VIO_PORT:-}"
XRAY_PANEL_DETECTED="${XRAY_PANEL_DETECTED:-false}"
MICROSOCKS_PORT="${MICROSOCKS_PORT:-}"
GFK_SERVER_IP="${GFK_SERVER_IP:-}"
GFK_TCP_FLAGS="${GFK_TCP_FLAGS:-AP}"
TELEGRAM_BOT_TOKEN="${_tg_token}"
TELEGRAM_CHAT_ID="${_tg_chat}"
TELEGRAM_INTERVAL=${_tg_interval}
TELEGRAM_ENABLED=${_tg_enabled}
TELEGRAM_ALERTS_ENABLED=${_tg_alerts}
TELEGRAM_DAILY_SUMMARY=${_tg_daily}
TELEGRAM_WEEKLY_SUMMARY=${_tg_weekly}
TELEGRAM_SERVER_LABEL="${_tg_label}"
TELEGRAM_START_HOUR=${_tg_start_hour}
EOF
    )
    if ! mv "$_tmp" "$INSTALL_DIR/settings.conf"; then
        log_error "Failed to save settings"
        rm -f "$_tmp"
        return 1
    fi
    chmod 600 "$INSTALL_DIR/settings.conf" 2>/dev/null
    log_success "Settings saved"
}

#═══════════════════════════════════════════════════════════════════════
# Firewall Management
#═══════════════════════════════════════════════════════════════════════

_is_firewalld_active() {
    command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running
}

apply_iptables_rules() {
    local port="$1"
    if [ -z "$port" ]; then
        log_error "No port specified for iptables rules"
        return 1
    fi

    log_info "Applying firewall rules for port $port..."

    # firewalld path (Fedora/RHEL)
    if _is_firewalld_active; then
        firewall-cmd --direct --query-rule ipv4 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
        firewall-cmd --direct --add-rule ipv4 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
            { log_error "Failed to add PREROUTING NOTRACK rule via firewalld"; return 1; }
        firewall-cmd --direct --query-rule ipv4 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
        firewall-cmd --direct --add-rule ipv4 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
            { log_error "Failed to add OUTPUT NOTRACK rule via firewalld"; return 1; }
        firewall-cmd --direct --query-rule ipv4 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
        firewall-cmd --direct --add-rule ipv4 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
            { log_error "Failed to add RST DROP rule via firewalld"; return 1; }
        log_success "IPv4 firewalld rules applied"
        # IPv6
        firewall-cmd --direct --add-rule ipv6 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv6 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv6 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        persist_iptables_rules
        return 0
    fi

    # iptables path (Debian/Ubuntu/Arch/etc.)
    modprobe iptable_raw 2>/dev/null || true
    modprobe iptable_mangle 2>/dev/null || true

    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        log_warn "ufw is active — ensure port $port/tcp is allowed: sudo ufw allow $port/tcp"
    fi

    local TAG="paqctl"

    if iptables -t raw -C PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null && \
       iptables -t raw -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null && \
       iptables -t mangle -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null; then
        log_info "iptables rules already in place"
    else
        iptables -t raw -C PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
        iptables -t raw -A PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || {
            log_error "Failed to add PREROUTING NOTRACK rule"
            return 1
        }
        iptables -t raw -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
        iptables -t raw -A OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || {
            log_error "Failed to add OUTPUT NOTRACK rule"
            return 1
        }
        iptables -t mangle -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || \
        iptables -t mangle -A OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || {
            log_error "Failed to add RST DROP rule"
            return 1
        }
        log_success "IPv4 iptables rules applied"
    fi

    if command -v ip6tables &>/dev/null; then
        local _ipv6_ok=true
        ip6tables -t raw -C PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
            ip6tables -t raw -A PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || _ipv6_ok=false
        ip6tables -t raw -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
            ip6tables -t raw -A OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || _ipv6_ok=false
        ip6tables -t mangle -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || \
            ip6tables -t mangle -A OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || _ipv6_ok=false
        if [ "$_ipv6_ok" = true ]; then
            log_success "IPv6 iptables rules applied"
        else
            log_warn "Some IPv6 iptables rules failed (IPv6 may not be available)"
        fi
    fi

    # Persist rules
    persist_iptables_rules
}

remove_iptables_rules() {
    local port="$1"
    if [ -z "$port" ]; then return 0; fi

    log_info "Removing firewall rules for port $port..."

    # firewalld path
    if _is_firewalld_active; then
        firewall-cmd --direct --remove-rule ipv4 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 filter INPUT 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 filter OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        # IPv6
        firewall-cmd --direct --remove-rule ipv6 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv6 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv6 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv6 filter INPUT 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv6 filter OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        log_success "firewalld rules removed"
        return 0
    fi

    # iptables path
    local TAG="paqctl"
    iptables -t raw -D PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
    iptables -t raw -D OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || true
    iptables -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || true
    iptables -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || true
    iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    if command -v ip6tables &>/dev/null; then
        ip6tables -t raw -D PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
        ip6tables -t raw -D OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
        ip6tables -t mangle -D OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || true
        ip6tables -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || true
        ip6tables -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || true
        ip6tables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
    fi
    log_success "iptables rules removed"
}

persist_iptables_rules() {
    if _is_firewalld_active; then
        firewall-cmd --runtime-to-permanent 2>/dev/null || true
        return 0
    fi
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &>/dev/null; then
        if [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            command -v ip6tables-save &>/dev/null && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        elif [ -f /etc/debian_version ] && [ ! -d /etc/iptables ]; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            command -v ip6tables-save &>/dev/null && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        elif [ -d /etc/sysconfig ]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            command -v ip6tables-save &>/dev/null && ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
        fi
    fi
}

check_iptables_rules() {
    local port="$1"
    if [ -z "$port" ]; then return 1; fi

    local ok=true

    if _is_firewalld_active; then
        firewall-cmd --direct --query-rule ipv4 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || ok=false
        firewall-cmd --direct --query-rule ipv4 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || ok=false
        firewall-cmd --direct --query-rule ipv4 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || ok=false
    else
        local TAG="paqctl"
        iptables -t raw -C PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || ok=false
        iptables -t raw -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || ok=false
        iptables -t mangle -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || ok=false
    fi

    if [ "$ok" = true ]; then
        return 0
    else
        return 1
    fi
}

#═══════════════════════════════════════════════════════════════════════
# GFW-knocker Backend Functions
#═══════════════════════════════════════════════════════════════════════

install_python_deps() {
    log_info "Installing Python dependencies for GFW-knocker..."
    if ! command -v python3 &>/dev/null; then
        install_package python3
    fi
    # Ensure python3 version >= 3.10
    local pyver
    pyver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
    local pymajor pyminor
    pymajor=$(echo "$pyver" | cut -d. -f1)
    pyminor=$(echo "$pyver" | cut -d. -f2)
    if [ "$pymajor" -lt 3 ] || { [ "$pymajor" -eq 3 ] && [ "$pyminor" -lt 10 ]; }; then
        log_error "Python 3.10+ required, found $pyver"
        return 1
    fi

    # Install venv support (varies by distro)
    # - Debian/Ubuntu: needs python3-venv or python3.X-venv package
    # - Fedora/RHEL/Arch/openSUSE: venv included with python3, just need pip
    # - Alpine: needs py3-pip
    case "$PKG_MANAGER" in
        apt)
            # Debian/Ubuntu needs python3-venv package (version-specific)
            local pyver_full
            pyver_full=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null)
            if [ -n "$pyver_full" ]; then
                install_package "python${pyver_full}-venv" || install_package "python3-venv"
            else
                install_package "python3-venv"
            fi
            ;;
        dnf)
            # Fedora/RHEL 8+: venv is included with python3, just ensure pip
            install_package "python3-pip" || true
            ;;
        yum)
            # Older RHEL/CentOS 7
            install_package "python3-pip" || true
            ;;
        pacman)
            # Arch Linux: venv included with python, pip is separate
            install_package "python-pip" || true
            ;;
        zypper)
            # openSUSE: venv included with python3
            install_package "python3-pip" || true
            ;;
        apk)
            # Alpine
            install_package "py3-pip" || true
            ;;
        *)
            # Try generic python3-venv, ignore if fails (venv may be built-in)
            install_package "python3-venv" 2>/dev/null || true
            ;;
    esac

    # Create virtual environment
    local VENV_DIR="$INSTALL_DIR/venv"
    # Check if venv exists AND is complete (has pip)
    if [ ! -x "$VENV_DIR/bin/pip" ]; then
        # Remove broken/incomplete venv if exists
        [ -d "$VENV_DIR" ] && rm -rf "$VENV_DIR"
        log_info "Creating Python virtual environment..."
        python3 -m venv "$VENV_DIR" || {
            log_error "Failed to create virtual environment (is python3-venv installed?)"
            return 1
        }
    fi

    # Verify pip exists after venv creation
    if [ ! -x "$VENV_DIR/bin/pip" ]; then
        log_error "venv created but pip missing (install python3-venv package)"
        return 1
    fi

    # Install packages in venv
    log_info "Installing scapy and aioquic in venv..."
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
    "$VENV_DIR/bin/pip" install --quiet scapy aioquic 2>/dev/null || {
        # Try with --break-system-packages as fallback (shouldn't be needed in venv)
        "$VENV_DIR/bin/pip" install scapy aioquic || {
            log_error "Failed to install Python packages (scapy, aioquic)"
            return 1
        }
    }

    # Verify
    if "$VENV_DIR/bin/python" -c "import scapy; import aioquic" 2>/dev/null; then
        log_success "Python dependencies installed (scapy, aioquic)"
    else
        log_error "Python package verification failed"
        return 1
    fi
}

install_microsocks() {
    log_info "Installing microsocks for SOCKS5 proxy..."
    if [ -x "$INSTALL_DIR/bin/microsocks" ]; then
        log_success "microsocks already installed"
        return 0
    fi
    # Build dependencies
    command -v gcc &>/dev/null || install_package gcc
    command -v make &>/dev/null || install_package make
    local tmp_dir
    tmp_dir=$(mktemp -d)
    if ! curl -sL "https://github.com/${MICROSOCKS_REPO}/archive/refs/heads/master.tar.gz" -o "$tmp_dir/microsocks.tar.gz"; then
        log_error "Failed to download microsocks"
        rm -rf "$tmp_dir"
        return 1
    fi
    tar -xzf "$tmp_dir/microsocks.tar.gz" -C "$tmp_dir" 2>/dev/null || {
        log_error "Failed to extract microsocks"
        rm -rf "$tmp_dir"
        return 1
    }
    local src_dir
    src_dir=$(find "$tmp_dir" -maxdepth 1 -type d -name "microsocks*" | head -1)
    if [ -z "$src_dir" ]; then
        log_error "microsocks source directory not found"
        rm -rf "$tmp_dir"
        return 1
    fi
    if ! make -C "$src_dir" -j"$(nproc 2>/dev/null || echo 1)" 2>/dev/null; then
        log_error "Failed to compile microsocks"
        rm -rf "$tmp_dir"
        return 1
    fi
    mkdir -p "$INSTALL_DIR/bin"
    cp "$src_dir/microsocks" "$INSTALL_DIR/bin/microsocks"
    chmod 755 "$INSTALL_DIR/bin/microsocks"
    rm -rf "$tmp_dir"
    log_success "microsocks installed"
}

#───────────────────────────────────────────────────────────────────────
# Xray Installation (for GFK server - provides SOCKS5 on port 443)
#───────────────────────────────────────────────────────────────────────

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/config.json"

check_xray_installed() {
    command -v xray &>/dev/null && return 0
    [ -x /usr/local/bin/xray ] && return 0
    [ -x /usr/local/x-ui/bin/xray-linux-amd64 ] && return 0
    return 1
}

install_xray() {
    if check_xray_installed; then
        log_info "Xray is already installed"
        return 0
    fi

    log_info "Installing Xray ${XRAY_VERSION_PINNED}..."

    # Use official Xray install script with pinned version for stability
    local tmp_script
    tmp_script=$(mktemp)
    if ! curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp_script"; then
        log_error "Failed to download Xray installer"
        rm -f "$tmp_script"
        return 1
    fi

    # Install specific version (not latest) for stability
    if ! bash "$tmp_script" install --version "$XRAY_VERSION_PINNED" 2>/dev/null; then
        log_error "Failed to install Xray"
        rm -f "$tmp_script"
        return 1
    fi
    rm -f "$tmp_script"

    log_success "Xray ${XRAY_VERSION_PINNED} installed"
}

configure_xray_socks() {
    local listen_port="${1:-443}"

    log_info "Configuring Xray SOCKS5 proxy on port $listen_port..."

    mkdir -p "$XRAY_CONFIG_DIR"

    # Create simple SOCKS5 inbound config
    cat > "$XRAY_CONFIG_FILE" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": ${listen_port},
      "listen": "127.0.0.1",
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
    chmod 644 "$XRAY_CONFIG_FILE"  # Xray service runs as 'nobody', needs read access
    log_success "Xray configured (SOCKS5 on 127.0.0.1:$listen_port)"
}

# Check if running xray is paqctl's own standalone install (not a real panel)
# Returns 0 if standalone (all inbounds are socks on 127.0.0.1), 1 if panel
_is_paqctl_standalone_xray() {
    [ -f "$XRAY_CONFIG_FILE" ] || return 1
    command -v python3 &>/dev/null || return 1
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    inbounds = cfg.get('inbounds', [])
    if not inbounds:
        sys.exit(1)
    for i in inbounds:
        if i.get('protocol') != 'socks' or i.get('listen', '0.0.0.0') != '127.0.0.1':
            sys.exit(1)
    sys.exit(0)
except:
    sys.exit(1)
" "$XRAY_CONFIG_FILE" 2>/dev/null
}

# Add a SOCKS5 inbound to an existing xray config (panel) without touching other inbounds
_add_xray_gfk_socks() {
    local port="$1"
    python3 -c "
import json, sys
port = int(sys.argv[1])
config_path = sys.argv[2]
try:
    with open(config_path, 'r') as f:
        cfg = json.load(f)
except:
    cfg = {'inbounds': [], 'outbounds': [{'tag': 'direct', 'protocol': 'freedom', 'settings': {}}]}
cfg.setdefault('inbounds', [])
cfg['inbounds'] = [i for i in cfg['inbounds'] if i.get('tag') != 'gfk-socks']
cfg['inbounds'].append({
    'tag': 'gfk-socks',
    'port': port,
    'listen': '127.0.0.1',
    'protocol': 'socks',
    'settings': {'auth': 'noauth', 'udp': True},
    'sniffing': {'enabled': True, 'destOverride': ['http', 'tls']}
})
if not any(o.get('protocol') == 'freedom' for o in cfg.get('outbounds', [])):
    cfg.setdefault('outbounds', []).append({'tag': 'direct', 'protocol': 'freedom', 'settings': {}})
with open(config_path, 'w') as f:
    json.dump(cfg, f, indent=2)
" "$port" "$XRAY_CONFIG_FILE" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_error "Failed to add SOCKS5 inbound to existing Xray config"
        return 1
    fi
    log_success "Added GFK SOCKS5 inbound on 127.0.0.1:$port"
}

start_xray() {
    log_info "Starting Xray service..."

    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        # Stop first, reload daemon, then start - with retry
        systemctl stop xray 2>/dev/null || true
        sleep 1
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable xray 2>/dev/null || true

        # Try up to 3 times
        local attempt
        for attempt in 1 2 3; do
            systemctl start xray 2>/dev/null
            sleep 2
            if systemctl is-active --quiet xray; then
                log_success "Xray started"
                return 0
            fi
            [ "$attempt" -lt 3 ] && sleep 1
        done
        log_error "Failed to start Xray after 3 attempts"
        return 1
    else
        # Direct start for non-systemd
        local _xray_bin=""
        [ -x /usr/local/bin/xray ] && _xray_bin="/usr/local/bin/xray"
        [ -z "$_xray_bin" ] && [ -x /usr/local/x-ui/bin/xray-linux-amd64 ] && _xray_bin="/usr/local/x-ui/bin/xray-linux-amd64"
        if [ -n "$_xray_bin" ]; then
            pkill -x xray 2>/dev/null || true
            sleep 1
            nohup "$_xray_bin" run -c "$XRAY_CONFIG_FILE" > /var/log/xray.log 2>&1 &
            sleep 2
            if pgrep -f "xray" &>/dev/null; then
                log_success "Xray started"
                return 0
            fi
        fi
        log_error "Failed to start Xray"
        return 1
    fi
}

stop_xray() {
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl stop xray 2>/dev/null || true
    else
        pkill -x xray 2>/dev/null || true
    fi
}

setup_xray_for_gfk() {
    local target_port
    target_port=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d: -f2 | cut -d, -f1)

    if pgrep -x xray &>/dev/null || pgrep -f "xray-linux" &>/dev/null; then
        # Check if this is paqctl's own standalone Xray (not a real panel)
        if _is_paqctl_standalone_xray; then
            log_info "Existing Xray is paqctl's standalone install — reconfiguring..."
            stop_xray
            sleep 1
            # Fall through to standalone install path below
        else
            XRAY_PANEL_DETECTED=true
            log_info "Existing Xray detected — adding SOCKS5 alongside panel..."

            # Clean up any leftover standalone GFK xray from prior installs
            pkill -f "xray run -c.*gfk-socks.json" 2>/dev/null || true
            rm -f "${XRAY_CONFIG_DIR}/gfk-socks.json" 2>/dev/null

            # Check all existing target ports from mappings
            local mapping pairs
            IFS=',' read -ra pairs <<< "${GFK_PORT_MAPPINGS:-14000:443}"
            for mapping in "${pairs[@]}"; do
                local vio_port="${mapping%%:*}"
                local tp="${mapping##*:}"
                if ss -tln 2>/dev/null | grep -q ":${tp} "; then
                    log_success "Port $tp is listening — GFK will forward VIO port $vio_port to this port"
                else
                    log_warn "Port $tp is NOT listening — make sure your panel inbound is on port $tp"
                fi
            done

            # Find free port for SOCKS5 (starting at 10443)
            local socks_port=10443
            while ss -tln 2>/dev/null | grep -q ":${socks_port} "; do
                socks_port=$((socks_port + 1))
                if [ "$socks_port" -gt 65000 ]; then
                    log_warn "Could not find free port for SOCKS5 — panel-only mode"
                    echo ""
                    local first_vio
                    first_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d: -f1 | cut -d, -f1)
                    log_warn "For panel-to-panel: configure Iran panel outbound to 127.0.0.1:${first_vio}"
                    return 0
                fi
            done

            # Add SOCKS5 inbound to existing xray config
            _add_xray_gfk_socks "$socks_port" || {
                log_warn "Could not add SOCKS5 to panel config — panel-only mode"
                return 0
            }

            # Restart xray to load new config
            systemctl restart xray 2>/dev/null || pkill -SIGHUP xray 2>/dev/null || true
            sleep 2

            # Find next VIO port (highest existing + 1) and append SOCKS5 mapping
            local max_vio=0
            for mapping in "${pairs[@]}"; do
                local v="${mapping%%:*}"
                [ "$v" -gt "$max_vio" ] && max_vio="$v"
            done
            local socks_vio=$((max_vio + 1))
            GFK_PORT_MAPPINGS="${GFK_PORT_MAPPINGS},${socks_vio}:${socks_port}"
            GFK_SOCKS_PORT="$socks_port"
            GFK_SOCKS_VIO_PORT="$socks_vio"

            log_success "SOCKS5 proxy added on port $socks_port (VIO port $socks_vio)"
            echo ""
            log_info "Port mappings updated: ${GFK_PORT_MAPPINGS}"
            log_warn "Use these SAME mappings on the client side"
            echo ""
            local first_vio
            first_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d: -f1 | cut -d, -f1)
            log_warn "For panel-to-panel: configure Iran panel outbound to 127.0.0.1:${first_vio}"
            log_warn "For direct SOCKS5: use 127.0.0.1:${socks_vio} as your proxy on client"
            return 0
        fi
    fi

    install_xray || return 1
    configure_xray_socks "$target_port" || return 1
    start_xray || return 1
}

download_gfk() {
    log_info "Downloading GFW-knocker scripts..."
    if ! mkdir -p "$GFK_DIR"; then
        log_error "Failed to create $GFK_DIR"
        return 1
    fi
    # Note: parameters.py is generated by generate_gfk_config(), don't download it
    # Download server scripts from gfk/server/
    local server_files="mainserver.py quic_server.py vio_server.py"
    local f
    for f in $server_files; do
        if ! curl -sL "$GFK_RAW_URL/server/$f" -o "$GFK_DIR/$f"; then
            log_error "Failed to download $f"
            return 1
        fi
    done
    # Download client scripts from gfk/client/
    local client_files="mainclient.py quic_client.py vio_client.py"
    for f in $client_files; do
        if ! curl -sL "$GFK_RAW_URL/client/$f" -o "$GFK_DIR/$f"; then
            log_error "Failed to download $f"
            return 1
        fi
    done
    chmod 600 "$GFK_DIR"/*.py
    # Patch mainserver.py to use venv python for subprocesses
    if [ -f "$GFK_DIR/mainserver.py" ]; then
        sed -i "s|'python3'|'$INSTALL_DIR/venv/bin/python'|g" "$GFK_DIR/mainserver.py"
    fi
    log_success "GFW-knocker scripts downloaded to $GFK_DIR"
}

generate_gfk_certs() {
    if [ -f "$GFK_DIR/cert.pem" ] && [ -f "$GFK_DIR/key.pem" ]; then
        log_info "GFW-knocker certificates already exist"
        return 0
    fi
    if ! command -v openssl &>/dev/null; then
        log_info "Installing openssl..."
        install_package openssl || { log_error "Failed to install openssl"; return 1; }
    fi
    log_info "Generating QUIC TLS certificates..."
    if ! openssl req -x509 -newkey rsa:2048 -keyout "$GFK_DIR/key.pem" \
        -out "$GFK_DIR/cert.pem" -days 3650 -nodes -subj "/CN=gfk" 2>/dev/null; then
        log_error "Failed to generate certificates"
        return 1
    fi
    chmod 600 "$GFK_DIR/key.pem" "$GFK_DIR/cert.pem"
    log_success "QUIC certificates generated"
}

generate_gfk_config() {
    log_info "Generating GFW-knocker configuration..."
    # Ensure GFK directory exists
    mkdir -p "$GFK_DIR" || { log_error "Failed to create $GFK_DIR"; return 1; }
    local _tmp
    _tmp=$(mktemp "$GFK_DIR/parameters.py.XXXXXXXX") || { log_error "Failed to create temp file"; return 1; }

    # Determine port values based on role - validate they are numeric
    local vio_tcp_server_port="${GFK_VIO_PORT:-45000}"
    local vio_tcp_client_port="${GFK_VIO_CLIENT_PORT:-40000}"
    local vio_udp_server_port="${GFK_VIO_UDP_SERVER:-35000}"
    local vio_udp_client_port="${GFK_VIO_UDP_CLIENT:-30000}"
    local quic_server_port="${GFK_QUIC_PORT:-25000}"
    local quic_client_port="${GFK_QUIC_CLIENT_PORT:-20000}"

    # Validate all ports are numeric
    for _p in "$vio_tcp_server_port" "$vio_tcp_client_port" "$vio_udp_server_port" \
              "$vio_udp_client_port" "$quic_server_port" "$quic_client_port"; do
        if ! [[ "$_p" =~ ^[0-9]+$ ]]; then
            log_error "Invalid port number: $_p"
            rm -f "$_tmp"
            return 1
        fi
    done

    # Escape Python string - prevents code injection
    _escape_py_string() {
        local s="$1"
        s="${s//\\/\\\\}"   # Escape backslashes first
        s="${s//\"/\\\"}"   # Escape double quotes
        s="${s//\'/\\\'}"   # Escape single quotes
        s="${s//$'\n'/\\n}" # Escape newlines
        s="${s//$'\r'/\\r}" # Escape carriage returns
        printf '%s' "$s"
    }

    # Validate and escape server IP
    local safe_server_ip
    safe_server_ip=$(_escape_py_string "${GFK_SERVER_IP:-}")
    if ! _validate_ip "${GFK_SERVER_IP:-}"; then
        log_error "Invalid server IP: ${GFK_SERVER_IP:-}"
        rm -f "$_tmp"
        return 1
    fi

    # Validate and escape auth code
    local safe_auth_code
    safe_auth_code=$(_escape_py_string "${GFK_AUTH_CODE:-}")

    # Build port mapping dict string with validation
    local tcp_mapping="${GFK_PORT_MAPPINGS:-14000:443}"
    local mapping_str="{"
    local first=true
    local pair
    for pair in $(echo "$tcp_mapping" | tr ',' ' '); do
        local lport rport
        lport=$(echo "$pair" | cut -d: -f1)
        rport=$(echo "$pair" | cut -d: -f2)
        # Validate both ports are numeric
        if ! [[ "$lport" =~ ^[0-9]+$ ]] || ! [[ "$rport" =~ ^[0-9]+$ ]]; then
            log_error "Invalid port mapping: $pair (must be numeric:numeric)"
            rm -f "$_tmp"
            return 1
        fi
        if [ "$first" = true ]; then
            mapping_str="${mapping_str}${lport}: ${rport}"
            first=false
        else
            mapping_str="${mapping_str}, ${lport}: ${rport}"
        fi
    done
    mapping_str="${mapping_str}}"

    # Escape GFK_DIR for Python string
    local safe_gfk_dir
    safe_gfk_dir=$(_escape_py_string "${GFK_DIR}")

    (
    umask 077
    cat > "$_tmp" << PYEOF
# GFW-knocker parameters - auto-generated by paqctl
# Do not edit manually

vps_ip = "${safe_server_ip}"
xray_server_ip_address = "127.0.0.1"

tcp_port_mapping = ${mapping_str}
udp_port_mapping = {}

vio_tcp_server_port = ${vio_tcp_server_port}
vio_tcp_client_port = ${vio_tcp_client_port}
vio_udp_server_port = ${vio_udp_server_port}
vio_udp_client_port = ${vio_udp_client_port}

quic_server_port = ${quic_server_port}
quic_client_port = ${quic_client_port}
quic_local_ip = "127.0.0.1"

quic_idle_timeout = 86400
udp_timeout = 300
quic_mtu = 1420
quic_verify_cert = False
quic_max_data = 1073741824
quic_max_stream_data = 1073741824

quic_auth_code = "${safe_auth_code}"

quic_cert_filepath = ("${safe_gfk_dir}/cert.pem", "${safe_gfk_dir}/key.pem")

tcp_flags = "${GFK_TCP_FLAGS:-AP}"
PYEOF
    )
    if ! mv "$_tmp" "$GFK_DIR/parameters.py"; then
        log_error "Failed to save GFW-knocker configuration"
        rm -f "$_tmp"
        return 1
    fi
    chmod 600 "$GFK_DIR/parameters.py"
    log_success "GFW-knocker configuration saved"
}

create_gfk_client_wrapper() {
    log_info "Creating GFW-knocker client wrapper..."
    local wrapper="$INSTALL_DIR/bin/gfk-client.sh"
    mkdir -p "$INSTALL_DIR/bin"
    cat > "$wrapper" << 'WRAPEOF'
#!/bin/bash
set -e
GFK_DIR="REPLACE_ME_GFK_DIR"
INSTALL_DIR="REPLACE_ME_INSTALL_DIR"

cd "$GFK_DIR"
"$INSTALL_DIR/venv/bin/python" mainclient.py &
PID1=$!
trap "kill $PID1 2>/dev/null; wait" EXIT INT TERM
wait
WRAPEOF
    sed "s#REPLACE_ME_GFK_DIR#${GFK_DIR}#g; s#REPLACE_ME_INSTALL_DIR#${INSTALL_DIR}#g" "$wrapper" > "$wrapper.sed" && mv "$wrapper.sed" "$wrapper"
    chmod 755 "$wrapper"
    log_success "Client wrapper created at $wrapper"
}

#═══════════════════════════════════════════════════════════════════════
# Service Management
#═══════════════════════════════════════════════════════════════════════

setup_service() {
    log_info "Setting up auto-start on boot..."

    # Check which backends are installed
    local paqet_installed=false gfk_installed=false
    [ -f "$INSTALL_DIR/bin/paqet" ] && paqet_installed=true
    if [ "$ROLE" = "server" ]; then
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_server.py" ] && gfk_installed=true
    else
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_client.py" ] && gfk_installed=true
    fi

    # If both backends are installed, create a combined service
    local _both_installed=false
    [ "$paqet_installed" = true ] && [ "$gfk_installed" = true ] && _both_installed=true

    # Compute ExecStart based on backend
    local _exec_start _working_dir _svc_desc _svc_type="simple"
    if [ "$_both_installed" = true ]; then
        _svc_desc="Paqet Combined Proxy Service (Paqet + GFK)"
        _working_dir="${INSTALL_DIR}"
        _svc_type="forking"
        # Create a wrapper script that starts both backends
        cat > "${INSTALL_DIR}/bin/start-both.sh" << BOTH_SCRIPT
#!/bin/bash
INSTALL_DIR="/opt/paqctl"
GFK_DIR="\${INSTALL_DIR}/gfk"
ROLE="${ROLE}"

# Source config for ports
[ -f "\${INSTALL_DIR}/settings.conf" ] && . "\${INSTALL_DIR}/settings.conf"

# Detect firewall backend
_use_firewalld=false
if command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running; then
    _use_firewalld=true
fi

# Apply firewall rules (server + client)
if [ "\$ROLE" = "server" ]; then
    port="\${LISTEN_PORT:-8443}"
    vio_port="\${GFK_VIO_PORT:-45000}"
    TAG="paqctl"
    if [ "\$_use_firewalld" = true ]; then
        # Paqet rules via firewalld
        firewall-cmd --direct --add-rule ipv4 raw PREROUTING 0 -p tcp --dport "\$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv4 raw OUTPUT 0 -p tcp --sport "\$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv4 mangle OUTPUT 0 -p tcp --sport "\$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        # GFK rules via firewalld
        firewall-cmd --direct --add-rule ipv4 raw PREROUTING 0 -p tcp --dport "\$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv4 raw OUTPUT 0 -p tcp --sport "\$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv4 filter INPUT 0 -p tcp --dport "\$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --sport "\$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        # IPv6 GFK
        firewall-cmd --direct --add-rule ipv6 filter INPUT 0 -p tcp --dport "\$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv6 filter OUTPUT 0 -p tcp --sport "\$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --runtime-to-permanent 2>/dev/null || true
    else
        # Paqet rules via iptables
        modprobe iptable_raw 2>/dev/null || true
        modprobe iptable_mangle 2>/dev/null || true
        iptables -t raw -C PREROUTING -p tcp --dport "\$port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null || \\
            iptables -t raw -A PREROUTING -p tcp --dport "\$port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null
        iptables -t raw -C OUTPUT -p tcp --sport "\$port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null || \\
            iptables -t raw -A OUTPUT -p tcp --sport "\$port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null
        iptables -t mangle -C OUTPUT -p tcp --sport "\$port" -m comment --comment "\$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || \\
            iptables -t mangle -A OUTPUT -p tcp --sport "\$port" -m comment --comment "\$TAG" --tcp-flags RST RST -j DROP 2>/dev/null
        # GFK rules via iptables
        modprobe iptable_raw 2>/dev/null || true
        iptables -t raw -C PREROUTING -p tcp --dport "\$vio_port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null || \\
            iptables -t raw -A PREROUTING -p tcp --dport "\$vio_port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null
        iptables -t raw -C OUTPUT -p tcp --sport "\$vio_port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null || \\
            iptables -t raw -A OUTPUT -p tcp --sport "\$vio_port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null
        iptables -C INPUT -p tcp --dport "\$vio_port" -m comment --comment "\$TAG" -j DROP 2>/dev/null || \\
            iptables -A INPUT -p tcp --dport "\$vio_port" -m comment --comment "\$TAG" -j DROP 2>/dev/null
        iptables -C OUTPUT -p tcp --sport "\$vio_port" --tcp-flags RST RST -m comment --comment "\$TAG" -j DROP 2>/dev/null || \\
            iptables -A OUTPUT -p tcp --sport "\$vio_port" --tcp-flags RST RST -m comment --comment "\$TAG" -j DROP 2>/dev/null
        if command -v ip6tables &>/dev/null; then
            ip6tables -C INPUT -p tcp --dport "\$vio_port" -m comment --comment "\$TAG" -j DROP 2>/dev/null || \\
                ip6tables -A INPUT -p tcp --dport "\$vio_port" -m comment --comment "\$TAG" -j DROP 2>/dev/null || true
            ip6tables -C OUTPUT -p tcp --sport "\$vio_port" --tcp-flags RST RST -m comment --comment "\$TAG" -j DROP 2>/dev/null || \\
                ip6tables -A OUTPUT -p tcp --sport "\$vio_port" --tcp-flags RST RST -m comment --comment "\$TAG" -j DROP 2>/dev/null || true
        fi
    fi
else
    # GFK client firewall rules
    vio_client_port="\${GFK_VIO_CLIENT_PORT:-40000}"
    TAG="paqctl"
    if [ "\$_use_firewalld" = true ]; then
        firewall-cmd --direct --add-rule ipv4 raw PREROUTING 0 -p tcp --dport "\$vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv4 raw OUTPUT 0 -p tcp --sport "\$vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv4 filter INPUT 0 -p tcp --dport "\$vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --sport "\$vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv6 filter INPUT 0 -p tcp --dport "\$vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --add-rule ipv6 filter OUTPUT 0 -p tcp --sport "\$vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --runtime-to-permanent 2>/dev/null || true
    else
        modprobe iptable_raw 2>/dev/null || true
        iptables -t raw -C PREROUTING -p tcp --dport "\$vio_client_port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null || \\
            iptables -t raw -A PREROUTING -p tcp --dport "\$vio_client_port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null
        iptables -t raw -C OUTPUT -p tcp --sport "\$vio_client_port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null || \\
            iptables -t raw -A OUTPUT -p tcp --sport "\$vio_client_port" -m comment --comment "\$TAG" -j NOTRACK 2>/dev/null
        iptables -C INPUT -p tcp --dport "\$vio_client_port" -m comment --comment "\$TAG" -j DROP 2>/dev/null || \\
            iptables -A INPUT -p tcp --dport "\$vio_client_port" -m comment --comment "\$TAG" -j DROP 2>/dev/null
        iptables -C OUTPUT -p tcp --sport "\$vio_client_port" --tcp-flags RST RST -m comment --comment "\$TAG" -j DROP 2>/dev/null || \\
            iptables -A OUTPUT -p tcp --sport "\$vio_client_port" --tcp-flags RST RST -m comment --comment "\$TAG" -j DROP 2>/dev/null
        if command -v ip6tables &>/dev/null; then
            ip6tables -C INPUT -p tcp --dport "\$vio_client_port" -m comment --comment "\$TAG" -j DROP 2>/dev/null || \\
                ip6tables -A INPUT -p tcp --dport "\$vio_client_port" -m comment --comment "\$TAG" -j DROP 2>/dev/null || true
            ip6tables -C OUTPUT -p tcp --sport "\$vio_client_port" --tcp-flags RST RST -m comment --comment "\$TAG" -j DROP 2>/dev/null || \\
                ip6tables -A OUTPUT -p tcp --sport "\$vio_client_port" --tcp-flags RST RST -m comment --comment "\$TAG" -j DROP 2>/dev/null || true
        fi
    fi
fi

# Start paqet backend
(umask 077; touch /var/log/paqet-backend.log)
nohup "\${INSTALL_DIR}/bin/paqet" run -c "\${INSTALL_DIR}/config.yaml" > /var/log/paqet-backend.log 2>&1 &
echo \$! > /run/paqet-backend.pid

# Start GFK backend
(umask 077; touch /var/log/gfk-backend.log)
if [ "\$ROLE" = "server" ]; then
    # Start Xray if available
    if command -v xray &>/dev/null || [ -x /usr/local/bin/xray ] || [ -x /usr/local/x-ui/bin/xray-linux-amd64 ]; then
        if ! pgrep -f "xray run" &>/dev/null; then
            systemctl start xray 2>/dev/null || xray run -c /usr/local/etc/xray/config.json &>/dev/null &
            sleep 2
        fi
    fi
    cd "\$GFK_DIR"
    nohup "\${INSTALL_DIR}/venv/bin/python" "\${GFK_DIR}/mainserver.py" > /var/log/gfk-backend.log 2>&1 &
else
    if [ -x "\${INSTALL_DIR}/bin/gfk-client.sh" ]; then
        nohup "\${INSTALL_DIR}/bin/gfk-client.sh" > /var/log/gfk-backend.log 2>&1 &
    else
        cd "\$GFK_DIR"
        nohup "\${INSTALL_DIR}/venv/bin/python" "\${GFK_DIR}/mainclient.py" > /var/log/gfk-backend.log 2>&1 &
    fi
fi
echo \$! > /run/gfk-backend.pid

sleep 1
exit 0
BOTH_SCRIPT
        chmod +x "${INSTALL_DIR}/bin/start-both.sh"
        _exec_start="${INSTALL_DIR}/bin/start-both.sh"
    elif [ "$BACKEND" = "gfw-knocker" ]; then
        _svc_desc="GFW-knocker Proxy Service"
        _working_dir="${GFK_DIR}"
        if [ "$ROLE" = "server" ]; then
            _exec_start="${INSTALL_DIR}/venv/bin/python ${GFK_DIR}/mainserver.py"
        else
            _exec_start="${INSTALL_DIR}/bin/gfk-client.sh"
        fi
    else
        _svc_desc="Paqet Proxy Service"
        _working_dir="${INSTALL_DIR}"
        _exec_start="${INSTALL_DIR}/bin/paqet run -c ${INSTALL_DIR}/config.yaml"
    fi

    if [ "$HAS_SYSTEMD" = "true" ]; then
        if [ "$_both_installed" = true ]; then
            # Combined service for both backends
            cat > /etc/systemd/system/paqctl.service << EOF
[Unit]
Description=${_svc_desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=${_svc_type}
WorkingDirectory=${_working_dir}
ExecStart=${_exec_start}
ExecStop=/usr/local/bin/paqctl stop
ExecStopPost=/usr/local/bin/paqctl _remove-firewall
RemainAfterExit=yes
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=paqctl

[Install]
WantedBy=multi-user.target
EOF
        else
            # Single backend service
            cat > /etc/systemd/system/paqctl.service << EOF
[Unit]
Description=${_svc_desc}
After=network-online.target
Wants=network-online.target

[Service]
Type=${_svc_type}
WorkingDirectory=${_working_dir}
ExecStartPre=/usr/local/bin/paqctl _apply-firewall
ExecStart=${_exec_start}
ExecStopPost=/usr/local/bin/paqctl _remove-firewall
Restart=on-failure
RestartSec=5
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal
SyslogIdentifier=paqctl

[Install]
WantedBy=multi-user.target
EOF
        fi

        systemctl daemon-reload 2>/dev/null || true
        systemctl enable paqctl.service 2>/dev/null || true
        log_success "Systemd service created and enabled"

    elif command -v rc-update &>/dev/null; then
        local _openrc_run
        _openrc_run=$(command -v openrc-run 2>/dev/null || echo "/sbin/openrc-run")
        cat > /etc/init.d/paqctl << EOF
#!${_openrc_run}

name="paqctl"
description="${_svc_desc}"
command="$(echo "${_exec_start}" | awk '{print $1}')"
command_args="$(echo "${_exec_start}" | cut -d' ' -f2-)"
if [ "\$command_args" = "\$command" ]; then command_args=""; fi
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"

depend() {
    need net
    after firewall
}

start_pre() {
    /usr/local/bin/paqctl _apply-firewall
}

stop_post() {
    /usr/local/bin/paqctl _remove-firewall
}
EOF
        if ! chmod +x /etc/init.d/paqctl; then
            log_error "Failed to make init script executable"
            return 1
        fi
        rc-update add paqctl default 2>/dev/null || true
        log_success "OpenRC service created and enabled"

    elif [ -d /etc/init.d ]; then
        cat > /etc/init.d/paqctl << SYSV
#!/bin/bash
### BEGIN INIT INFO
# Provides:          paqctl
# Required-Start:    \$remote_fs \$network \$syslog
# Required-Stop:     \$remote_fs \$network \$syslog
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: ${_svc_desc}
### END INIT INFO

case "\$1" in
    start)
        /usr/local/bin/paqctl _apply-firewall
        ${_exec_start} &
        _pid=\$!
        sleep 1
        if kill -0 "\$_pid" 2>/dev/null; then
            echo \$_pid > /run/paqctl.pid
        else
            echo "Failed to start paqet"
            /usr/local/bin/paqctl _remove-firewall
            exit 1
        fi
        ;;
    stop)
        if [ -f /run/paqctl.pid ]; then
            _pid=\$(cat /run/paqctl.pid)
            kill "\$_pid" 2>/dev/null
            _count=0
            while kill -0 "\$_pid" 2>/dev/null && [ \$_count -lt 10 ]; do
                sleep 1
                _count=\$((_count + 1))
            done
            kill -0 "\$_pid" 2>/dev/null && kill -9 "\$_pid" 2>/dev/null
            rm -f /run/paqctl.pid
        fi
        /usr/local/bin/paqctl _remove-firewall
        ;;
    restart)
        \$0 stop
        sleep 1
        \$0 start
        ;;
    status)
        [ -f /run/paqctl.pid ] && kill -0 "\$(cat /run/paqctl.pid)" 2>/dev/null && echo "Running" || echo "Stopped"
        ;;
    *)
        echo "Usage: \$0 {start|stop|restart|status}"
        exit 1
        ;;
esac
SYSV
        if ! chmod +x /etc/init.d/paqctl; then
            log_error "Failed to make init script executable"
            return 1
        fi
        if command -v update-rc.d &>/dev/null; then
            update-rc.d paqctl defaults 2>/dev/null || true
        elif command -v chkconfig &>/dev/null; then
            chkconfig paqctl on 2>/dev/null || true
        fi
        log_success "SysVinit service created and enabled"

    else
        log_warn "Could not set up auto-start. You can start paqet manually with: sudo paqctl start"
    fi
}

setup_logrotate() {
    # Only set up if logrotate is available
    command -v logrotate &>/dev/null || return 0

    log_info "Setting up log rotation..."

    cat > /etc/logrotate.d/paqctl << 'LOGROTATE'
/var/log/paqctl.log
/var/log/paqet-backend.log
/var/log/gfk-backend.log
/var/log/xray.log
{
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        # Signal processes to reopen logs if needed
        systemctl reload paqctl.service 2>/dev/null || true
    endscript
}
LOGROTATE

    log_success "Log rotation configured (7 days, compressed)"
}

#═══════════════════════════════════════════════════════════════════════
# Management Script (Embedded)
#═══════════════════════════════════════════════════════════════════════

create_management_script() {
    local tmp_script
    tmp_script=$(mktemp "$INSTALL_DIR/paqctl.XXXXXXXX") || { log_error "Failed to create temp file"; return 1; }
    cat > "$tmp_script" << 'MANAGEMENT'
#!/bin/bash
#
# paqctl - Paqet Manager
# https://github.com/SamNet-dev/paqctl
#

VERSION="1.0.0"

# Pinned versions for stability (update these after testing new releases)
PAQET_VERSION_PINNED="v1.0.0-alpha.15"
XRAY_VERSION_PINNED="v26.2.4"
GFK_VERSION_PINNED="v1.0.0"

INSTALL_DIR="REPLACE_ME_INSTALL_DIR"
BACKUP_DIR="$INSTALL_DIR/backups"
PAQET_REPO="hanselime/paqet"
PAQET_API_URL="https://api.github.com/repos/${PAQET_REPO}/releases/latest"
GFK_REPO="SamNet-dev/paqctl"
GFK_BRANCH="main"
GFK_RAW_URL="https://raw.githubusercontent.com/${GFK_REPO}/${GFK_BRANCH}/gfk"
GFK_DIR="$INSTALL_DIR/gfk"
MICROSOCKS_REPO="rofl0r/microsocks"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Input validation helpers
_validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }
_validate_ip() {
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    local IFS='.'; set -- $1
    [ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ]
}
_validate_mac() { [[ "$1" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; }
_validate_iface() { [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]] && [ ${#1} -le 64 ]; }
# Safe string length check - prevents DoS via extremely long inputs
_check_length() { [ ${#1} -le "${2:-256}" ]; }

# Network auto-detection
detect_network() {
    log_info "Auto-detecting network configuration..."

    # Default interface - handle both standard "via X dev Y" and OpenVZ "dev Y scope link" formats
    # Standard: "default via 192.168.1.1 dev eth0" -> $5 = eth0
    # OpenVZ:   "default dev venet0 scope link"   -> $3 = venet0
    local _route_line
    _route_line=$(ip route show default 2>/dev/null | head -1)
    if [[ "$_route_line" == *" via "* ]]; then
        # Standard format with gateway
        DETECTED_IFACE=$(echo "$_route_line" | awk '{print $5}')
    elif [[ "$_route_line" == *" dev "* ]]; then
        # OpenVZ/direct format without gateway
        DETECTED_IFACE=$(echo "$_route_line" | awk '{print $3}')
    fi

    # Validate detected interface exists
    if [ -n "$DETECTED_IFACE" ] && ! ip link show "$DETECTED_IFACE" &>/dev/null; then
        DETECTED_IFACE=""
    fi

    if [ -z "$DETECTED_IFACE" ]; then
        # Note: grep -v returns exit 1 if no matches, so we add || true for pipefail
        DETECTED_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{gsub(/ /,"",$2); print $2}' | { grep -vE '^(lo|docker[0-9]|br-|veth|virbr|tun|tap|wg)' || true; } | head -1)
    fi

    # Local IP - wrap entire pipeline to prevent pipefail exit
    if [ -n "$DETECTED_IFACE" ]; then
        # Note: wrap in subshell with || true to handle cases where interface is invalid or has no IP
        DETECTED_IP=$( (ip -4 addr show "$DETECTED_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | { grep -o '[0-9.]*' || true; } | head -1) || true )
    fi
    if [ -z "$DETECTED_IP" ]; then
        DETECTED_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -z "$DETECTED_IP" ] && DETECTED_IP=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{gsub(/\/.*/, "", $2); print $2; exit}')
    fi

    # Gateway IP - handle OpenVZ format (may not have gateway)
    if [[ "$_route_line" == *" via "* ]]; then
        DETECTED_GATEWAY=$(echo "$_route_line" | awk '{print $3}')
    else
        DETECTED_GATEWAY=""
    fi

    # Gateway MAC
    DETECTED_GW_MAC=""
    if [ -n "$DETECTED_GATEWAY" ]; then
        DETECTED_GW_MAC=$(ip neigh show "$DETECTED_GATEWAY" 2>/dev/null | awk '/lladdr/{print $5; exit}')
        if [ -z "$DETECTED_GW_MAC" ]; then
            ping -c 1 -W 2 "$DETECTED_GATEWAY" &>/dev/null || true
            sleep 1
            DETECTED_GW_MAC=$(ip neigh show "$DETECTED_GATEWAY" 2>/dev/null | awk '/lladdr/{print $5; exit}')
        fi
        if [ -z "$DETECTED_GW_MAC" ] && command -v arp &>/dev/null; then
            # Note: grep returns exit 1 if no matches, so we add || true for pipefail
            DETECTED_GW_MAC=$(arp -n "$DETECTED_GATEWAY" 2>/dev/null | { grep -oE '([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}' || true; } | head -1)
        fi
    fi

    log_info "Interface: ${DETECTED_IFACE:-unknown}"
    log_info "Local IP:  ${DETECTED_IP:-unknown}"
    log_info "Gateway:   ${DETECTED_GATEWAY:-unknown}"
    log_info "GW MAC:    ${DETECTED_GW_MAC:-unknown}"
}

_load_settings() {
    [ -f "$INSTALL_DIR/settings.conf" ] || return 0
    # Safe settings loading without eval - uses case statement
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_][A-Z_0-9]*$ ]] || continue
        value="${value#\"}"; value="${value%\"}"
        # Skip values with dangerous shell characters
        [[ "$value" =~ [\`\$\(] ]] && continue
        case "$key" in
            BACKEND) BACKEND="$value" ;;
            ROLE) ROLE="$value" ;;
            PAQET_VERSION) PAQET_VERSION="$value" ;;
            PAQCTL_VERSION) PAQCTL_VERSION="$value" ;;
            LISTEN_PORT) [[ "$value" =~ ^[0-9]*$ ]] && LISTEN_PORT="$value" ;;
            SOCKS_PORT) [[ "$value" =~ ^[0-9]*$ ]] && SOCKS_PORT="$value" ;;
            INTERFACE) INTERFACE="$value" ;;
            LOCAL_IP) LOCAL_IP="$value" ;;
            GATEWAY_MAC) GATEWAY_MAC="$value" ;;
            ENCRYPTION_KEY) ENCRYPTION_KEY="$value" ;;
            PAQET_TCP_LOCAL_FLAG) [[ "$value" =~ ^[FSRPAUEC]+(,[FSRPAUEC]+)*$ ]] && PAQET_TCP_LOCAL_FLAG="$value" ;;
            PAQET_TCP_REMOTE_FLAG) [[ "$value" =~ ^[FSRPAUEC]+(,[FSRPAUEC]+)*$ ]] && PAQET_TCP_REMOTE_FLAG="$value" ;;
            REMOTE_SERVER) REMOTE_SERVER="$value" ;;
            GFK_VIO_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_VIO_PORT="$value" ;;
            GFK_VIO_CLIENT_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_VIO_CLIENT_PORT="$value" ;;
            GFK_QUIC_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_QUIC_PORT="$value" ;;
            GFK_QUIC_CLIENT_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_QUIC_CLIENT_PORT="$value" ;;
            GFK_AUTH_CODE) GFK_AUTH_CODE="$value" ;;
            GFK_PORT_MAPPINGS) GFK_PORT_MAPPINGS="$value" ;;
            GFK_SOCKS_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_SOCKS_PORT="$value" ;;
            GFK_SOCKS_VIO_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_SOCKS_VIO_PORT="$value" ;;
            XRAY_PANEL_DETECTED) XRAY_PANEL_DETECTED="$value" ;;
            MICROSOCKS_PORT) [[ "$value" =~ ^[0-9]*$ ]] && MICROSOCKS_PORT="$value" ;;
            GFK_SERVER_IP) GFK_SERVER_IP="$value" ;;
            GFK_TCP_FLAGS) [[ "$value" =~ ^[FSRPAUEC]+$ ]] && GFK_TCP_FLAGS="$value" ;;
            TELEGRAM_BOT_TOKEN) TELEGRAM_BOT_TOKEN="$value" ;;
            TELEGRAM_CHAT_ID) TELEGRAM_CHAT_ID="$value" ;;
            TELEGRAM_INTERVAL) [[ "$value" =~ ^[0-9]+$ ]] && TELEGRAM_INTERVAL="$value" ;;
            TELEGRAM_ENABLED) TELEGRAM_ENABLED="$value" ;;
            TELEGRAM_ALERTS_ENABLED) TELEGRAM_ALERTS_ENABLED="$value" ;;
            TELEGRAM_DAILY_SUMMARY) TELEGRAM_DAILY_SUMMARY="$value" ;;
            TELEGRAM_WEEKLY_SUMMARY) TELEGRAM_WEEKLY_SUMMARY="$value" ;;
            TELEGRAM_SERVER_LABEL) TELEGRAM_SERVER_LABEL="$value" ;;
            TELEGRAM_START_HOUR) [[ "$value" =~ ^[0-9]+$ ]] && TELEGRAM_START_HOUR="$value" ;;
        esac
    done < <(grep '^[A-Z_][A-Z_0-9]*=' "$INSTALL_DIR/settings.conf")
}

# Load settings
_load_settings
ROLE=${ROLE:-server}
PAQET_VERSION=${PAQET_VERSION:-unknown}
LISTEN_PORT=${LISTEN_PORT:-8443}
SOCKS_PORT=${SOCKS_PORT:-1080}
INTERFACE=${INTERFACE:-eth0}
LOCAL_IP=${LOCAL_IP:-}
GATEWAY_MAC=${GATEWAY_MAC:-}
ENCRYPTION_KEY=${ENCRYPTION_KEY:-}
REMOTE_SERVER=${REMOTE_SERVER:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_ENABLED=${TELEGRAM_ENABLED:-false}
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
TELEGRAM_SERVER_LABEL=${TELEGRAM_SERVER_LABEL:-}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}
BACKEND=${BACKEND:-paqet}
GFK_VIO_PORT=${GFK_VIO_PORT:-}
GFK_QUIC_PORT=${GFK_QUIC_PORT:-}
GFK_AUTH_CODE=${GFK_AUTH_CODE:-}
GFK_PORT_MAPPINGS=${GFK_PORT_MAPPINGS:-}
GFK_SOCKS_PORT=${GFK_SOCKS_PORT:-}
GFK_SOCKS_VIO_PORT=${GFK_SOCKS_VIO_PORT:-}
XRAY_PANEL_DETECTED=${XRAY_PANEL_DETECTED:-false}
MICROSOCKS_PORT=${MICROSOCKS_PORT:-}
GFK_SERVER_IP=${GFK_SERVER_IP:-}
GFK_TCP_FLAGS=${GFK_TCP_FLAGS:-AP}

# Ensure root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This command must be run as root (use sudo paqctl)${NC}"
    exit 1
fi

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
log_error()   { echo -e "${RED}[✗]${NC} $1"; }

# Retry helper with exponential backoff for API requests
_curl_with_retry() {
    local url="$1"
    local max_attempts="${2:-3}"
    local attempt=1
    local delay=2
    local response=""
    while [ $attempt -le $max_attempts ]; do
        response=$(curl -s --max-time 15 "$url" 2>/dev/null)
        if [ -n "$response" ]; then
            if echo "$response" | grep -q '"message".*rate limit'; then
                log_warn "API rate limited, waiting ${delay}s..."
                sleep $delay
                delay=$((delay * 2))
                attempt=$((attempt + 1))
                continue
            fi
            echo "$response"
            return 0
        fi
        [ $attempt -lt $max_attempts ] && sleep $delay
        delay=$((delay * 2))
        attempt=$((attempt + 1))
    done
    return 1
}

_validate_version_tag() {
    # Strict validation: only allow vX.Y.Z or X.Y.Z format with optional -suffix
    [[ "$1" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]]
}

# Safe sed: escape replacement string to prevent metachar injection
_sed_escape() { printf '%s\n' "$1" | sed 's/[&/\]/\\&/g'; }
_safe_update_setting() {
    local key="$1" value="$2" file="$3"
    local escaped_value
    escaped_value=$(_sed_escape "$value")
    sed "s/^${key}=.*/${key}=\"${escaped_value}\"/" "$file" > "$file.tmp" 2>/dev/null && mv "$file.tmp" "$file" || true
}

print_header() {
    echo -e "${CYAN}"
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                  PAQCTL - Paqet Manager v${VERSION}                   ║"
    echo "║        Raw-socket encrypted proxy - bypass firewalls           ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

#═══════════════════════════════════════════════════════════════════════
# Settings Save (management script)
#═══════════════════════════════════════════════════════════════════════

save_settings() {
    local _tg_token="${TELEGRAM_BOT_TOKEN:-}"
    local _tg_chat="${TELEGRAM_CHAT_ID:-}"
    local _tg_interval="${TELEGRAM_INTERVAL:-6}"
    local _tg_enabled="${TELEGRAM_ENABLED:-false}"
    local _tg_alerts="${TELEGRAM_ALERTS_ENABLED:-true}"
    local _tg_daily="${TELEGRAM_DAILY_SUMMARY:-true}"
    local _tg_weekly="${TELEGRAM_WEEKLY_SUMMARY:-true}"
    local _tg_label="${TELEGRAM_SERVER_LABEL:-}"
    local _tg_start_hour="${TELEGRAM_START_HOUR:-0}"
    # Sanitize sensitive values - remove shell metacharacters and control chars
    _sanitize_value() {
        printf '%s' "$1" | tr -d '"$`\\'\''(){}[]<>|;&!\n\r\t'
    }
    local _safe_key; _safe_key=$(_sanitize_value "${ENCRYPTION_KEY:-}")
    local _safe_auth; _safe_auth=$(_sanitize_value "${GFK_AUTH_CODE:-}")
    local _tmp
    _tmp=$(mktemp "$INSTALL_DIR/settings.conf.XXXXXXXX") || { log_error "Failed to create temp file"; return 1; }
    (umask 077; cat > "$_tmp" << SEOF
BACKEND="${BACKEND:-paqet}"
ROLE="${ROLE}"
PAQET_VERSION="${PAQET_VERSION:-unknown}"
PAQCTL_VERSION="${VERSION}"
LISTEN_PORT="${LISTEN_PORT:-}"
SOCKS_PORT="${SOCKS_PORT:-}"
INTERFACE="${INTERFACE:-}"
LOCAL_IP="${LOCAL_IP:-}"
GATEWAY_MAC="${GATEWAY_MAC:-}"
ENCRYPTION_KEY="${_safe_key}"
PAQET_TCP_LOCAL_FLAG="${PAQET_TCP_LOCAL_FLAG:-PA}"
PAQET_TCP_REMOTE_FLAG="${PAQET_TCP_REMOTE_FLAG:-PA}"
REMOTE_SERVER="${REMOTE_SERVER:-}"
GFK_VIO_PORT="${GFK_VIO_PORT:-}"
GFK_VIO_CLIENT_PORT="${GFK_VIO_CLIENT_PORT:-}"
GFK_QUIC_PORT="${GFK_QUIC_PORT:-}"
GFK_QUIC_CLIENT_PORT="${GFK_QUIC_CLIENT_PORT:-}"
GFK_AUTH_CODE="${_safe_auth}"
GFK_PORT_MAPPINGS="${GFK_PORT_MAPPINGS:-}"
GFK_SOCKS_PORT="${GFK_SOCKS_PORT:-}"
GFK_SOCKS_VIO_PORT="${GFK_SOCKS_VIO_PORT:-}"
XRAY_PANEL_DETECTED="${XRAY_PANEL_DETECTED:-false}"
MICROSOCKS_PORT="${MICROSOCKS_PORT:-}"
GFK_SERVER_IP="${GFK_SERVER_IP:-}"
GFK_TCP_FLAGS="${GFK_TCP_FLAGS:-AP}"
TELEGRAM_BOT_TOKEN="${_tg_token}"
TELEGRAM_CHAT_ID="${_tg_chat}"
TELEGRAM_INTERVAL=${_tg_interval}
TELEGRAM_ENABLED=${_tg_enabled}
TELEGRAM_ALERTS_ENABLED=${_tg_alerts}
TELEGRAM_DAILY_SUMMARY=${_tg_daily}
TELEGRAM_WEEKLY_SUMMARY=${_tg_weekly}
TELEGRAM_SERVER_LABEL="${_tg_label}"
TELEGRAM_START_HOUR=${_tg_start_hour}
SEOF
    )
    if ! mv "$_tmp" "$INSTALL_DIR/settings.conf"; then
        log_error "Failed to save settings"
        rm -f "$_tmp"
        return 1
    fi
    chmod 600 "$INSTALL_DIR/settings.conf" 2>/dev/null
}

#═══════════════════════════════════════════════════════════════════════
# Architecture Detection & Paqet Download (management script)
#═══════════════════════════════════════════════════════════════════════

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv7|armhf) echo "arm32" ;;
        *)
            log_error "Unsupported architecture: $arch"
            return 1
            ;;
    esac
}

download_paqet() {
    local version="$1"
    local arch
    arch=$(detect_arch) || return 1
    local os_name="linux"
    local ext="tar.gz"
    local filename="paqet-${os_name}-${arch}-${version}.${ext}"
    local url="https://github.com/${PAQET_REPO}/releases/download/${version}/${filename}"

    log_info "Downloading paqet ${version} for ${os_name}/${arch}..."

    mkdir -p "$INSTALL_DIR/bin" || { log_error "Failed to create directory"; return 1; }
    local tmp_file
    tmp_file=$(mktemp "/tmp/paqet-download-XXXXXXXX.${ext}") || { log_error "Failed to create temp file"; return 1; }

    # Try curl first, fallback to wget
    local download_ok=false
    if curl -sL --max-time 180 --retry 3 --retry-delay 5 --fail -o "$tmp_file" "$url" 2>/dev/null; then
        download_ok=true
    elif command -v wget &>/dev/null; then
        log_info "curl failed, trying wget..."
        rm -f "$tmp_file"
        if wget -q --timeout=180 --tries=3 -O "$tmp_file" "$url" 2>/dev/null; then
            download_ok=true
        fi
    fi

    if [ "$download_ok" != "true" ]; then
        log_error "Failed to download: $url"
        log_error "Try manual download: wget '$url' and place binary in $INSTALL_DIR/bin/"
        rm -f "$tmp_file"
        return 1
    fi

    # Validate download
    local fsize
    fsize=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || wc -c < "$tmp_file" 2>/dev/null || echo 0)
    if [ "$fsize" -lt 1000 ]; then
        log_error "Downloaded file is too small ($fsize bytes)"
        rm -f "$tmp_file"
        return 1
    fi

    # Extract
    log_info "Extracting..."
    local tmp_extract
    tmp_extract=$(mktemp -d "/tmp/paqet-extract-XXXXXXXX") || { log_error "Failed to create temp dir"; return 1; }
    if ! tar -xzf "$tmp_file" -C "$tmp_extract" 2>/dev/null; then
        log_error "Failed to extract archive"
        rm -f "$tmp_file"; rm -rf "$tmp_extract"
        return 1
    fi

    # Find the binary
    local binary_name="paqet_${os_name}_${arch}"
    local found_binary=""
    found_binary=$(find "$tmp_extract" -name "$binary_name" -type f 2>/dev/null | head -1)
    [ -z "$found_binary" ] && found_binary=$(find "$tmp_extract" -name "paqet*" -type f -executable 2>/dev/null | head -1)
    [ -z "$found_binary" ] && found_binary=$(find "$tmp_extract" -name "paqet*" -type f 2>/dev/null | head -1)

    if [ -z "$found_binary" ]; then
        log_error "Could not find paqet binary in archive"
        rm -f "$tmp_file"; rm -rf "$tmp_extract"
        return 1
    fi

    # Stop paqet if running to avoid "Text file busy" error
    pkill -f "$INSTALL_DIR/bin/paqet" 2>/dev/null || true
    sleep 1

    if ! cp "$found_binary" "$INSTALL_DIR/bin/paqet"; then
        log_error "Failed to copy paqet binary"
        rm -f "$tmp_file"; rm -rf "$tmp_extract"
        return 1
    fi
    chmod +x "$INSTALL_DIR/bin/paqet" || { log_error "Failed to make paqet executable"; return 1; }

    rm -f "$tmp_file"; rm -rf "$tmp_extract"

    if "$INSTALL_DIR/bin/paqet" version &>/dev/null; then
        log_success "paqet ${version} installed successfully"
    else
        log_warn "paqet installed but version check failed (may need libpcap)"
    fi
}

#═══════════════════════════════════════════════════════════════════════
# GFK Helper Functions (management script)
#═══════════════════════════════════════════════════════════════════════

install_python_deps() {
    log_info "Installing Python dependencies..."
    if ! command -v python3 &>/dev/null; then
        if command -v apt-get &>/dev/null; then apt-get install -y python3 2>/dev/null
        elif command -v dnf &>/dev/null; then dnf install -y python3 2>/dev/null
        elif command -v yum &>/dev/null; then yum install -y python3 2>/dev/null
        elif command -v apk &>/dev/null; then apk add python3 2>/dev/null
        fi
    fi
    # Verify Python 3.10+ (required for GFK)
    local pyver pymajor pyminor
    pyver=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo "0.0")
    pymajor=$(echo "$pyver" | cut -d. -f1)
    pyminor=$(echo "$pyver" | cut -d. -f2)
    if [ "$pymajor" -lt 3 ] || { [ "$pymajor" -eq 3 ] && [ "$pyminor" -lt 10 ]; }; then
        log_error "Python 3.10+ required, found $pyver"
        return 1
    fi
    # Install python3-venv (version-specific for apt, generic for others)
    if command -v apt-get &>/dev/null; then
        apt-get install -y "python${pyver}-venv" 2>/dev/null || apt-get install -y python3-venv 2>/dev/null
    elif command -v dnf &>/dev/null; then
        dnf install -y python3-pip 2>/dev/null  # dnf includes venv in python3
    elif command -v yum &>/dev/null; then
        yum install -y python3-pip 2>/dev/null
    elif command -v apk &>/dev/null; then
        apk add py3-pip 2>/dev/null
    fi
    # Use venv (recreate if broken/incomplete)
    local VENV_DIR="$INSTALL_DIR/venv"
    if [ ! -x "$VENV_DIR/bin/pip" ]; then
        [ -d "$VENV_DIR" ] && rm -rf "$VENV_DIR"
        python3 -m venv "$VENV_DIR" || { log_error "Failed to create venv (is python3-venv installed?)"; return 1; }
    fi
    # Verify pip exists after venv creation
    if [ ! -x "$VENV_DIR/bin/pip" ]; then
        log_error "venv created but pip missing (install python${pyver}-venv)"
        return 1
    fi
    "$VENV_DIR/bin/pip" install --quiet --upgrade pip 2>/dev/null || true
    "$VENV_DIR/bin/pip" install --quiet scapy aioquic 2>/dev/null || { log_error "Failed to install Python packages"; return 1; }
    "$VENV_DIR/bin/python" -c "import scapy; import aioquic" 2>/dev/null || { log_error "Python deps verification failed"; return 1; }
    log_success "Python dependencies OK"
}

install_microsocks() {
    log_info "Installing microsocks..."
    [ -x "$INSTALL_DIR/bin/microsocks" ] && { log_success "microsocks already installed"; return 0; }
    command -v gcc &>/dev/null || {
        if command -v apt-get &>/dev/null; then apt-get install -y gcc make 2>/dev/null
        elif command -v yum &>/dev/null; then yum install -y gcc make 2>/dev/null
        elif command -v apk &>/dev/null; then apk add gcc make musl-dev 2>/dev/null
        fi
    }
    local tmp_dir; tmp_dir=$(mktemp -d)
    curl -sL "https://github.com/${MICROSOCKS_REPO}/archive/refs/heads/master.tar.gz" -o "$tmp_dir/ms.tar.gz" || { rm -rf "$tmp_dir"; return 1; }
    tar -xzf "$tmp_dir/ms.tar.gz" -C "$tmp_dir" 2>/dev/null || { rm -rf "$tmp_dir"; return 1; }
    local src; src=$(find "$tmp_dir" -maxdepth 1 -type d -name "microsocks*" | head -1)
    [ -z "$src" ] && { rm -rf "$tmp_dir"; return 1; }
    make -C "$src" -j"$(nproc 2>/dev/null || echo 1)" 2>/dev/null || { rm -rf "$tmp_dir"; return 1; }
    mkdir -p "$INSTALL_DIR/bin"
    cp "$src/microsocks" "$INSTALL_DIR/bin/microsocks"
    chmod 755 "$INSTALL_DIR/bin/microsocks"
    rm -rf "$tmp_dir"
    log_success "microsocks installed"
}

download_gfk() {
    log_info "Downloading GFW-knocker scripts..."
    mkdir -p "$GFK_DIR" || return 1
    # Note: parameters.py is generated by generate_gfk_config(), don't download it
    local f
    # Download server scripts from gfk/server/
    for f in mainserver.py quic_server.py vio_server.py; do
        curl -sL "$GFK_RAW_URL/server/$f" -o "$GFK_DIR/$f" || { log_error "Failed to download $f"; return 1; }
    done
    # Download client scripts from gfk/client/
    for f in mainclient.py quic_client.py vio_client.py; do
        curl -sL "$GFK_RAW_URL/client/$f" -o "$GFK_DIR/$f" || { log_error "Failed to download $f"; return 1; }
    done
    chmod 600 "$GFK_DIR"/*.py
    # Patch mainserver.py to use venv python for subprocesses
    [ -f "$GFK_DIR/mainserver.py" ] && sed -i "s|'python3'|'$INSTALL_DIR/venv/bin/python'|g" "$GFK_DIR/mainserver.py"
    log_success "GFW-knocker scripts downloaded"
}

generate_gfk_certs() {
    [ -f "$GFK_DIR/cert.pem" ] && [ -f "$GFK_DIR/key.pem" ] && return 0
    if ! command -v openssl &>/dev/null; then
        log_info "Installing openssl..."
        if command -v apt-get &>/dev/null; then apt-get install -y openssl 2>/dev/null
        elif command -v dnf &>/dev/null; then dnf install -y openssl 2>/dev/null
        elif command -v yum &>/dev/null; then yum install -y openssl 2>/dev/null
        elif command -v apk &>/dev/null; then apk add openssl 2>/dev/null
        elif command -v pacman &>/dev/null; then pacman -S --noconfirm openssl 2>/dev/null
        fi
        command -v openssl &>/dev/null || { log_error "Failed to install openssl"; return 1; }
    fi
    log_info "Generating QUIC certificates..."
    openssl req -x509 -newkey rsa:2048 -keyout "$GFK_DIR/key.pem" \
        -out "$GFK_DIR/cert.pem" -days 3650 -nodes -subj "/CN=gfk" 2>/dev/null || return 1
    chmod 600 "$GFK_DIR/key.pem" "$GFK_DIR/cert.pem"
    log_success "QUIC certificates generated"
}

generate_gfk_config() {
    log_info "Generating GFW-knocker config..."
    local _tmp; _tmp=$(mktemp "$GFK_DIR/parameters.py.XXXXXXXX") || { log_error "Failed to create temp file"; return 1; }
    local vio_tcp_server_port="${GFK_VIO_PORT:-45000}"
    local vio_tcp_client_port="${GFK_VIO_CLIENT_PORT:-40000}"
    local vio_udp_server_port="${GFK_VIO_UDP_SERVER:-35000}"
    local vio_udp_client_port="${GFK_VIO_UDP_CLIENT:-30000}"
    local quic_server_port="${GFK_QUIC_PORT:-25000}"
    local quic_client_port="${GFK_QUIC_CLIENT_PORT:-20000}"
    # Validate all ports are numeric
    local _p; for _p in "$vio_tcp_server_port" "$vio_tcp_client_port" "$vio_udp_server_port" \
              "$vio_udp_client_port" "$quic_server_port" "$quic_client_port"; do
        [[ "$_p" =~ ^[0-9]+$ ]] || { log_error "Invalid port: $_p"; rm -f "$_tmp"; return 1; }
    done
    # Escape Python strings to prevent code injection
    _esc_py() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//\'/\\\'}"; printf '%s' "$s"; }
    local safe_ip; safe_ip=$(_esc_py "${GFK_SERVER_IP:-}")
    local safe_auth; safe_auth=$(_esc_py "${GFK_AUTH_CODE:-}")
    local safe_dir; safe_dir=$(_esc_py "${GFK_DIR}")
    # Validate and build port mapping
    local tcp_mapping="${GFK_PORT_MAPPINGS:-14000:443}"
    local mapping_str="{" first=true pair lport rport
    for pair in $(echo "$tcp_mapping" | tr ',' ' '); do
        lport=$(echo "$pair" | cut -d: -f1); rport=$(echo "$pair" | cut -d: -f2)
        [[ "$lport" =~ ^[0-9]+$ ]] && [[ "$rport" =~ ^[0-9]+$ ]] || { log_error "Invalid mapping: $pair"; rm -f "$_tmp"; return 1; }
        [ "$first" = true ] && { mapping_str="${mapping_str}${lport}: ${rport}"; first=false; } || mapping_str="${mapping_str}, ${lport}: ${rport}"
    done
    mapping_str="${mapping_str}}"
    (umask 077; cat > "$_tmp" << PYEOF
vps_ip = "${safe_ip}"
xray_server_ip_address = "127.0.0.1"
tcp_port_mapping = ${mapping_str}
udp_port_mapping = {}
vio_tcp_server_port = ${vio_tcp_server_port}
vio_tcp_client_port = ${vio_tcp_client_port}
vio_udp_server_port = ${vio_udp_server_port}
vio_udp_client_port = ${vio_udp_client_port}
quic_server_port = ${quic_server_port}
quic_client_port = ${quic_client_port}
quic_local_ip = "127.0.0.1"
quic_idle_timeout = 86400
udp_timeout = 300
quic_mtu = 1420
quic_verify_cert = False
quic_max_data = 1073741824
quic_max_stream_data = 1073741824
quic_auth_code = "${safe_auth}"
quic_cert_filepath = ("${safe_dir}/cert.pem", "${safe_dir}/key.pem")
tcp_flags = "${GFK_TCP_FLAGS:-AP}"
PYEOF
    )
    mv "$_tmp" "$GFK_DIR/parameters.py" || { rm -f "$_tmp"; return 1; }
    chmod 600 "$GFK_DIR/parameters.py"
    log_success "GFW-knocker config saved"
}

create_gfk_client_wrapper() {
    local wrapper="$INSTALL_DIR/bin/gfk-client.sh"
    mkdir -p "$INSTALL_DIR/bin"
    cat > "$wrapper" << 'WEOF'
#!/bin/bash
set -e
GFK_DIR="REPLACE_GFK"
INSTALL_DIR="REPLACE_INST"
cd "$GFK_DIR"
"$INSTALL_DIR/venv/bin/python" mainclient.py &
PID1=$!
trap "kill $PID1 2>/dev/null; wait" EXIT INT TERM
wait
WEOF
    sed "s#REPLACE_GFK#${GFK_DIR}#g; s#REPLACE_INST#${INSTALL_DIR}#g" "$wrapper" > "$wrapper.sed" && mv "$wrapper.sed" "$wrapper"
    chmod 755 "$wrapper"
}

#═══════════════════════════════════════════════════════════════════════
# Service Control
#═══════════════════════════════════════════════════════════════════════

is_running() {
    # Check which backends are installed
    local paqet_installed=false gfk_installed=false
    [ -f "$INSTALL_DIR/bin/paqet" ] && paqet_installed=true
    if [ "$ROLE" = "server" ]; then
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_server.py" ] && gfk_installed=true
    else
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_client.py" ] && gfk_installed=true
    fi

    # If both backends installed, return true if EITHER is running
    if [ "$paqet_installed" = true ] && [ "$gfk_installed" = true ]; then
        is_paqet_running && return 0
        is_gfk_running && return 0
        return 1
    fi

    # Single backend mode - original logic
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl is-active paqctl.service &>/dev/null && return 0
    elif [ -f /run/paqctl.pid ]; then
        local _pid
        _pid=$(cat /run/paqctl.pid 2>/dev/null)
        # Validate PID is numeric and process exists
        [[ "$_pid" =~ ^[0-9]+$ ]] && kill -0 "$_pid" 2>/dev/null && return 0
    fi
    # Also check for the process directly with more specific patterns
    if [ "$BACKEND" = "gfw-knocker" ]; then
        # Use full path matching to avoid false positives
        pgrep -f "${GFK_DIR}/mainserver.py" &>/dev/null && return 0
        pgrep -f "${GFK_DIR}/mainclient.py" &>/dev/null && return 0
        pgrep -f "${INSTALL_DIR}/bin/gfk-client.sh" &>/dev/null && return 0
    else
        # Match specific config file path
        pgrep -f "${INSTALL_DIR}/bin/paqet run -c ${INSTALL_DIR}/config.yaml" &>/dev/null && return 0
    fi
    return 1
}

# Check if paqet backend specifically is running
is_paqet_running() {
    pgrep -f "${INSTALL_DIR}/bin/paqet run -c ${INSTALL_DIR}/config.yaml" &>/dev/null && return 0
    return 1
}

# Check if GFK backend specifically is running
is_gfk_running() {
    if [ "$ROLE" = "server" ]; then
        pgrep -f "${GFK_DIR}/mainserver.py" &>/dev/null && return 0
    else
        pgrep -f "${GFK_DIR}/mainclient.py" &>/dev/null && return 0
        pgrep -f "${INSTALL_DIR}/bin/gfk-client.sh" &>/dev/null && return 0
    fi
    return 1
}

# Start paqet backend only
start_paqet_backend() {
    if is_paqet_running; then
        log_warn "paqet is already running"
        return 0
    fi

    if [ ! -f "$INSTALL_DIR/bin/paqet" ]; then
        log_error "paqet binary not installed. Use 'Install additional backend' first."
        return 1
    fi

    # Generate config.yaml if missing - prompt for values
    if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
        echo ""
        echo -e "${YELLOW}config.yaml not found. Let's configure paqet:${NC}"
        echo ""

        detect_network
        local _det_iface="$DETECTED_IFACE"
        local _det_ip="$DETECTED_IP"
        local _det_mac="$DETECTED_GW_MAC"

        echo -e "${BOLD}Network Interface${NC} [${_det_iface:-eth0}]:"
        read -p "  Interface: " input < /dev/tty || true
        local _iface="${input:-${_det_iface:-eth0}}"

        echo -e "${BOLD}Local IP${NC} [${_det_ip:-}]:"
        read -p "  IP: " input < /dev/tty || true
        local _local_ip="${input:-$_det_ip}"

        echo -e "${BOLD}Gateway MAC${NC} [${_det_mac:-}]:"
        read -p "  MAC: " input < /dev/tty || true
        local _gw_mac="${input:-$_det_mac}"

        local _key
        _key=$("$INSTALL_DIR/bin/paqet" secret 2>/dev/null || true)
        if [ -z "$_key" ]; then
            _key=$(openssl rand -base64 32 2>/dev/null | tr -d '=+/' | head -c 32 || true)
        fi

        if [ "$ROLE" = "server" ]; then
            echo -e "${BOLD}Listen Port${NC} [8443]:"
            read -p "  Port: " input < /dev/tty || true
            local _port="${input:-8443}"

            echo ""
            echo -e "${GREEN}${BOLD}  Generated Key: ${_key}${NC}"
            echo -e "${BOLD}Encryption Key${NC} (Enter to use generated):"
            read -p "  Key: " input < /dev/tty || true
            [ -n "$input" ] && _key="$input"

            LISTEN_PORT="$_port"
            ENCRYPTION_KEY="$_key"

            cat > "$INSTALL_DIR/config.yaml" << EOFCFG
role: "server"
log:
  level: "info"
listen:
  addr: ":${_port}"
network:
  interface: "${_iface}"
  ipv4:
    addr: "${_local_ip}:${_port}"
    router_mac: "${_gw_mac}"
transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "${_key}"
EOFCFG
        else
            echo -e "${BOLD}Remote Server${NC} (IP:PORT):"
            read -p "  Server: " input < /dev/tty || true
            local _server="${input:-${REMOTE_SERVER:-}}"

            echo -e "${BOLD}Encryption Key${NC} (from server):"
            read -p "  Key: " input < /dev/tty || true
            [ -n "$input" ] && _key="$input"

            echo -e "${BOLD}SOCKS5 Port${NC} [1080]:"
            read -p "  Port: " input < /dev/tty || true
            local _socks="${input:-1080}"

            REMOTE_SERVER="$_server"
            SOCKS_PORT="$_socks"
            ENCRYPTION_KEY="$_key"

            cat > "$INSTALL_DIR/config.yaml" << EOFCFG
role: "client"
log:
  level: "info"
socks5:
  - listen: "127.0.0.1:${_socks}"
network:
  interface: "${_iface}"
  ipv4:
    addr: "${_local_ip}:0"
    router_mac: "${_gw_mac}"
server:
  addr: "${_server}"
transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "${_key}"
EOFCFG
        fi

        if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
            log_error "Failed to write config.yaml"
            return 1
        fi
        chmod 600 "$INSTALL_DIR/config.yaml" 2>/dev/null
        INTERFACE="$_iface"
        LOCAL_IP="$_local_ip"
        GATEWAY_MAC="$_gw_mac"
        save_settings 2>/dev/null || true
        log_success "Configuration saved"
        echo ""
    fi

    log_info "Starting paqet backend..."

    # Apply paqet firewall rules
    local _saved_backend="$BACKEND"
    BACKEND="paqet"
    _apply_firewall
    BACKEND="$_saved_backend"

    (umask 077; touch /var/log/paqet-backend.log)
    nohup "$INSTALL_DIR/bin/paqet" run -c "$INSTALL_DIR/config.yaml" > /var/log/paqet-backend.log 2>&1 &
    echo $! > /run/paqet-backend.pid

    sleep 2
    if is_paqet_running; then
        log_success "paqet backend started"
    else
        log_error "paqet failed to start. Check: tail /var/log/paqet-backend.log"
        return 1
    fi
}

# Stop paqet backend only
stop_paqet_backend() {
    if ! is_paqet_running; then
        log_warn "paqet is not running"
        return 0
    fi

    log_info "Stopping paqet backend..."

    if [ -f /run/paqet-backend.pid ]; then
        local _pid
        _pid=$(cat /run/paqet-backend.pid 2>/dev/null)
        if [ -n "$_pid" ] && [[ "$_pid" =~ ^[0-9]+$ ]]; then
            kill "$_pid" 2>/dev/null
            sleep 1
            kill -0 "$_pid" 2>/dev/null && kill -9 "$_pid" 2>/dev/null
        fi
        rm -f /run/paqet-backend.pid
    fi

    pkill -f "${INSTALL_DIR}/bin/paqet run -c" 2>/dev/null || true

    # Remove paqet firewall rules
    local _saved_backend="$BACKEND"
    BACKEND="paqet"
    _remove_firewall
    BACKEND="$_saved_backend"

    sleep 1
    if ! is_paqet_running; then
        log_success "paqet backend stopped"
    else
        pkill -9 -f "${INSTALL_DIR}/bin/paqet run -c" 2>/dev/null || true
        log_success "paqet backend stopped (forced)"
    fi
}

# Start GFK backend only
start_gfk_backend() {
    if is_gfk_running; then
        log_warn "gfw-knocker is already running"
        return 0
    fi

    if [ ! -d "$GFK_DIR" ] || [ ! -f "$GFK_DIR/quic_server.py" ]; then
        log_error "gfw-knocker not installed. Use 'Install additional backend' first."
        return 1
    fi

    log_info "Starting gfw-knocker backend..."

    # Apply GFK firewall rules
    local _saved_backend="$BACKEND"
    BACKEND="gfw-knocker"
    _apply_firewall
    BACKEND="$_saved_backend"

    (umask 077; touch /var/log/gfk-backend.log)

    if [ "$ROLE" = "server" ]; then
        # Start Xray if not running
        if command -v xray &>/dev/null || [ -x /usr/local/bin/xray ] || [ -x /usr/local/x-ui/bin/xray-linux-amd64 ]; then
            if ! pgrep -f "xray run" &>/dev/null; then
                systemctl start xray 2>/dev/null || xray run -c /usr/local/etc/xray/config.json &>/dev/null &
                sleep 2
            fi
        fi
        # Run from GFK_DIR so relative script paths work
        pushd "$GFK_DIR" >/dev/null
        nohup "$INSTALL_DIR/venv/bin/python" "$GFK_DIR/mainserver.py" > /var/log/gfk-backend.log 2>&1 &
        popd >/dev/null
    else
        if [ -x "$INSTALL_DIR/bin/gfk-client.sh" ]; then
            nohup "$INSTALL_DIR/bin/gfk-client.sh" > /var/log/gfk-backend.log 2>&1 &
        else
            # Run from GFK_DIR so relative script paths work
            pushd "$GFK_DIR" >/dev/null
            nohup "$INSTALL_DIR/venv/bin/python" "$GFK_DIR/mainclient.py" > /var/log/gfk-backend.log 2>&1 &
            popd >/dev/null
        fi
    fi
    echo $! > /run/gfk-backend.pid

    sleep 2
    if is_gfk_running; then
        log_success "gfw-knocker backend started"
    else
        log_error "gfw-knocker failed to start. Check: tail /var/log/gfk-backend.log"
        return 1
    fi
}

# Stop GFK backend only
stop_gfk_backend() {
    if ! is_gfk_running; then
        log_warn "gfw-knocker is not running"
        return 0
    fi

    log_info "Stopping gfw-knocker backend..."

    if [ -f /run/gfk-backend.pid ]; then
        local _pid
        _pid=$(cat /run/gfk-backend.pid 2>/dev/null)
        if [ -n "$_pid" ] && [[ "$_pid" =~ ^[0-9]+$ ]]; then
            kill "$_pid" 2>/dev/null
            sleep 1
            kill -0 "$_pid" 2>/dev/null && kill -9 "$_pid" 2>/dev/null
        fi
        rm -f /run/gfk-backend.pid
    fi

    pkill -f "${GFK_DIR}/mainserver.py" 2>/dev/null || true
    pkill -f "${GFK_DIR}/mainclient.py" 2>/dev/null || true
    pkill -f "${INSTALL_DIR}/bin/gfk-client.sh" 2>/dev/null || true
    pkill -f "${INSTALL_DIR}/bin/microsocks" 2>/dev/null || true

    # Remove GFK firewall rules
    local _saved_backend="$BACKEND"
    BACKEND="gfw-knocker"
    _remove_firewall
    BACKEND="$_saved_backend"

    sleep 1
    if ! is_gfk_running; then
        log_success "gfw-knocker backend stopped"
    else
        pkill -9 -f "${GFK_DIR}/mainserver.py" 2>/dev/null || true
        pkill -9 -f "${GFK_DIR}/mainclient.py" 2>/dev/null || true
        pkill -9 -f "${INSTALL_DIR}/bin/gfk-client.sh" 2>/dev/null || true
        log_success "gfw-knocker backend stopped (forced)"
    fi
}

start_paqet() {
    # Check which backends are installed
    local paqet_installed=false gfk_installed=false
    [ -f "$INSTALL_DIR/bin/paqet" ] && paqet_installed=true
    if [ "$ROLE" = "server" ]; then
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_server.py" ] && gfk_installed=true
    else
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_client.py" ] && gfk_installed=true
    fi

    # If both backends installed, start both
    if [ "$paqet_installed" = true ] && [ "$gfk_installed" = true ]; then
        local started_something=false
        if ! is_paqet_running; then
            start_paqet_backend && started_something=true
        else
            log_warn "paqet is already running"
        fi
        if ! is_gfk_running; then
            start_gfk_backend && started_something=true
        else
            log_warn "gfw-knocker is already running"
        fi
        [ "$started_something" = true ] && return 0
        return 0
    fi

    # Single backend mode - original logic
    if is_running; then
        log_warn "${BACKEND} is already running"
        return 0
    fi

    log_info "Starting paqet..."
    local _direct_start=false

    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl start paqctl.service 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service paqctl start 2>/dev/null
    elif [ -x /etc/init.d/paqctl ]; then
        /etc/init.d/paqctl start 2>/dev/null
    else
        # Direct start - track for cleanup on failure
        _direct_start=true
        _apply_firewall
        (umask 077; touch /var/log/paqctl.log)
        if [ "$BACKEND" = "gfw-knocker" ]; then
            if [ "$ROLE" = "client" ] && [ -x "$INSTALL_DIR/bin/gfk-client.sh" ]; then
                nohup "$INSTALL_DIR/bin/gfk-client.sh" > /var/log/paqctl.log 2>&1 &
            else
                nohup "$INSTALL_DIR/venv/bin/python" "$GFK_DIR/mainserver.py" > /var/log/paqctl.log 2>&1 &
            fi
        else
            nohup "$INSTALL_DIR/bin/paqet" run -c "$INSTALL_DIR/config.yaml" > /var/log/paqctl.log 2>&1 &
        fi
        echo $! > /run/paqctl.pid
    fi

    sleep 2
    if is_running; then
        log_success "${BACKEND} started successfully"
    else
        log_error "${BACKEND} failed to start. Check logs: sudo paqctl logs"
        # Clean up firewall rules on failure (only for direct start)
        if [ "$_direct_start" = true ]; then
            _remove_firewall
        fi
        return 1
    fi
}

stop_paqet() {
    # Check which backends are installed
    local paqet_installed=false gfk_installed=false
    [ -f "$INSTALL_DIR/bin/paqet" ] && paqet_installed=true
    if [ "$ROLE" = "server" ]; then
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_server.py" ] && gfk_installed=true
    else
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_client.py" ] && gfk_installed=true
    fi

    # If both backends installed, stop both
    if [ "$paqet_installed" = true ] && [ "$gfk_installed" = true ]; then
        local stopped_something=false
        if is_paqet_running; then
            stop_paqet_backend && stopped_something=true
        fi
        if is_gfk_running; then
            stop_gfk_backend && stopped_something=true
        fi
        if [ "$stopped_something" = false ]; then
            log_warn "No backends are running"
        fi
        return 0
    fi

    # Single backend mode - original logic
    if ! is_running; then
        log_warn "paqet is not running"
        return 0
    fi

    log_info "Stopping paqet..."

    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl stop paqctl.service 2>/dev/null
    elif command -v rc-service &>/dev/null; then
        rc-service paqctl stop 2>/dev/null
    elif [ -x /etc/init.d/paqctl ]; then
        /etc/init.d/paqctl stop 2>/dev/null
    else
        if [ -f /run/paqctl.pid ]; then
            local _pid
            _pid=$(cat /run/paqctl.pid 2>/dev/null)
            if [ -n "$_pid" ]; then
                kill "$_pid" 2>/dev/null
                local _count=0
                while kill -0 "$_pid" 2>/dev/null && [ $_count -lt 10 ]; do
                    sleep 1
                    _count=$((_count + 1))
                done
                kill -0 "$_pid" 2>/dev/null && kill -9 "$_pid" 2>/dev/null
            fi
            rm -f /run/paqctl.pid
        fi
        # Use specific paths to avoid killing unrelated processes
        if [ "$BACKEND" = "gfw-knocker" ]; then
            pkill -f "${GFK_DIR}/mainserver.py" 2>/dev/null || true
            pkill -f "${GFK_DIR}/mainclient.py" 2>/dev/null || true
            pkill -f "${INSTALL_DIR}/bin/gfk-client.sh" 2>/dev/null || true
            pkill -f "${INSTALL_DIR}/bin/microsocks" 2>/dev/null || true
        else
            pkill -f "${INSTALL_DIR}/bin/paqet run -c" 2>/dev/null || true
        fi
        _remove_firewall
    fi

    sleep 1
    if ! is_running; then
        log_success "${BACKEND} stopped"
    else
        log_warn "${BACKEND} may still be running, force killing..."
        if [ "$BACKEND" = "gfw-knocker" ]; then
            pkill -9 -f "${GFK_DIR}/mainserver.py" 2>/dev/null || true
            pkill -9 -f "${GFK_DIR}/mainclient.py" 2>/dev/null || true
            pkill -9 -f "${INSTALL_DIR}/bin/gfk-client.sh" 2>/dev/null || true
            pkill -9 -f "${INSTALL_DIR}/bin/microsocks" 2>/dev/null || true
        else
            pkill -9 -f "${INSTALL_DIR}/bin/paqet run -c" 2>/dev/null || true
        fi
        sleep 1
        log_success "${BACKEND} stopped"
    fi
}

restart_paqet() {
    stop_paqet
    sleep 1
    start_paqet
}

#═══════════════════════════════════════════════════════════════════════
# Firewall (internal commands)
#═══════════════════════════════════════════════════════════════════════

_is_firewalld_active() {
    command -v firewall-cmd &>/dev/null && firewall-cmd --state 2>/dev/null | grep -q running
}

_apply_firewall() {
    if ! _is_firewalld_active && ! command -v iptables &>/dev/null; then
        echo -e "${YELLOW}[!]${NC} No firewall backend found (iptables or firewalld)." >&2
        return 1
    fi

    if [ "$BACKEND" = "gfw-knocker" ]; then
        local vio_port
        if [ "$ROLE" = "server" ]; then
            vio_port="${GFK_VIO_PORT:-45000}"
        else
            vio_port="${GFK_VIO_CLIENT_PORT:-40000}"
        fi

        if _is_firewalld_active; then
            firewall-cmd --direct --query-rule ipv4 raw PREROUTING 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                firewall-cmd --direct --add-rule ipv4 raw PREROUTING 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
            firewall-cmd --direct --query-rule ipv4 raw OUTPUT 0 -p tcp --sport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                firewall-cmd --direct --add-rule ipv4 raw OUTPUT 0 -p tcp --sport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
            firewall-cmd --direct --query-rule ipv4 filter INPUT 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                firewall-cmd --direct --add-rule ipv4 filter INPUT 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                echo -e "${YELLOW}[!]${NC} Failed to add VIO port DROP rule via firewalld" >&2
            firewall-cmd --direct --query-rule ipv4 filter OUTPUT 0 -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                firewall-cmd --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                echo -e "${YELLOW}[!]${NC} Failed to add RST DROP rule via firewalld" >&2
            firewall-cmd --direct --query-rule ipv6 filter INPUT 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                firewall-cmd --direct --add-rule ipv6 filter INPUT 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
            firewall-cmd --direct --query-rule ipv6 filter OUTPUT 0 -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                firewall-cmd --direct --add-rule ipv6 filter OUTPUT 0 -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        else
            local TAG="paqctl"
            modprobe iptable_raw 2>/dev/null || true
            iptables -t raw -C PREROUTING -p tcp --dport "$vio_port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
                iptables -t raw -A PREROUTING -p tcp --dport "$vio_port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
            iptables -t raw -C OUTPUT -p tcp --sport "$vio_port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
                iptables -t raw -A OUTPUT -p tcp --sport "$vio_port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
            iptables -C INPUT -p tcp --dport "$vio_port" -m comment --comment "$TAG" -j DROP 2>/dev/null || \
                iptables -A INPUT -p tcp --dport "$vio_port" -m comment --comment "$TAG" -j DROP 2>/dev/null || \
                echo -e "${YELLOW}[!]${NC} Failed to add VIO port DROP rule" >&2
            iptables -C OUTPUT -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "$TAG" -j DROP 2>/dev/null || \
                iptables -A OUTPUT -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "$TAG" -j DROP 2>/dev/null || \
                echo -e "${YELLOW}[!]${NC} Failed to add RST DROP rule" >&2
            if command -v ip6tables &>/dev/null; then
                ip6tables -C INPUT -p tcp --dport "$vio_port" -m comment --comment "$TAG" -j DROP 2>/dev/null || \
                    ip6tables -A INPUT -p tcp --dport "$vio_port" -m comment --comment "$TAG" -j DROP 2>/dev/null || true
                ip6tables -C OUTPUT -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "$TAG" -j DROP 2>/dev/null || \
                    ip6tables -A OUTPUT -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "$TAG" -j DROP 2>/dev/null || true
            fi
        fi
        return 0
    fi

    [ "$ROLE" != "server" ] && return 0
    local port="${LISTEN_PORT:-8443}"

    if _is_firewalld_active; then
        firewall-cmd --direct --query-rule ipv4 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
            firewall-cmd --direct --add-rule ipv4 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
            echo -e "${YELLOW}[!]${NC} Failed to add PREROUTING NOTRACK rule via firewalld" >&2
        firewall-cmd --direct --query-rule ipv4 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
            firewall-cmd --direct --add-rule ipv4 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
            echo -e "${YELLOW}[!]${NC} Failed to add OUTPUT NOTRACK rule via firewalld" >&2
        firewall-cmd --direct --query-rule ipv4 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
            firewall-cmd --direct --add-rule ipv4 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
            echo -e "${YELLOW}[!]${NC} Failed to add RST DROP rule via firewalld" >&2
        firewall-cmd --direct --query-rule ipv6 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
            firewall-cmd --direct --add-rule ipv6 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --query-rule ipv6 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
            firewall-cmd --direct --add-rule ipv6 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --query-rule ipv6 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
            firewall-cmd --direct --add-rule ipv6 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
    else
        local TAG="paqctl"
        modprobe iptable_raw 2>/dev/null || true
        modprobe iptable_mangle 2>/dev/null || true
        iptables -t raw -C PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
            iptables -t raw -A PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
            echo -e "${YELLOW}[!]${NC} Failed to add PREROUTING NOTRACK rule" >&2
        iptables -t raw -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
            iptables -t raw -A OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
            echo -e "${YELLOW}[!]${NC} Failed to add OUTPUT NOTRACK rule" >&2
        iptables -t mangle -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || \
            iptables -t mangle -A OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || \
            echo -e "${YELLOW}[!]${NC} Failed to add RST DROP rule" >&2
        if command -v ip6tables &>/dev/null; then
            ip6tables -t raw -C PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
                ip6tables -t raw -A PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
            ip6tables -t raw -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || \
                ip6tables -t raw -A OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
            ip6tables -t mangle -C OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || \
                ip6tables -t mangle -A OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || true
        fi
    fi
}

_remove_firewall() {
    if ! _is_firewalld_active && ! command -v iptables &>/dev/null; then
        return 0
    fi

    if [ "$BACKEND" = "gfw-knocker" ]; then
        local vio_port
        if [ "$ROLE" = "server" ]; then
            vio_port="${GFK_VIO_PORT:-45000}"
        else
            vio_port="${GFK_VIO_CLIENT_PORT:-40000}"
        fi

        if _is_firewalld_active; then
            firewall-cmd --direct --remove-rule ipv4 raw PREROUTING 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
            firewall-cmd --direct --remove-rule ipv4 raw OUTPUT 0 -p tcp --sport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
            firewall-cmd --direct --remove-rule ipv4 filter INPUT 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
            firewall-cmd --direct --remove-rule ipv4 filter OUTPUT 0 -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
            firewall-cmd --direct --remove-rule ipv6 filter INPUT 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
            firewall-cmd --direct --remove-rule ipv6 filter OUTPUT 0 -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        else
            local TAG="paqctl"
            iptables -t raw -D PREROUTING -p tcp --dport "$vio_port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
            iptables -t raw -D OUTPUT -p tcp --sport "$vio_port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
            iptables -t raw -D PREROUTING -p tcp --dport "$vio_port" -j NOTRACK 2>/dev/null || true
            iptables -t raw -D OUTPUT -p tcp --sport "$vio_port" -j NOTRACK 2>/dev/null || true
            iptables -D INPUT -p tcp --dport "$vio_port" -m comment --comment "$TAG" -j DROP 2>/dev/null || true
            iptables -D OUTPUT -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "$TAG" -j DROP 2>/dev/null || true
            iptables -D INPUT -p tcp --dport "$vio_port" -j DROP 2>/dev/null || true
            iptables -D OUTPUT -p tcp --sport "$vio_port" --tcp-flags RST RST -j DROP 2>/dev/null || true
            if command -v ip6tables &>/dev/null; then
                ip6tables -D INPUT -p tcp --dport "$vio_port" -m comment --comment "$TAG" -j DROP 2>/dev/null || true
                ip6tables -D OUTPUT -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "$TAG" -j DROP 2>/dev/null || true
                ip6tables -D INPUT -p tcp --dport "$vio_port" -j DROP 2>/dev/null || true
                ip6tables -D OUTPUT -p tcp --sport "$vio_port" --tcp-flags RST RST -j DROP 2>/dev/null || true
            fi
        fi
        return 0
    fi

    [ "$ROLE" != "server" ] && return 0
    local port="${LISTEN_PORT:-8443}"

    if _is_firewalld_active; then
        firewall-cmd --direct --remove-rule ipv4 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv4 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv6 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv6 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
        firewall-cmd --direct --remove-rule ipv6 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
    else
        local TAG="paqctl"
        iptables -t raw -D PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
        iptables -t raw -D OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || true
        iptables -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || true
        iptables -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || true
        iptables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
        if command -v ip6tables &>/dev/null; then
            ip6tables -t raw -D PREROUTING -p tcp --dport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
            ip6tables -t raw -D OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" -j NOTRACK 2>/dev/null || true
            ip6tables -t mangle -D OUTPUT -p tcp --sport "$port" -m comment --comment "$TAG" --tcp-flags RST RST -j DROP 2>/dev/null || true
            ip6tables -t raw -D PREROUTING -p tcp --dport "$port" -j NOTRACK 2>/dev/null || true
            ip6tables -t raw -D OUTPUT -p tcp --sport "$port" -j NOTRACK 2>/dev/null || true
            ip6tables -t mangle -D OUTPUT -p tcp --sport "$port" --tcp-flags RST RST -j DROP 2>/dev/null || true
        fi
    fi
}

# Remove ALL paqctl-tagged firewall rules (for complete uninstall)
_remove_all_paqctl_firewall_rules() {
    # firewalld: remove paqctl-tagged direct rules
    if _is_firewalld_active; then
        local _rules
        _rules=$(firewall-cmd --direct --get-all-rules 2>/dev/null) || true
        if [ -n "$_rules" ]; then
            echo "$_rules" | grep "paqctl" | while IFS= read -r _rule; do
                firewall-cmd --direct --remove-rule $_rule 2>/dev/null || true
                firewall-cmd --permanent --direct --remove-rule $_rule 2>/dev/null || true
            done
        fi
        return 0
    fi

    command -v iptables &>/dev/null || return 0
    local TAG="paqctl"

    # Remove all rules with "paqctl" comment from all tables
    # Loop to remove multiple rules if port was changed
    local i
    for i in {1..10}; do
        iptables -t raw -S 2>/dev/null | grep -q "paqctl" || break
        iptables -t raw -S 2>/dev/null | grep "paqctl" | while read -r rule; do
            # Convert -A to -D for deletion
            local del_rule="${rule/-A /-D }"
            eval "iptables -t raw $del_rule" 2>/dev/null || true
        done
    done

    for i in {1..10}; do
        iptables -t mangle -S 2>/dev/null | grep -q "paqctl" || break
        iptables -t mangle -S 2>/dev/null | grep "paqctl" | while read -r rule; do
            local del_rule="${rule/-A /-D }"
            eval "iptables -t mangle $del_rule" 2>/dev/null || true
        done
    done

    for i in {1..10}; do
        iptables -S 2>/dev/null | grep -q "paqctl" || break
        iptables -S 2>/dev/null | grep "paqctl" | while read -r rule; do
            local del_rule="${rule/-A /-D }"
            eval "iptables $del_rule" 2>/dev/null || true
        done
    done

    # Same for IPv6
    if command -v ip6tables &>/dev/null; then
        for i in {1..10}; do
            ip6tables -t raw -S 2>/dev/null | grep -q "paqctl" || break
            ip6tables -t raw -S 2>/dev/null | grep "paqctl" | while read -r rule; do
                local del_rule="${rule/-A /-D }"
                eval "ip6tables -t raw $del_rule" 2>/dev/null || true
            done
        done

        for i in {1..10}; do
            ip6tables -t mangle -S 2>/dev/null | grep -q "paqctl" || break
            ip6tables -t mangle -S 2>/dev/null | grep "paqctl" | while read -r rule; do
                local del_rule="${rule/-A /-D }"
                eval "ip6tables -t mangle $del_rule" 2>/dev/null || true
            done
        done

        for i in {1..10}; do
            ip6tables -S 2>/dev/null | grep -q "paqctl" || break
            ip6tables -S 2>/dev/null | grep "paqctl" | while read -r rule; do
                local del_rule="${rule/-A /-D }"
                eval "ip6tables $del_rule" 2>/dev/null || true
            done
        done
    fi
}

_persist_firewall() {
    if _is_firewalld_active; then
        firewall-cmd --runtime-to-permanent 2>/dev/null || true
        return 0
    fi
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &>/dev/null; then
        if [ -d /etc/iptables ]; then
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            command -v ip6tables-save &>/dev/null && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        elif [ -f /etc/debian_version ] && [ ! -d /etc/iptables ]; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            command -v ip6tables-save &>/dev/null && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
        elif [ -d /etc/sysconfig ]; then
            iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
            command -v ip6tables-save &>/dev/null && ip6tables-save > /etc/sysconfig/ip6tables 2>/dev/null || true
        fi
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Status & Info
#═══════════════════════════════════════════════════════════════════════

show_status() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  PAQCTL STATUS (${BACKEND})${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    # Running status
    if is_running; then
        echo -e "  Status:     ${GREEN}● Running${NC}"
        # Uptime
        if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
            local started
            started=$(systemctl show paqctl.service --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
            if [ -n "$started" ]; then
                local started_ts
                started_ts=$(date -d "$started" +%s 2>/dev/null || echo 0)
                if [ "$started_ts" -gt 0 ] 2>/dev/null; then
                    local now=$(date +%s)
                    local up=$((now - started_ts))
                    local days=$((up / 86400))
                    local hours=$(( (up % 86400) / 3600 ))
                    local mins=$(( (up % 3600) / 60 ))
                    if [ "$days" -gt 0 ]; then
                        echo -e "  Uptime:     ${days}d ${hours}h ${mins}m"
                    else
                        echo -e "  Uptime:     ${hours}h ${mins}m"
                    fi
                fi
            fi
        fi
        # PID
        local pid
        if [ "$BACKEND" = "gfw-knocker" ]; then
            pid=$(pgrep -f "mainserver.py|mainclient.py" 2>/dev/null | head -1)
        else
            pid=$(pgrep -f "paqet run -c" 2>/dev/null | head -1)
        fi
        [ -n "$pid" ] && echo -e "  PID:        $pid"

        # CPU/RAM of process
        if [ -n "$pid" ]; then
            local cpu_mem
            cpu_mem=$(ps -p "$pid" -o %cpu=,%mem= 2>/dev/null | head -1)
            if [ -n "$cpu_mem" ]; then
                local cpu=$(echo "$cpu_mem" | awk '{print $1}')
                local mem=$(echo "$cpu_mem" | awk '{print $2}')
                echo -e "  CPU:        ${cpu}%"
                echo -e "  Memory:     ${mem}%"
            fi
        fi
    else
        echo -e "  Status:     ${RED}● Stopped${NC}"
    fi

    echo ""
    echo -e "  ${DIM}── Configuration ──${NC}"
    echo -e "  Backend:    ${BOLD}${BACKEND}${NC}"
    echo -e "  Role:       ${BOLD}${ROLE}${NC}"
    echo -e "  Version:    ${PAQET_VERSION}"

    if [ "$BACKEND" = "gfw-knocker" ]; then
        echo -e "  Server IP:  ${GFK_SERVER_IP}"
        echo -e "  VIO port:   ${GFK_VIO_PORT}"
        echo -e "  QUIC port:  ${GFK_QUIC_PORT}"
        if [ "$ROLE" = "server" ]; then
            if [ "${XRAY_PANEL_DETECTED:-false}" = "true" ] && [ -n "${GFK_SOCKS_VIO_PORT:-}" ]; then
                local _md=""
                IFS=',' read -ra _pairs <<< "${GFK_PORT_MAPPINGS}"
                for _p in "${_pairs[@]}"; do
                    if [ "${_p%%:*}" = "${GFK_SOCKS_VIO_PORT}" ]; then
                        _md="${_md:+${_md}, }${_p} (SOCKS5)"
                    else
                        _md="${_md:+${_md}, }${_p} (panel)"
                    fi
                done
                echo -e "  Mappings:   ${_md}"
                echo -e "  SOCKS5:     ${GREEN}127.0.0.1:${GFK_SOCKS_PORT}${NC} (server-side)"
                echo -e "  Client use: ${GREEN}127.0.0.1:${GFK_SOCKS_VIO_PORT}${NC} (set as proxy on client)"
            elif [ "${XRAY_PANEL_DETECTED:-false}" = "true" ]; then
                echo -e "  Mappings:   ${GFK_PORT_MAPPINGS}"
                echo -e "  SOCKS5:     ${YELLOW}not configured${NC}"
            else
                echo -e "  Mappings:   ${GFK_PORT_MAPPINGS}"
                local _srv_port _cli_port
                _srv_port=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f2)
                _cli_port=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f1)
                echo -e "  SOCKS5:     ${GREEN}127.0.0.1:${_srv_port}${NC} (server-side)"
                echo -e "  Client use: ${GREEN}127.0.0.1:${_cli_port}${NC} (set as proxy on client)"
            fi
            echo -e "  Auth code:  ${GFK_AUTH_CODE:0:8}..."
            local _vio_port="${GFK_VIO_PORT:-45000}"
            local _input_ok=false _rst_ok=false
            if iptables -C INPUT -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
               iptables -C INPUT -p tcp --dport "$_vio_port" -j DROP 2>/dev/null; then
                _input_ok=true
            fi
            if iptables -C OUTPUT -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
               iptables -C OUTPUT -p tcp --sport "$_vio_port" --tcp-flags RST RST -j DROP 2>/dev/null; then
                _rst_ok=true
            fi
            if [ "$_input_ok" = true ] && [ "$_rst_ok" = true ]; then
                echo -e "  Firewall:   ${GREEN}VIO port blocked${NC}"
            elif [ "$_input_ok" = true ]; then
                echo -e "  Firewall:   ${YELLOW}Partial (RST DROP missing)${NC}"
            else
                echo -e "  Firewall:   ${RED}VIO port NOT blocked${NC}"
            fi
        else
            echo -e "  Mappings:   ${GFK_PORT_MAPPINGS}"
            local _fv
            if [ -n "${GFK_SOCKS_VIO_PORT:-}" ]; then
                _fv="$GFK_SOCKS_VIO_PORT"
            else
                _fv=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f1)
            fi
            echo -e "  Proxy:      ${GREEN}SOCKS5 127.0.0.1:${_fv}${NC} (set as browser proxy)"
        fi
    else
        echo -e "  Interface:  ${INTERFACE}"
        echo -e "  Local IP:   ${LOCAL_IP}"
        if [ "$ROLE" = "server" ]; then
            echo -e "  Port:       ${LISTEN_PORT}"
            echo -e "  Key:        ${ENCRYPTION_KEY:0:8}..."
            if iptables -t raw -C PREROUTING -p tcp --dport "$LISTEN_PORT" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null; then
                echo -e "  Firewall:   ${GREEN}Rules active${NC}"
            else
                echo -e "  Firewall:   ${RED}Rules missing${NC}"
            fi
        else
            echo -e "  Server:     ${REMOTE_SERVER}"
            echo -e "  SOCKS port: ${SOCKS_PORT}"
            echo -e "  Key:        ${ENCRYPTION_KEY:0:8}..."
        fi
    fi

    # Telegram
    if [ "$TELEGRAM_ENABLED" = "true" ]; then
        echo -e "  Telegram:   ${GREEN}Enabled${NC}"
    else
        echo -e "  Telegram:   ${DIM}Disabled${NC}"
    fi

    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Logs
#═══════════════════════════════════════════════════════════════════════

show_logs() {
    echo ""
    log_info "Showing paqet logs (Ctrl+C to return to menu)..."
    echo ""

    # Trap Ctrl+C to return to menu instead of exiting
    trap 'echo ""; log_info "Returning to menu..."; return 0' INT

    if command -v journalctl &>/dev/null && [ -d /run/systemd/system ]; then
        journalctl -u paqctl.service -f --no-pager -n 50
    elif [ -f /var/log/paqctl.log ]; then
        tail -f -n 50 /var/log/paqctl.log
    else
        log_warn "No logs found. Is paqet running?"
    fi

    # Restore default trap
    trap - INT
}

#═══════════════════════════════════════════════════════════════════════
# Health Check
#═══════════════════════════════════════════════════════════════════════

health_check() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  HEALTH CHECK${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    local issues=0

    if [ "$BACKEND" = "gfw-knocker" ]; then
        # 1. Python scripts exist
        if [ -f "$GFK_DIR/mainserver.py" ] && [ -f "$GFK_DIR/mainclient.py" ]; then
            echo -e "  ${GREEN}✓${NC} GFW-knocker scripts found"
        else
            echo -e "  ${RED}✗${NC} GFW-knocker scripts missing from $GFK_DIR"
            issues=$((issues + 1))
        fi

        # 2. Python + deps (check venv)
        if [ -x "$INSTALL_DIR/venv/bin/python" ] && "$INSTALL_DIR/venv/bin/python" -c "import scapy; import aioquic" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Python dependencies OK (scapy, aioquic)"
        else
            echo -e "  ${RED}✗${NC} Python dependencies missing (venv not setup)"
            issues=$((issues + 1))
        fi

        # 3. Config
        if [ -f "$GFK_DIR/parameters.py" ]; then
            echo -e "  ${GREEN}✓${NC} GFK configuration found"
        else
            echo -e "  ${RED}✗${NC} GFK configuration missing"
            issues=$((issues + 1))
        fi

        # 4. Certificates
        if [ -f "$GFK_DIR/cert.pem" ] && [ -f "$GFK_DIR/key.pem" ]; then
            echo -e "  ${GREEN}✓${NC} QUIC certificates found"
        else
            echo -e "  ${RED}✗${NC} QUIC certificates missing"
            issues=$((issues + 1))
        fi

        # 5. Service running
        if is_running; then
            echo -e "  ${GREEN}✓${NC} GFW-knocker is running"
        else
            echo -e "  ${RED}✗${NC} GFW-knocker is not running"
            issues=$((issues + 1))
        fi

        # 6. Firewall (server)
        if [ "$ROLE" = "server" ]; then
            # Check both tagged and untagged rules (tagged added by _apply_firewall, untagged by install wizard)
            local _vio_port="${GFK_VIO_PORT:-45000}"
            if iptables -C INPUT -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
               iptables -C INPUT -p tcp --dport "$_vio_port" -j DROP 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} VIO port ${_vio_port} INPUT blocked"
            else
                echo -e "  ${RED}✗${NC} VIO port ${_vio_port} INPUT NOT blocked"
                issues=$((issues + 1))
            fi
            # Check RST DROP rule (prevents kernel from sending RST packets)
            if iptables -C OUTPUT -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
               iptables -C OUTPUT -p tcp --sport "$_vio_port" --tcp-flags RST RST -j DROP 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} VIO port ${_vio_port} RST DROP in place"
            else
                echo -e "  ${RED}✗${NC} VIO port ${_vio_port} RST DROP missing"
                issues=$((issues + 1))
            fi
        fi

        # 7. SOCKS5 port (client)
        if [ "$ROLE" = "client" ]; then
            local _socks_vio
            if [ -n "${GFK_SOCKS_VIO_PORT:-}" ]; then
                _socks_vio="$GFK_SOCKS_VIO_PORT"
            else
                _socks_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f1)
            fi
            if is_running && ss -tlnp 2>/dev/null | grep -q ":${_socks_vio} "; then
                echo -e "  ${GREEN}✓${NC} SOCKS5 port ${_socks_vio} is listening"
            elif is_running; then
                echo -e "  ${RED}✗${NC} SOCKS5 port ${_socks_vio} not listening"
                issues=$((issues + 1))
            fi
        fi
    else
        # 1. Binary exists
        if [ -x "$INSTALL_DIR/bin/paqet" ]; then
            echo -e "  ${GREEN}✓${NC} paqet binary found"
        else
            echo -e "  ${RED}✗${NC} paqet binary not found at $INSTALL_DIR/bin/paqet"
            issues=$((issues + 1))
        fi

        # 2. Config exists
        if [ -f "$INSTALL_DIR/config.yaml" ]; then
            echo -e "  ${GREEN}✓${NC} Configuration file found"
        else
            echo -e "  ${RED}✗${NC} Configuration file missing"
            issues=$((issues + 1))
        fi

        # 3. Service running
        if is_running; then
            echo -e "  ${GREEN}✓${NC} paqet is running"
        else
            echo -e "  ${RED}✗${NC} paqet is not running"
            issues=$((issues + 1))
        fi

        # 4. libpcap
        if ldconfig -p 2>/dev/null | grep -q libpcap; then
            echo -e "  ${GREEN}✓${NC} libpcap is available"
        else
            echo -e "  ${YELLOW}!${NC} libpcap not found in ldconfig (may still work)"
        fi

        # 5. iptables (server only)
        if [ "$ROLE" = "server" ]; then
            if iptables -t raw -C PREROUTING -p tcp --dport "$LISTEN_PORT" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} iptables NOTRACK rules in place (port $LISTEN_PORT)"
            else
                echo -e "  ${RED}✗${NC} iptables NOTRACK rules missing for port $LISTEN_PORT"
                issues=$((issues + 1))
            fi

            if iptables -t mangle -C OUTPUT -p tcp --sport "$LISTEN_PORT" -m comment --comment "paqctl" --tcp-flags RST RST -j DROP 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} iptables RST DROP rule in place"
            else
                echo -e "  ${RED}✗${NC} iptables RST DROP rule missing"
                issues=$((issues + 1))
            fi
        fi

        # 6. Port listening (server) or connectivity (client)
        if [ "$ROLE" = "server" ] && is_running; then
            if ss -tlnp 2>/dev/null | grep -q ":${LISTEN_PORT}"; then
                echo -e "  ${GREEN}✓${NC} Port $LISTEN_PORT is listening"
            else
                echo -e "  ${YELLOW}!${NC} Port $LISTEN_PORT not shown in ss (paqet uses raw sockets)"
            fi
        fi

        if [ "$ROLE" = "client" ] && is_running; then
            if ss -tlnp 2>/dev/null | grep -q ":${SOCKS_PORT}"; then
                echo -e "  ${GREEN}✓${NC} SOCKS5 port $SOCKS_PORT is listening"
            else
                echo -e "  ${RED}✗${NC} SOCKS5 port $SOCKS_PORT is not listening"
                issues=$((issues + 1))
            fi
        fi

        # 7. Paqet ping test
        if is_running && [ -x "$INSTALL_DIR/bin/paqet" ]; then
            echo -e "  ${DIM}Running paqet ping test...${NC}"
            local ping_result
            ping_result=$(timeout 10 "$INSTALL_DIR/bin/paqet" ping -c "$INSTALL_DIR/config.yaml" 2>&1 || true)
            if echo "$ping_result" | grep -qi "success\|pong\|ok\|alive\|rtt"; then
                echo -e "  ${GREEN}✓${NC} Paqet ping: OK"
            elif [ -n "$ping_result" ]; then
                echo -e "  ${YELLOW}!${NC} Paqet ping: $(echo "$ping_result" | head -1)"
            else
                echo -e "  ${YELLOW}!${NC} Paqet ping: no response (may not be supported)"
            fi
        fi
    fi

    # 8. Network connectivity
    if curl -s --max-time 5 https://api.github.com &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} Internet connectivity: OK"
    else
        echo -e "  ${YELLOW}!${NC} Cannot reach GitHub API (may be firewall/network)"
    fi

    # 9. Systemd service
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        if systemctl is-enabled paqctl.service &>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Auto-start on boot: enabled"
        else
            echo -e "  ${YELLOW}!${NC} Auto-start on boot: disabled"
        fi
    fi

    echo ""
    if [ "$issues" -eq 0 ]; then
        echo -e "  ${GREEN}${BOLD}All checks passed!${NC}"
    else
        echo -e "  ${RED}${BOLD}$issues issue(s) found${NC}"
    fi
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Update
#═══════════════════════════════════════════════════════════════════════

update_gfk() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  UPDATE GFW-KNOCKER${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    log_info "Downloading latest GFW-knocker scripts..."
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local server_files="mainserver.py quic_server.py vio_server.py"
    local client_files="mainclient.py quic_client.py vio_client.py"
    local f changed=false
    # Download server scripts
    for f in $server_files; do
        if ! curl -sL "$GFK_RAW_URL/server/$f" -o "$tmp_dir/$f"; then
            log_error "Failed to download $f"
            rm -rf "$tmp_dir"
            return 1
        fi
        if ! diff -q "$tmp_dir/$f" "$GFK_DIR/$f" &>/dev/null; then
            changed=true
        fi
    done
    # Download client scripts
    for f in $client_files; do
        if ! curl -sL "$GFK_RAW_URL/client/$f" -o "$tmp_dir/$f"; then
            log_error "Failed to download $f"
            rm -rf "$tmp_dir"
            return 1
        fi
        if ! diff -q "$tmp_dir/$f" "$GFK_DIR/$f" &>/dev/null; then
            changed=true
        fi
    done

    if [ "$changed" = true ]; then
        local was_running=false
        is_running && was_running=true
        [ "$was_running" = true ] && stop_paqet

        # Backup old scripts
        mkdir -p "$BACKUP_DIR"
        local all_files="$server_files $client_files"
        for f in $all_files; do
            [ -f "$GFK_DIR/$f" ] && cp "$GFK_DIR/$f" "$BACKUP_DIR/${f}.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
        done

        for f in $all_files; do
            cp "$tmp_dir/$f" "$GFK_DIR/$f"
        done
        chmod 600 "$GFK_DIR"/*.py
        # Patch mainserver.py to use venv python for subprocesses
        [ -f "$GFK_DIR/mainserver.py" ] && sed -i "s|'python3'|'$INSTALL_DIR/venv/bin/python'|g" "$GFK_DIR/mainserver.py"
        log_success "GFW-knocker scripts updated"

        # Also upgrade Python deps in venv
        "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade scapy aioquic 2>/dev/null || true

        [ "$was_running" = true ] && start_paqet
    else
        log_success "GFW-knocker scripts are already up to date"
        "$INSTALL_DIR/venv/bin/pip" install --quiet --upgrade scapy aioquic 2>/dev/null || true
    fi
    rm -rf "$tmp_dir"

    # Regenerate client wrapper (removes legacy microsocks startup)
    if [ "$ROLE" = "client" ]; then
        create_gfk_client_wrapper
        pkill -f "${INSTALL_DIR}/bin/microsocks" 2>/dev/null || true
    fi

    # Also check for management script updates
    update_management_script
    echo ""
}

update_paqet() {
    if [ "$BACKEND" = "gfw-knocker" ]; then
        update_gfk
        return
    fi

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  UPDATE PAQET${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    log_info "Querying GitHub for latest release..."

    # Get latest version from GitHub with retry
    local response
    response=$(_curl_with_retry "$PAQET_API_URL" 3)
    if [ -z "$response" ]; then
        log_error "Failed to query GitHub API after retries. Check your internet connection."
        return 1
    fi

    local latest_tag
    latest_tag=$(echo "$response" | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"')
    if [ -z "$latest_tag" ] || ! _validate_version_tag "$latest_tag"; then
        log_error "Could not determine valid version from GitHub"
        return 1
    fi

    # Extract release date
    local release_date
    release_date=$(echo "$response" | grep -o '"published_at"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"' | cut -dT -f1)

    # Extract release notes (body field)
    local release_notes=""
    if command -v python3 &>/dev/null; then
        release_notes=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    body=d.get('body','')
    if body:
        # Truncate to first 500 chars, strip markdown
        body=body[:500].replace('**','').replace('##','').replace('# ','')
        print(body)
except: pass
" <<< "$response" 2>/dev/null)
    fi

    local current="${PAQET_VERSION:-unknown}"
    local bin_ver
    bin_ver=$("$INSTALL_DIR/bin/paqet" version 2>/dev/null || echo "unknown")

    echo ""
    echo -e "  ${DIM}── Version Info ──${NC}"
    echo -e "  Installed version:  ${BOLD}${current}${NC}"
    echo -e "  Binary reports:     ${BOLD}${bin_ver}${NC}"
    echo -e "  Latest release:     ${BOLD}${latest_tag}${NC}"
    [ -n "$release_date" ] && echo -e "  Release date:       ${release_date}"

    if [ "$current" = "$latest_tag" ]; then
        echo ""
        log_success "You are already on the latest version!"
        echo ""
        echo -e "  ${DIM}Options:${NC}"
        echo "  1. Force reinstall current version"
        echo "  2. Rollback to previous version"
        echo "  3. Update management script only"
        echo "  b. Back"
        echo ""
        read -p "  Choice: " up_choice < /dev/tty || true
        case "$up_choice" in
            1)
                read -p "  Force reinstall ${current}? [y/N]: " _fc < /dev/tty || true
                [[ "$_fc" =~ ^[Yy]$ ]] || { log_info "Cancelled"; return 0; }
                ;;
            2) rollback_paqet; return ;;
            3) update_management_script; return ;;
            [bB]) return 0 ;;
            *) return 0 ;;
        esac
    fi

    # Show release notes if available
    if [ -n "$release_notes" ]; then
        echo ""
        echo -e "  ${DIM}── Release Notes ──${NC}"
        echo "$release_notes" | while IFS= read -r line; do
            echo -e "  ${DIM}${line}${NC}"
        done
        echo ""
    fi

    echo ""
    echo -e "${YELLOW}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ${BOLD}⚠ WARNING: Updating may cause compatibility issues!${NC}${YELLOW}            ║${NC}"
    echo -e "${YELLOW}╠════════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}  paqctl was tested with: ${BOLD}${PAQET_VERSION_PINNED}${NC}"
    echo -e "${YELLOW}║${NC}  Newer versions may have breaking changes or bugs."
    echo -e "${YELLOW}║${NC}  You can rollback with: ${BOLD}sudo paqctl rollback${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -p "  Update to ${latest_tag}? [y/N]: " confirm < /dev/tty || true
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Update cancelled"
        return 0
    fi

    # Download new binary
    _download_and_install_binary "$latest_tag" || return 1

    # Check for management script update
    update_management_script
}

_download_and_install_binary() {
    local target_tag="$1"
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "Unsupported architecture: $arch"; return 1 ;;
    esac

    local filename="paqet-linux-${arch}-${target_tag}.tar.gz"
    local url="https://github.com/${PAQET_REPO}/releases/download/${target_tag}/${filename}"
    local tmp_file
    tmp_file=$(mktemp "/tmp/paqet-update-XXXXXXXX.tar.gz")

    log_info "Downloading ${filename}..."
    if ! curl -sL --max-time 120 --fail -o "$tmp_file" "$url"; then
        log_error "Download failed: $url"
        rm -f "$tmp_file"
        return 1
    fi

    # Validate
    local fsize
    fsize=$(stat -c%s "$tmp_file" 2>/dev/null || stat -f%z "$tmp_file" 2>/dev/null || wc -c < "$tmp_file" 2>/dev/null || echo 0)
    if [ "$fsize" -lt 1000 ]; then
        log_error "Downloaded file too small ($fsize bytes). Aborting."
        rm -f "$tmp_file"
        return 1
    fi

    # Extract
    local tmp_extract
    tmp_extract=$(mktemp -d "/tmp/paqet-update-extract-XXXXXXXX")
    if ! tar -xzf "$tmp_file" -C "$tmp_extract" 2>/dev/null; then
        log_error "Failed to extract archive"
        rm -f "$tmp_file"
        rm -rf "$tmp_extract"
        return 1
    fi

    local binary_name="paqet_linux_${arch}"
    local found_binary
    found_binary=$(find "$tmp_extract" -name "$binary_name" -type f 2>/dev/null | head -1)
    [ -z "$found_binary" ] && found_binary=$(find "$tmp_extract" -name "paqet*" -type f -executable 2>/dev/null | head -1)
    [ -z "$found_binary" ] && found_binary=$(find "$tmp_extract" -name "paqet*" -type f 2>/dev/null | head -1)

    if [ -z "$found_binary" ]; then
        log_error "Could not find paqet binary in archive"
        rm -f "$tmp_file"
        rm -rf "$tmp_extract"
        return 1
    fi

    # Stop service, replace, start
    local was_running=false
    if is_running; then
        was_running=true
        stop_paqet
    fi

    # Backup old binary with version tag for rollback
    if ! mkdir -p "$BACKUP_DIR"; then
        log_warn "Failed to create backup directory"
    fi
    local old_ver="${PAQET_VERSION:-unknown}"
    cp "$INSTALL_DIR/bin/paqet" "$BACKUP_DIR/paqet.${old_ver}.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true

    if ! cp "$found_binary" "$INSTALL_DIR/bin/paqet"; then
        log_error "Failed to copy new binary"
        rm -f "$tmp_file"
        rm -rf "$tmp_extract"
        # Restore from backup
        local latest_backup
        latest_backup=$(ls -t "$BACKUP_DIR"/paqet.* 2>/dev/null | head -1)
        [ -n "$latest_backup" ] && cp "$latest_backup" "$INSTALL_DIR/bin/paqet" && chmod +x "$INSTALL_DIR/bin/paqet"
        [ "$was_running" = true ] && start_paqet
        return 1
    fi
    chmod +x "$INSTALL_DIR/bin/paqet"

    rm -f "$tmp_file"
    rm -rf "$tmp_extract"

    # Verify the new binary works
    if ! "$INSTALL_DIR/bin/paqet" version &>/dev/null; then
        log_warn "New binary failed verification. Restoring backup..."
        local latest_backup
        latest_backup=$(ls -t "$BACKUP_DIR"/paqet.* 2>/dev/null | head -1)
        if [ -n "$latest_backup" ]; then
            cp "$latest_backup" "$INSTALL_DIR/bin/paqet"
            chmod +x "$INSTALL_DIR/bin/paqet"
            log_error "Update failed — previous version restored"
            return 1
        fi
        log_error "Update failed and no backup available"
        return 1
    fi

    # Update version in settings
    PAQET_VERSION="$target_tag"
    _safe_update_setting "PAQET_VERSION" "$target_tag" "$INSTALL_DIR/settings.conf"

    log_success "paqet updated to ${target_tag}"

    if [ "$was_running" = true ]; then
        start_paqet
    fi
}

rollback_paqet() {
    echo ""
    if [ ! -d "$BACKUP_DIR" ]; then
        log_warn "No backups found"
        return 1
    fi

    local backups=()
    local i=1
    echo -e "  ${BOLD}Available binary backups:${NC}"
    echo ""
    for f in "$BACKUP_DIR"/paqet.*; do
        [ -f "$f" ] || continue
        backups+=("$f")
        local bname=$(basename "$f")
        local bsize=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || wc -c < "$f" 2>/dev/null || echo "?")
        echo "  $i. $bname  (${bsize} bytes)"
        i=$((i + 1))
    done

    if [ ${#backups[@]} -eq 0 ]; then
        log_warn "No binary backups found in $BACKUP_DIR"
        return 1
    fi

    echo ""
    echo "  0. Cancel"
    echo ""
    read -p "  Select backup to restore [0-${#backups[@]}]: " choice < /dev/tty || true
    if [ "$choice" = "0" ]; then
        log_info "Cancelled"
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        log_error "Invalid choice"
        return 1
    fi

    local selected="${backups[$((choice-1))]}"
    log_info "Rolling back to: $(basename "$selected")"

    local was_running=false
    is_running && was_running=true
    [ "$was_running" = true ] && stop_paqet

    if ! cp "$selected" "$INSTALL_DIR/bin/paqet"; then
        log_error "Failed to restore backup"
        [ "$was_running" = true ] && start_paqet
        return 1
    fi
    chmod +x "$INSTALL_DIR/bin/paqet"

    # Verify restored binary
    if ! "$INSTALL_DIR/bin/paqet" version &>/dev/null; then
        log_warn "Restored binary failed verification (may need libpcap)"
    fi

    # Try to extract version from the filename (format: paqet.vX.Y.Z.TIMESTAMP)
    local restored_ver=""
    local _bname
    _bname=$(basename "$selected")
    # Extract version: remove 'paqet.' prefix and '.YYYYMMDDHHMMSS' timestamp suffix
    restored_ver=$(echo "$_bname" | sed 's/^paqet\.//' | sed 's/\.[0-9]\{14\}$//')
    # Validate extracted version looks reasonable
    if [ -n "$restored_ver" ] && [ "$restored_ver" != "backup" ] && [ "$restored_ver" != "$_bname" ]; then
        if _validate_version_tag "$restored_ver"; then
            PAQET_VERSION="$restored_ver"
            _safe_update_setting "PAQET_VERSION" "$restored_ver" "$INSTALL_DIR/settings.conf"
            log_info "Restored version: $restored_ver"
        else
            log_warn "Could not determine version from backup filename, keeping current version setting"
        fi
    else
        log_warn "Could not extract version from backup filename"
    fi

    log_success "Rolled back successfully"

    [ "$was_running" = true ] && start_paqet
}

update_management_script() {
    local update_url="https://raw.githubusercontent.com/SamNet-dev/paqctl/main/paqctl.sh"
    local tmp_script
    tmp_script=$(mktemp "/tmp/paqctl-update-XXXXXXXX.sh")

    log_info "Checking for management script updates..."
    if ! curl -sL --max-time 30 --max-filesize 2097152 -o "$tmp_script" "$update_url" 2>/dev/null; then
        log_warn "Could not check for script updates"
        rm -f "$tmp_script"
        return 0
    fi

    # Validate: must contain our markers, be a bash script, and pass syntax check
    if ! head -n 1 "$tmp_script" 2>/dev/null | grep -q "^#!.*bash"; then
        log_warn "Downloaded file is not a bash script, skipping"
        rm -f "$tmp_script"
        return 0
    fi
    if grep -q "PAQET_REPO=" "$tmp_script" && \
       grep -q "create_management_script" "$tmp_script" && \
       grep -q "PAQCTL_VERSION=" "$tmp_script" && \
       bash -n "$tmp_script" 2>/dev/null; then
        local _update_output
        if _update_output=$(bash "$tmp_script" --update-components 2>&1); then
            log_success "Management script updated"
        else
            log_warn "Management script update execution failed: ${_update_output:-unknown error}"
        fi
    else
        log_warn "Downloaded script failed validation, skipping"
    fi
    rm -f "$tmp_script"
}

#═══════════════════════════════════════════════════════════════════════
# Secret Key Generation
#═══════════════════════════════════════════════════════════════════════

generate_secret() {
    echo ""
    local key
    key=$("$INSTALL_DIR/bin/paqet" secret 2>/dev/null || true)
    if [ -z "$key" ]; then
        key=$(openssl rand -base64 32 2>/dev/null | tr -d '=+/' | head -c 32)
    fi
    echo -e "  ${GREEN}${BOLD}New encryption key: ${key}${NC}"
    echo ""
    echo -e "  ${DIM}Share this key securely with client users.${NC}"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Firewall Display
#═══════════════════════════════════════════════════════════════════════

show_firewall() {
    if [ "$ROLE" != "server" ] && [ "$BACKEND" != "gfw-knocker" ]; then
        echo ""
        log_info "Firewall rules only apply in server mode or GFK client mode"
        echo ""
        return
    fi

    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            echo ""
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}  FIREWALL RULES${NC}"
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo ""

            local _fw_backend="iptables"
            _is_firewalld_active && _fw_backend="firewalld"
            echo -e "  ${DIM}Backend: ${_fw_backend}${NC}"
            echo ""

            if [ "$BACKEND" = "gfw-knocker" ]; then
                local vio_port
                if [ "$ROLE" = "server" ]; then
                    vio_port="${GFK_VIO_PORT:-45000}"
                else
                    vio_port="${GFK_VIO_CLIENT_PORT:-40000}"
                fi
                echo -e "  ${BOLD}Required rules for VIO port ${vio_port}:${NC}"
                echo ""
                if [ "$_fw_backend" = "firewalld" ]; then
                    firewall-cmd --direct --query-rule ipv4 raw PREROUTING 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} PREROUTING NOTRACK (dport $vio_port)" \
                        || echo -e "  ${RED}✗${NC} PREROUTING NOTRACK (dport $vio_port)  ${DIM}MISSING${NC}"
                    firewall-cmd --direct --query-rule ipv4 raw OUTPUT 0 -p tcp --sport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} OUTPUT NOTRACK (sport $vio_port)" \
                        || echo -e "  ${RED}✗${NC} OUTPUT NOTRACK (sport $vio_port)  ${DIM}MISSING${NC}"
                    firewall-cmd --direct --query-rule ipv4 filter INPUT 0 -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} INPUT DROP (dport $vio_port)" \
                        || echo -e "  ${RED}✗${NC} INPUT DROP (dport $vio_port)  ${DIM}MISSING${NC}"
                    firewall-cmd --direct --query-rule ipv4 filter OUTPUT 0 -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} RST DROP (sport $vio_port)" \
                        || echo -e "  ${RED}✗${NC} RST DROP (sport $vio_port)  ${DIM}MISSING${NC}"
                else
                    iptables -t raw -C PREROUTING -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} PREROUTING NOTRACK (dport $vio_port)" \
                        || echo -e "  ${RED}✗${NC} PREROUTING NOTRACK (dport $vio_port)  ${DIM}MISSING${NC}"
                    iptables -t raw -C OUTPUT -p tcp --sport "$vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} OUTPUT NOTRACK (sport $vio_port)" \
                        || echo -e "  ${RED}✗${NC} OUTPUT NOTRACK (sport $vio_port)  ${DIM}MISSING${NC}"
                    iptables -C INPUT -p tcp --dport "$vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} INPUT DROP (dport $vio_port)" \
                        || echo -e "  ${RED}✗${NC} INPUT DROP (dport $vio_port)  ${DIM}MISSING${NC}"
                    iptables -C OUTPUT -p tcp --sport "$vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} RST DROP (sport $vio_port)" \
                        || echo -e "  ${RED}✗${NC} RST DROP (sport $vio_port)  ${DIM}MISSING${NC}"
                fi
            else
                local port="${LISTEN_PORT:-8443}"
                echo -e "  ${BOLD}Required rules for port ${port}:${NC}"
                echo ""
                if [ "$_fw_backend" = "firewalld" ]; then
                    firewall-cmd --direct --query-rule ipv4 raw PREROUTING 0 -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} PREROUTING NOTRACK (dport $port)" \
                        || echo -e "  ${RED}✗${NC} PREROUTING NOTRACK (dport $port)  ${DIM}MISSING${NC}"
                    firewall-cmd --direct --query-rule ipv4 raw OUTPUT 0 -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} OUTPUT NOTRACK (sport $port)" \
                        || echo -e "  ${RED}✗${NC} OUTPUT NOTRACK (sport $port)  ${DIM}MISSING${NC}"
                    firewall-cmd --direct --query-rule ipv4 mangle OUTPUT 0 -p tcp --sport "$port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} RST DROP (sport $port)" \
                        || echo -e "  ${RED}✗${NC} RST DROP (sport $port)  ${DIM}MISSING${NC}"
                else
                    iptables -t raw -C PREROUTING -p tcp --dport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} PREROUTING NOTRACK (dport $port)" \
                        || echo -e "  ${RED}✗${NC} PREROUTING NOTRACK (dport $port)  ${DIM}MISSING${NC}"
                    iptables -t raw -C OUTPUT -p tcp --sport "$port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} OUTPUT NOTRACK (sport $port)" \
                        || echo -e "  ${RED}✗${NC} OUTPUT NOTRACK (sport $port)  ${DIM}MISSING${NC}"
                    iptables -t mangle -C OUTPUT -p tcp --sport "$port" -m comment --comment "paqctl" --tcp-flags RST RST -j DROP 2>/dev/null \
                        && echo -e "  ${GREEN}✓${NC} RST DROP (sport $port)" \
                        || echo -e "  ${RED}✗${NC} RST DROP (sport $port)  ${DIM}MISSING${NC}"
                fi
            fi

            echo ""
            echo -e "  ${BOLD}Actions:${NC}"
            echo "  1. Apply missing rules"
            echo "  2. Remove all rules"
            echo "  b. Back"
            echo ""
            redraw=false
        fi

        read -p "  Choice: " fw_choice < /dev/tty || break
        case "$fw_choice" in
            1)
                _apply_firewall
                _persist_firewall
                log_success "Firewall rules applied and persisted"
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            2)
                _remove_firewall
                _persist_firewall
                log_success "Firewall rules removed"
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            b|B) return ;;
            "") ;;
            *) echo -e "  ${RED}Invalid choice${NC}" ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════
# Configuration
#═══════════════════════════════════════════════════════════════════════

_change_config_gfk() {
    local was_running="$1"
    echo ""
    echo -e "${BOLD}Select role:${NC}"
    echo "  1. Server"
    echo "  2. Client"
    echo ""
    local role_choice
    read -p "  Enter choice [1/2]: " role_choice < /dev/tty || true
    case "$role_choice" in
        1) ROLE="server" ;;
        2) ROLE="client" ;;
        *) log_warn "Invalid. Keeping current role: $ROLE" ;;
    esac

    if [ "$ROLE" = "server" ]; then
        echo -e "${BOLD}Server public IP${NC} [${GFK_SERVER_IP}]:"
        read -p "  IP: " input < /dev/tty || true
        if [ -n "$input" ] && ! _validate_ip "$input"; then
            log_error "Invalid IP address"; return 1
        fi
        [ -n "$input" ] && GFK_SERVER_IP="$input"

        echo -e "${BOLD}VIO TCP port${NC} [${GFK_VIO_PORT:-45000}]:"
        read -p "  Port: " input < /dev/tty || true
        if [ -n "$input" ] && ! _validate_port "$input"; then
            log_error "Invalid port number"; return 1
        fi
        [ -n "$input" ] && GFK_VIO_PORT="$input"

        echo -e "${BOLD}QUIC port${NC} [${GFK_QUIC_PORT:-25000}]:"
        read -p "  Port: " input < /dev/tty || true
        if [ -n "$input" ] && ! _validate_port "$input"; then
            log_error "Invalid port number"; return 1
        fi
        [ -n "$input" ] && GFK_QUIC_PORT="$input"

        echo -e "${BOLD}Auth code${NC} [keep current]:"
        read -p "  Code: " input < /dev/tty || true
        [ -n "$input" ] && GFK_AUTH_CODE="$input"

        echo -e "${BOLD}Port mappings${NC} [${GFK_PORT_MAPPINGS:-14000:443}]:"
        read -p "  Mappings: " input < /dev/tty || true
        [ -n "$input" ] && GFK_PORT_MAPPINGS="$input"

        echo -e "${BOLD}Outgoing TCP flags${NC} [${GFK_TCP_FLAGS:-AP}]:"
        echo -e "  ${DIM}Controls TCP flags on outgoing violated packets (default: AP)${NC}"
        echo -e "  ${DIM}Valid flags: S(SYN) A(ACK) P(PSH) R(RST) F(FIN) U(URG)${NC}"
        read -p "  Flags: " input < /dev/tty || true
        if [ -n "$input" ] && ! [[ "$input" =~ ^[FSRPAUEC]+$ ]]; then
            log_error "Invalid flags. Use uppercase letters only: F, S, R, P, A, U, E, C"; return 1
        fi
        [ -n "$input" ] && GFK_TCP_FLAGS="$input"
    else
        echo -e "${BOLD}Server IP${NC} [${GFK_SERVER_IP}]:"
        read -p "  IP: " input < /dev/tty || true
        if [ -n "$input" ] && ! _validate_ip "$input"; then
            log_error "Invalid IP address"; return 1
        fi
        [ -n "$input" ] && GFK_SERVER_IP="$input"

        echo -e "${BOLD}Server's VIO TCP port${NC} [${GFK_VIO_PORT:-45000}] (must match server):"
        read -p "  Port: " input < /dev/tty || true
        if [ -n "$input" ] && ! _validate_port "$input"; then
            log_error "Invalid port number"; return 1
        fi
        [ -n "$input" ] && GFK_VIO_PORT="$input"

        echo -e "${BOLD}Local VIO client port${NC} [${GFK_VIO_CLIENT_PORT:-40000}]:"
        read -p "  Port: " input < /dev/tty || true
        if [ -n "$input" ] && ! _validate_port "$input"; then
            log_error "Invalid port number"; return 1
        fi
        [ -n "$input" ] && GFK_VIO_CLIENT_PORT="$input"

        echo -e "${BOLD}Server's QUIC port${NC} [${GFK_QUIC_PORT:-25000}] (must match server):"
        read -p "  Port: " input < /dev/tty || true
        if [ -n "$input" ] && ! _validate_port "$input"; then
            log_error "Invalid port number"; return 1
        fi
        [ -n "$input" ] && GFK_QUIC_PORT="$input"

        echo -e "${BOLD}Local QUIC client port${NC} [${GFK_QUIC_CLIENT_PORT:-20000}]:"
        read -p "  Port: " input < /dev/tty || true
        if [ -n "$input" ] && ! _validate_port "$input"; then
            log_error "Invalid port number"; return 1
        fi
        [ -n "$input" ] && GFK_QUIC_CLIENT_PORT="$input"

        echo -e "${BOLD}Auth code${NC}:"
        read -p "  Code: " input < /dev/tty || true
        [ -n "$input" ] && GFK_AUTH_CODE="$input"

        echo -e "${BOLD}Port mappings${NC} [${GFK_PORT_MAPPINGS:-14000:443}]:"
        read -p "  Mappings: " input < /dev/tty || true
        [ -n "$input" ] && GFK_PORT_MAPPINGS="$input"

        echo -e "${BOLD}Outgoing TCP flags${NC} [${GFK_TCP_FLAGS:-AP}]:"
        echo -e "  ${DIM}Controls TCP flags on outgoing violated packets (default: AP)${NC}"
        echo -e "  ${DIM}Valid flags: S(SYN) A(ACK) P(PSH) R(RST) F(FIN) U(URG)${NC}"
        read -p "  Flags: " input < /dev/tty || true
        if [ -n "$input" ] && ! [[ "$input" =~ ^[FSRPAUEC]+$ ]]; then
            log_error "Invalid flags. Use uppercase letters only: F, S, R, P, A, U, E, C"; return 1
        fi
        [ -n "$input" ] && GFK_TCP_FLAGS="$input"
    fi

    # Regenerate parameters.py
    generate_gfk_config || { [ "$was_running" = true ] && start_paqet; return 1; }

    # Regenerate wrapper if client
    if [ "$ROLE" = "client" ]; then
        create_gfk_client_wrapper
    fi

    # Save settings
    local IFACE="" GW_MAC=""
    save_settings

    # Re-apply firewall
    _apply_firewall

    # Restart
    [ "$was_running" = true ] && start_paqet
    log_success "GFW-knocker configuration updated"
}

change_config() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  CHANGE CONFIGURATION${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    local _warn_text="config"
    [ "$BACKEND" = "gfw-knocker" ] && _warn_text="parameters.py"
    echo -e "  ${YELLOW}Warning: This will regenerate ${_warn_text} and restart ${BACKEND}.${NC}"
    echo ""
    read -p "  Continue? [y/N]: " confirm < /dev/tty || true
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    fi

    local was_running=false
    is_running && was_running=true
    [ "$was_running" = true ] && stop_paqet

    if [ "$BACKEND" = "gfw-knocker" ]; then
        _remove_firewall
        _change_config_gfk "$was_running"
        return
    fi

    # Remove old firewall rules (save old port before user changes it)
    local _saved_port="$LISTEN_PORT"
    if [ "$ROLE" = "server" ] && [ -n "$_saved_port" ]; then
        _remove_firewall
    fi

    # Re-run wizard (inline version)
    echo ""
    echo -e "${BOLD}Select role:${NC}"
    echo "  1. Server"
    echo "  2. Client"
    echo ""
    local role_choice
    read -p "  Enter choice [1/2]: " role_choice < /dev/tty || true
    case "$role_choice" in
        1) ROLE="server" ;;
        2) ROLE="client" ;;
        *)
            log_warn "Invalid choice. Defaulting to server."
            ROLE="server"
            ;;
    esac

    # Detect network
    local _iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
    # Note: grep returns exit 1 if no matches, so we add || true for pipefail
    local _ip=$(ip -4 addr show "$_iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | { grep -o '[0-9.]*' || true; } | head -1)
    local _gw=$(ip route show default 2>/dev/null | awk '{print $3; exit}')
    local _gw_mac=""
    [ -n "$_gw" ] && _gw_mac=$(ip neigh show "$_gw" 2>/dev/null | awk '/lladdr/{print $5; exit}')

    echo ""
    echo -e "${BOLD}Interface${NC} [${_iface:-$INTERFACE}]:"
    read -p "  Interface: " input < /dev/tty || true
    INTERFACE="${input:-${_iface:-$INTERFACE}}"

    echo -e "${BOLD}Local IP${NC} [${_ip:-$LOCAL_IP}]:"
    read -p "  IP: " input < /dev/tty || true
    LOCAL_IP="${input:-${_ip:-$LOCAL_IP}}"

    echo -e "${BOLD}Gateway MAC${NC} [${_gw_mac:-$GATEWAY_MAC}]:"
    read -p "  MAC: " input < /dev/tty || true
    GATEWAY_MAC="${input:-${_gw_mac:-$GATEWAY_MAC}}"
    if [ -n "$GATEWAY_MAC" ] && ! _validate_mac "$GATEWAY_MAC"; then
        log_warn "Invalid MAC address format (expected: aa:bb:cc:dd:ee:ff)"
        read -p "  Enter valid MAC address: " input < /dev/tty || true
        if [ -n "$input" ] && ! _validate_mac "$input"; then
            log_warn "Invalid MAC format, keeping current value"
            input=""
        fi
        [ -n "$input" ] && GATEWAY_MAC="$input"
    fi

    if [ "$ROLE" = "server" ]; then
        echo -e "${BOLD}Port${NC} [${LISTEN_PORT:-8443}]:"
        read -p "  Port: " input < /dev/tty || true
        LISTEN_PORT="${input:-${LISTEN_PORT:-8443}}"
        if ! _validate_port "$LISTEN_PORT"; then
            log_warn "Invalid port. Using default 8443."
            LISTEN_PORT=8443
        fi

        echo -e "${BOLD}Encryption key${NC} [keep current]:"
        read -p "  Key (enter to keep): " input < /dev/tty || true
        [ -n "$input" ] && ENCRYPTION_KEY="$input"
        REMOTE_SERVER=""
        SOCKS_PORT=""
    else
        echo -e "${BOLD}Remote server${NC} (IP:PORT):"
        read -p "  Server: " input < /dev/tty || true
        REMOTE_SERVER="${input:-$REMOTE_SERVER}"

        echo -e "${BOLD}Encryption key${NC}:"
        read -p "  Key: " input < /dev/tty || true
        [ -n "$input" ] && ENCRYPTION_KEY="$input"

        echo -e "${BOLD}SOCKS5 port${NC} [${SOCKS_PORT:-1080}]:"
        read -p "  Port: " input < /dev/tty || true
        SOCKS_PORT="${input:-${SOCKS_PORT:-1080}}"
        LISTEN_PORT=""
    fi

    # TCP flags (for both server and client)
    echo -e "${BOLD}TCP local flag${NC} [${PAQET_TCP_LOCAL_FLAG:-PA}]:"
    echo -e "  ${DIM}Controls TCP flags on outgoing packets (default: PA = PSH+ACK)${NC}"
    echo -e "  ${DIM}Valid flags: S(SYN) A(ACK) P(PSH) R(RST) F(FIN) U(URG) E(ECE) C(CWR)${NC}"
    echo -e "  ${DIM}Multiple values: PA,A (tries PA first, then A)${NC}"
    read -p "  Flag: " input < /dev/tty || true
    if [ -n "$input" ] && ! [[ "$input" =~ ^[FSRPAUEC]+(,[FSRPAUEC]+)*$ ]]; then
        log_warn "Invalid flags. Use: FSRPAUEC (e.g., PA or PA,A). Keeping current value."
        input=""
    fi
    [ -n "$input" ] && PAQET_TCP_LOCAL_FLAG="$input"

    echo -e "${BOLD}TCP remote flag${NC} [${PAQET_TCP_REMOTE_FLAG:-PA}]:"
    echo -e "  ${DIM}Controls expected TCP flags on incoming packets (default: PA)${NC}"
    echo -e "  ${DIM}Should match the server/client counterpart's local flag${NC}"
    read -p "  Flag: " input < /dev/tty || true
    if [ -n "$input" ] && ! [[ "$input" =~ ^[FSRPAUEC]+(,[FSRPAUEC]+)*$ ]]; then
        log_warn "Invalid flags. Use: FSRPAUEC (e.g., PA or PA,A). Keeping current value."
        input=""
    fi
    [ -n "$input" ] && PAQET_TCP_REMOTE_FLAG="$input"

    # Save
    local IFACE="$INTERFACE"
    local GW_MAC="$GATEWAY_MAC"
    # Regenerate YAML
    local tmp_conf
    tmp_conf=$(mktemp "$INSTALL_DIR/config.yaml.XXXXXXXX")
    # Validate required fields
    if [ -z "$INTERFACE" ] || [ -z "$LOCAL_IP" ] || [ -z "$GATEWAY_MAC" ] || [ -z "$ENCRYPTION_KEY" ]; then
        log_error "Missing required configuration fields"
        rm -f "$tmp_conf"
        [ "$was_running" = true ] && start_paqet
        return 1
    fi

    # Escape YAML special characters to prevent injection
    _escape_yaml() {
        local s="$1"
        if [[ "$s" =~ [:\#\[\]{}\"\'\|\>\<\&\*\!\%\@\`] ]] || [[ "$s" =~ ^[[:space:]] ]] || [[ "$s" =~ [[:space:]]$ ]]; then
            s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"
        else
            printf '%s' "$s"
        fi
    }
    # Set permissions before writing
    chmod 600 "$tmp_conf" 2>/dev/null
    (
    umask 077
    local _y_iface _y_ip _y_mac _y_key _y_server _tcp_local_flags _tcp_remote_flags
    _y_iface=$(_escape_yaml "$INTERFACE")
    _y_ip=$(_escape_yaml "$LOCAL_IP")
    _y_mac=$(_escape_yaml "$GATEWAY_MAC")
    _y_key=$(_escape_yaml "$ENCRYPTION_KEY")
    _tcp_local_flags=$(echo "${PAQET_TCP_LOCAL_FLAG:-PA}" | sed 's/,/", "/g; s/.*/["&"]/')
    _tcp_remote_flags=$(echo "${PAQET_TCP_REMOTE_FLAG:-PA}" | sed 's/,/", "/g; s/.*/["&"]/')
    if [ "$ROLE" = "server" ]; then
        cat > "$tmp_conf" << EOF
role: "server"

log:
  level: "info"

listen:
  addr: ":${LISTEN_PORT}"

network:
  interface: "${_y_iface}"
  ipv4:
    addr: "${_y_ip}:${LISTEN_PORT}"
    router_mac: "${_y_mac}"
  tcp:
    local_flag: ${_tcp_local_flags}
    remote_flag: ${_tcp_remote_flags}

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "${_y_key}"
EOF
    else
        _y_server=$(_escape_yaml "$REMOTE_SERVER")
        cat > "$tmp_conf" << EOF
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:${SOCKS_PORT}"

network:
  interface: "${_y_iface}"
  ipv4:
    addr: "${_y_ip}:0"
    router_mac: "${_y_mac}"
  tcp:
    local_flag: ${_tcp_local_flags}
    remote_flag: ${_tcp_remote_flags}

server:
  addr: "${_y_server}"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "${_y_key}"
EOF
    fi
    )
    if ! mv "$tmp_conf" "$INSTALL_DIR/config.yaml"; then
        log_error "Failed to save configuration"
        rm -f "$tmp_conf"
        [ "$was_running" = true ] && start_paqet
        return 1
    fi
    chmod 600 "$INSTALL_DIR/config.yaml" 2>/dev/null

    # Save settings
    local _tmp
    _tmp=$(mktemp "$INSTALL_DIR/settings.conf.XXXXXXXX")
    # Read current telegram settings
    local _tg_token="${TELEGRAM_BOT_TOKEN:-}"
    local _tg_chat="${TELEGRAM_CHAT_ID:-}"
    local _tg_interval="${TELEGRAM_INTERVAL:-6}"
    local _tg_enabled="${TELEGRAM_ENABLED:-false}"
    local _tg_alerts="${TELEGRAM_ALERTS_ENABLED:-true}"
    local _tg_daily="${TELEGRAM_DAILY_SUMMARY:-true}"
    local _tg_weekly="${TELEGRAM_WEEKLY_SUMMARY:-true}"
    local _tg_label="${TELEGRAM_SERVER_LABEL:-}"
    local _tg_start_hour="${TELEGRAM_START_HOUR:-0}"
    (
    umask 077
    cat > "$_tmp" << EOF
BACKEND="${BACKEND:-paqet}"
ROLE="${ROLE}"
PAQET_VERSION="${PAQET_VERSION}"
PAQCTL_VERSION="${VERSION}"
LISTEN_PORT="${LISTEN_PORT:-}"
SOCKS_PORT="${SOCKS_PORT:-}"
INTERFACE="${INTERFACE}"
LOCAL_IP="${LOCAL_IP}"
GATEWAY_MAC="${GATEWAY_MAC}"
ENCRYPTION_KEY="${ENCRYPTION_KEY}"
REMOTE_SERVER="${REMOTE_SERVER:-}"
GFK_VIO_PORT="${GFK_VIO_PORT:-}"
GFK_QUIC_PORT="${GFK_QUIC_PORT:-}"
GFK_AUTH_CODE="${GFK_AUTH_CODE:-}"
GFK_PORT_MAPPINGS="${GFK_PORT_MAPPINGS:-}"
GFK_SOCKS_PORT="${GFK_SOCKS_PORT:-}"
GFK_SOCKS_VIO_PORT="${GFK_SOCKS_VIO_PORT:-}"
XRAY_PANEL_DETECTED="${XRAY_PANEL_DETECTED:-false}"
MICROSOCKS_PORT="${MICROSOCKS_PORT:-}"
GFK_SERVER_IP="${GFK_SERVER_IP:-}"
GFK_TCP_FLAGS="${GFK_TCP_FLAGS:-AP}"
PAQET_TCP_LOCAL_FLAG="${PAQET_TCP_LOCAL_FLAG:-PA}"
PAQET_TCP_REMOTE_FLAG="${PAQET_TCP_REMOTE_FLAG:-PA}"
TELEGRAM_BOT_TOKEN="${_tg_token}"
TELEGRAM_CHAT_ID="${_tg_chat}"
TELEGRAM_INTERVAL=${_tg_interval}
TELEGRAM_ENABLED=${_tg_enabled}
TELEGRAM_ALERTS_ENABLED=${_tg_alerts}
TELEGRAM_DAILY_SUMMARY=${_tg_daily}
TELEGRAM_WEEKLY_SUMMARY=${_tg_weekly}
TELEGRAM_SERVER_LABEL="${_tg_label}"
TELEGRAM_START_HOUR=${_tg_start_hour}
EOF
    )
    if ! mv "$_tmp" "$INSTALL_DIR/settings.conf"; then
        log_error "Failed to save settings"
        rm -f "$_tmp"
    fi
    chmod 600 "$INSTALL_DIR/settings.conf" 2>/dev/null

    log_success "Configuration updated"

    if [ "$was_running" = true ]; then
        start_paqet
    fi
}

#═══════════════════════════════════════════════════════════════════════
# Backup & Restore
#═══════════════════════════════════════════════════════════════════════

backup_config() {
    (umask 077; mkdir -p "$BACKUP_DIR")
    chmod 700 "$BACKUP_DIR" 2>/dev/null
    local ts=$(date +%Y%m%d%H%M%S)
    local backup_file="$BACKUP_DIR/paqctl-backup-${ts}.tar.gz"

    if ! (umask 077; tar -czf "$backup_file" \
        -C "$INSTALL_DIR" \
        config.yaml settings.conf 2>/dev/null); then
        log_error "Failed to create backup archive"
        rm -f "$backup_file"
        return 1
    fi
    echo ""
    log_success "Backup saved to: $backup_file"
    echo ""
}

restore_config() {
    echo ""
    if [ ! -d "$BACKUP_DIR" ] || [ -z "$(ls -A "$BACKUP_DIR"/*.tar.gz 2>/dev/null)" ]; then
        log_warn "No backups found in $BACKUP_DIR"
        return 1
    fi

    echo -e "${BOLD}Available backups:${NC}"
    echo ""
    local i=1
    local backups=()
    for f in "$BACKUP_DIR"/*.tar.gz; do
        backups+=("$f")
        echo "  $i. $(basename "$f")"
        i=$((i + 1))
    done
    echo ""
    echo "  0. Cancel"
    echo ""
    read -p "  Select backup [0-${#backups[@]}]: " choice < /dev/tty || true
    if [ "$choice" = "0" ]; then
        log_info "Cancelled"
        return 0
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backups[@]} ]; then
        log_error "Invalid choice"
        return 1
    fi

    local selected="${backups[$((choice-1))]}"
    log_info "Restoring from: $(basename "$selected")"

    local was_running=false
    is_running && was_running=true
    [ "$was_running" = true ] && stop_paqet

    if ! (umask 077; tar -xzf "$selected" -C "$INSTALL_DIR" 2>/dev/null); then
        log_error "Failed to extract backup archive"
        [ "$was_running" = true ] && start_paqet
        return 1
    fi
    chmod 600 "$INSTALL_DIR/config.yaml" "$INSTALL_DIR/settings.conf" 2>/dev/null
    chown root:root "$INSTALL_DIR/config.yaml" "$INSTALL_DIR/settings.conf" 2>/dev/null

    # Reload settings
    _load_settings

    log_success "Configuration restored"

    [ "$was_running" = true ] && start_paqet
}

#═══════════════════════════════════════════════════════════════════════
# Telegram Integration
#═══════════════════════════════════════════════════════════════════════

# Secure Telegram API curl - writes token to temp file to avoid /proc exposure
_telegram_api_curl() {
    local endpoint="$1"
    shift
    local _tg_tmp
    _tg_tmp=$(mktemp "${INSTALL_DIR}/.tg_curl.XXXXXXXX") || return 1
    chmod 600 "$_tg_tmp" 2>/dev/null
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TELEGRAM_BOT_TOKEN" "$endpoint" > "$_tg_tmp"
    local _result
    _result=$(curl -s --max-time 10 --max-filesize 1048576 -K "$_tg_tmp" "$@" 2>/dev/null)
    local _exit=$?
    rm -f "$_tg_tmp"
    [ $_exit -eq 0 ] && echo "$_result"
    return $_exit
}

escape_telegram_markdown() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

telegram_send_message() {
    local message="$1"
    { [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; } && return 1
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_telegram_markdown "$label")
    local _ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    if [ -n "$_ip" ]; then
        message="[${label} | ${_ip}] ${message}"
    else
        message="[${label}] ${message}"
    fi
    local response
    response=$(_telegram_api_curl "sendMessage" \
        -X POST \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message" \
        --data-urlencode "parse_mode=Markdown")
    [ $? -ne 0 ] && return 1
    echo "$response" | grep -q '"ok":true' && return 0
    return 1
}

telegram_get_chat_id() {
    local response
    response=$(_telegram_api_curl "getUpdates")
    [ -z "$response" ] && return 1
    echo "$response" | grep -q '"ok":true' || return 1
    local chat_id=""
    if command -v python3 &>/dev/null; then
        chat_id=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    msgs=d.get('result',[])
    if msgs:
        print(msgs[-1]['message']['chat']['id'])
except: pass
" <<< "$response" 2>/dev/null)
    fi
    if [ -z "$chat_id" ]; then
        chat_id=$(echo "$response" | grep -o '"chat"[[:space:]]*:[[:space:]]*{[[:space:]]*"id"[[:space:]]*:[[:space:]]*-\?[0-9]\+' | grep -o -- '-\?[0-9]\+$' | tail -1 2>/dev/null)
    fi
    if [ -n "$chat_id" ] && echo "$chat_id" | grep -qE '^-?[0-9]+$'; then
        TELEGRAM_CHAT_ID="$chat_id"
        return 0
    fi
    return 1
}

telegram_build_report() {
    local report="📊 *Paqet Status Report*"
    report+=$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"
    report+=$'\n\n'

    if is_running; then
        report+="✅ Status: Running"
    else
        report+="❌ Status: Stopped"
    fi
    report+=$'\n'
    report+="📡 Role: ${ROLE}"
    report+=$'\n'
    report+="📦 Version: ${PAQET_VERSION}"
    report+=$'\n'

    if [ "$ROLE" = "server" ]; then
        report+="🔌 Port: ${LISTEN_PORT}"
        report+=$'\n'
        if iptables -t raw -C PREROUTING -p tcp --dport "$LISTEN_PORT" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null; then
            report+="🛡 Firewall: Rules active"
        else
            report+="⚠️ Firewall: Rules missing"
        fi
    else
        report+="🔗 Server: ${REMOTE_SERVER}"
        report+=$'\n'
        report+="🧦 SOCKS: port ${SOCKS_PORT}"
    fi
    report+=$'\n'

    # Uptime
    if is_running && command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        local started
        started=$(systemctl show paqctl.service --property=ActiveEnterTimestamp 2>/dev/null | cut -d= -f2)
        if [ -n "$started" ]; then
            local started_ts
            started_ts=$(date -d "$started" +%s 2>/dev/null || echo 0)
            if [ "$started_ts" -gt 0 ] 2>/dev/null; then
                local now=$(date +%s)
                local up=$((now - started_ts))
                local days=$((up / 86400))
                local hours=$(( (up % 86400) / 3600 ))
                local mins=$(( (up % 3600) / 60 ))
                if [ "$days" -gt 0 ]; then
                    report+="⏱ Uptime: ${days}d ${hours}h ${mins}m"
                else
                    report+="⏱ Uptime: ${hours}h ${mins}m"
                fi
                report+=$'\n'
            fi
        fi
    fi

    # CPU/RAM
    local pid
    if [ "$BACKEND" = "gfw-knocker" ]; then
        pid=$(pgrep -f "mainserver.py|mainclient.py" 2>/dev/null | head -1)
    else
        pid=$(pgrep -f "paqet run -c" 2>/dev/null | head -1)
    fi
    if [ -n "$pid" ]; then
        local cpu_mem
        cpu_mem=$(ps -p "$pid" -o %cpu=,%mem= 2>/dev/null | head -1)
        if [ -n "$cpu_mem" ]; then
            local cpu=$(echo "$cpu_mem" | awk '{print $1}')
            local mem=$(echo "$cpu_mem" | awk '{print $2}')
            report+="💻 CPU: ${cpu}% | RAM: ${mem}%"
            report+=$'\n'
        fi
    fi

    echo "$report"
}

telegram_test_message() {
    local interval_label="${TELEGRAM_INTERVAL:-6}"
    local report=$(telegram_build_report)
    local backend_name="${BACKEND:-paqet}"

    # Backend-specific description
    local tech_desc=""
    if [ "$BACKEND" = "gfw-knocker" ]; then
        tech_desc="🔗 *What is GFW-Knocker?*
An advanced anti-censorship tool using 'violated TCP' packets + QUIC tunneling.
Designed for heavy DPI environments like the Great Firewall.
• Raw socket layer bypasses kernel TCP stack
• QUIC tunnel provides encrypted transport
• Requires Xray on server for SOCKS5 proxy"
    else
        tech_desc="🔗 *What is Paqet?*
A raw-socket encrypted proxy using KCP protocol.
Simple all-in-one solution with built-in SOCKS5 proxy.
• KCP over raw TCP packets with custom flags bypasses DPI
• Built-in SOCKS5 proxy (no extra software needed)
• Easy setup with just IP, port, and key"
    fi

    local message="✅ *paqctl Connected!*

📦 *About paqctl*
A unified management tool for bypass proxies.
Supports two backends for different network conditions:
• *paqet* — Simple KCP-based proxy (recommended)
• *gfw-knocker* — Advanced violated-TCP + QUIC tunnel

━━━━━━━━━━━━━━━━━━━━
${tech_desc}

📬 *What this bot sends you every ${interval_label}h:*
• Service status & uptime
• CPU & RAM usage
• Configuration summary
• Firewall rule status

⚠️ *Alerts:*
If the service goes down or is restarted, you will receive an immediate alert.

━━━━━━━━━━━━━━━━━━━━
🎮 *Available Commands:*
━━━━━━━━━━━━━━━━━━━━
/status — Full status report
/health — Run health check
/restart — Restart ${backend_name}
/stop — Stop ${backend_name}
/start — Start ${backend_name}
/version — Show version info

━━━━━━━━━━━━━━━━━━━━
📊 *Your first report:*
━━━━━━━━━━━━━━━━━━━━

${report}"
    telegram_send_message "$message"
}

telegram_generate_notify_script() {
    local script_path="$INSTALL_DIR/paqctl-telegram.sh"
    local _tmp
    _tmp=$(mktemp "${script_path}.XXXXXXXX")
    cat > "$_tmp" << 'TGSCRIPT'
#!/bin/bash
# paqctl Telegram notification daemon

INSTALL_DIR="REPLACE_ME_INSTALL_DIR"

# Safe settings loader - parses key=value with validation
_load_settings() {
    [ -f "$INSTALL_DIR/settings.conf" ] || return 0
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_][A-Z_0-9]*$ ]] || continue
        value="${value#\"}"; value="${value%\"}"
        # Skip values with dangerous shell characters
        [[ "$value" =~ [\`\$\(] ]] && continue
        case "$key" in
            BACKEND|ROLE|PAQET_VERSION|PAQCTL_VERSION|INTERFACE|LOCAL_IP|GATEWAY_MAC|\
            ENCRYPTION_KEY|REMOTE_SERVER|GFK_AUTH_CODE|GFK_PORT_MAPPINGS|GFK_SERVER_IP|\
            XRAY_PANEL_DETECTED|\
            TELEGRAM_BOT_TOKEN|TELEGRAM_CHAT_ID|TELEGRAM_SERVER_LABEL|\
            TELEGRAM_ENABLED|TELEGRAM_ALERTS_ENABLED|TELEGRAM_DAILY_SUMMARY|TELEGRAM_WEEKLY_SUMMARY)
                export "$key=$value" ;;
            LISTEN_PORT|SOCKS_PORT|GFK_VIO_PORT|GFK_VIO_CLIENT_PORT|GFK_QUIC_PORT|GFK_QUIC_CLIENT_PORT|MICROSOCKS_PORT|\
            GFK_SOCKS_PORT|GFK_SOCKS_VIO_PORT|\
            TELEGRAM_INTERVAL|TELEGRAM_START_HOUR)
                [[ "$value" =~ ^[0-9]*$ ]] && export "$key=$value" ;;
        esac
    done < <(grep '^[A-Z_][A-Z_0-9]*=' "$INSTALL_DIR/settings.conf")
}
_load_settings

TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
TELEGRAM_INTERVAL=${TELEGRAM_INTERVAL:-6}
TELEGRAM_ALERTS_ENABLED=${TELEGRAM_ALERTS_ENABLED:-true}
TELEGRAM_DAILY_SUMMARY=${TELEGRAM_DAILY_SUMMARY:-true}
TELEGRAM_WEEKLY_SUMMARY=${TELEGRAM_WEEKLY_SUMMARY:-true}
TELEGRAM_START_HOUR=${TELEGRAM_START_HOUR:-0}

{ [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; } && exit 1

escape_telegram_markdown() {
    local text="$1"
    text="${text//\\/\\\\}"
    text="${text//\*/\\*}"
    text="${text//_/\\_}"
    text="${text//\`/\\\`}"
    text="${text//\[/\\[}"
    text="${text//\]/\\]}"
    echo "$text"
}

# Secure Telegram API curl - writes token to temp file to avoid /proc exposure
_tg_api_curl() {
    local endpoint="$1"
    shift
    local _tg_tmp
    _tg_tmp=$(mktemp "${INSTALL_DIR}/.tg_curl.XXXXXXXX") || return 1
    chmod 600 "$_tg_tmp" 2>/dev/null
    printf 'url = "https://api.telegram.org/bot%s/%s"\n' "$TELEGRAM_BOT_TOKEN" "$endpoint" > "$_tg_tmp"
    local _result
    _result=$(curl -s --max-time 10 --max-filesize 1048576 -K "$_tg_tmp" "$@" 2>/dev/null)
    local _exit=$?
    rm -f "$_tg_tmp"
    [ $_exit -eq 0 ] && echo "$_result"
    return $_exit
}

send_message() {
    local message="$1"
    { [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; } && return 1
    local label="${TELEGRAM_SERVER_LABEL:-$(hostname 2>/dev/null || echo 'unknown')}"
    label=$(escape_telegram_markdown "$label")
    local _ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null || echo "")
    [ -n "$_ip" ] && message="[${label} | ${_ip}] ${message}" || message="[${label}] ${message}"
    local response
    response=$(_tg_api_curl "sendMessage" \
        -X POST \
        --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
        --data-urlencode "text=$message" \
        --data-urlencode "parse_mode=Markdown")
    [ $? -ne 0 ] && return 1
    echo "$response" | grep -q '"ok":true' && return 0
    return 1
}

is_running() {
    if [ "$BACKEND" = "gfw-knocker" ]; then
        pgrep -f "mainserver.py|mainclient.py|gfk-client.sh" &>/dev/null
    else
        pgrep -f "paqet run -c" &>/dev/null
    fi
}

get_main_pid() {
    if [ "$BACKEND" = "gfw-knocker" ]; then
        pgrep -f "mainserver.py" 2>/dev/null | head -1
    else
        pgrep -f "paqet run -c" 2>/dev/null | head -1
    fi
}

build_report() {
    local report="📊 *${BACKEND} Status Report*"$'\n'
    report+="🕐 $(date '+%Y-%m-%d %H:%M %Z')"$'\n\n'
    if is_running; then
        report+="✅ Status: Running"
    else
        report+="❌ Status: Stopped"
    fi
    report+=$'\n'"📡 Role: ${ROLE:-unknown}"$'\n'
    report+="📦 Version: ${PAQET_VERSION:-unknown}"$'\n'
    local pid=$(get_main_pid)
    if [ -n "$pid" ]; then
        local cpu_mem=$(ps -p "$pid" -o %cpu=,%mem= 2>/dev/null | head -1)
        if [ -n "$cpu_mem" ]; then
            local cpu=$(echo "$cpu_mem" | awk '{print $1}')
            local mem=$(echo "$cpu_mem" | awk '{print $2}')
            report+="💻 CPU: ${cpu}% | RAM: ${mem}%"$'\n'
        fi
    fi
    echo "$report"
}

LAST_COMMAND_TIME=0
COMMAND_COOLDOWN=5

check_commands() {
    local response
    response=$(_tg_api_curl "getUpdates" \
        -X POST \
        --data-urlencode "offset=${LAST_UPDATE_ID:-0}" \
        --data-urlencode "limit=10")
    [ -z "$response" ] && return
    echo "$response" | grep -q '"ok":true' || return

    if command -v python3 &>/dev/null; then
        local cmds
        local _safe_chat_id
        _safe_chat_id=$(printf '%s' "$TELEGRAM_CHAT_ID" | tr -cd '0-9-')
        [ -z "$_safe_chat_id" ] && return
        cmds=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    chat_id=sys.argv[1]
    if not chat_id: sys.exit(0)
    for r in d.get('result',[]):
        uid=r['update_id']
        txt=r.get('message',{}).get('text','').replace('|','')
        cid=str(r.get('message',{}).get('chat',{}).get('id',''))
        if cid==chat_id and txt.startswith('/'):
            print(f'{uid}|{txt}')
except: pass
" "$_safe_chat_id" <<< "$response" 2>/dev/null)

        while IFS='|' read -r uid cmd; do
            [ -z "$uid" ] && continue
            # Validate uid is numeric
            [[ "$uid" =~ ^[0-9]+$ ]] || continue
            LAST_UPDATE_ID=$((uid + 1))
            cmd="${cmd%% *}"  # strip arguments, match command only

            # Rate limiting
            local _now
            _now=$(date +%s)
            if [ $((_now - LAST_COMMAND_TIME)) -lt $COMMAND_COOLDOWN ]; then
                continue
            fi
            LAST_COMMAND_TIME=$_now

            case "$cmd" in
                /status)  send_message "$(build_report)" ;;
                /health)  send_message "$(/usr/local/bin/paqctl health 2>&1 | head -30)" ;;
                /restart) /usr/local/bin/paqctl restart 2>&1; send_message "🔄 Service restarted" ;;
                /stop)    /usr/local/bin/paqctl stop 2>&1; send_message "⏹ Service stopped" ;;
                /start)   /usr/local/bin/paqctl start 2>&1; send_message "▶️ Service started" ;;
                /version) send_message "📦 Version: ${PAQET_VERSION:-unknown} | paqctl: ${PAQCTL_VERSION:-unknown}" ;;
            esac
        done <<< "$cmds"
    fi
}

# Alert state
LAST_STATE="unknown"
LAST_REPORT=0
LAST_DAILY=0
LAST_WEEKLY=0
LAST_UPDATE_ID=0

# Initialize update offset
init_response=$(_tg_api_curl "getUpdates" \
    -X POST \
    --data-urlencode "offset=-1")
if command -v python3 &>/dev/null; then
    LAST_UPDATE_ID=$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read())
    r=d.get('result',[])
    if r: print(r[-1]['update_id']+1)
    else: print(0)
except: print(0)
" <<< "$init_response" 2>/dev/null)
fi
LAST_UPDATE_ID=${LAST_UPDATE_ID:-0}

# Send startup notification
send_message "🚀 *Telegram notifications started*"$'\n'"Reports every ${TELEGRAM_INTERVAL}h | Alerts: ${TELEGRAM_ALERTS_ENABLED}"

while true; do
    # Reload settings periodically (safe parser, no code execution)
    _load_settings

    # Check commands from Telegram
    check_commands

    # Service state alerts
    current_state="stopped"
    is_running && current_state="running"

    if [ "$TELEGRAM_ALERTS_ENABLED" = "true" ]; then
        if [ "$LAST_STATE" = "running" ] && [ "$current_state" = "stopped" ]; then
            send_message "🚨 *ALERT:* ${BACKEND} service has stopped!"
        elif [ "$LAST_STATE" = "stopped" ] && [ "$current_state" = "running" ]; then
            send_message "✅ ${BACKEND} service is back up"
        fi

        # High CPU alert
        _pid=$(get_main_pid)
        if [ -n "$_pid" ]; then
            _cpu=$(ps -p "$_pid" -o %cpu= 2>/dev/null | awk '{printf "%.0f", $1}')
            if [ "${_cpu:-0}" -gt 80 ] 2>/dev/null; then
                send_message "⚠️ High CPU usage: ${_cpu}%"
            fi
        fi
    fi
    LAST_STATE="$current_state"

    # Periodic reports
    _now=$(date +%s)
    _interval_secs=$(( ${TELEGRAM_INTERVAL:-6} * 3600 ))
    if [ $((_now - LAST_REPORT)) -ge "$_interval_secs" ]; then
        send_message "$(build_report)"
        LAST_REPORT=$_now
    fi

    # Daily summary
    _hour=$(date +%H)
    _day_of_week=$(date +%u)
    if [ "$TELEGRAM_DAILY_SUMMARY" = "true" ] && [ "$_hour" = "$(printf '%02d' ${TELEGRAM_START_HOUR:-0})" ]; then
        if [ $((_now - LAST_DAILY)) -ge 86400 ]; then
            send_message "📅 *Daily Summary*"$'\n'"$(build_report)"
            LAST_DAILY=$_now
        fi
    fi

    # Weekly summary (Monday)
    if [ "$TELEGRAM_WEEKLY_SUMMARY" = "true" ] && [ "$_day_of_week" = "1" ] && [ "$_hour" = "$(printf '%02d' ${TELEGRAM_START_HOUR:-0})" ]; then
        if [ $((_now - LAST_WEEKLY)) -ge 604800 ]; then
            send_message "📆 *Weekly Summary*"$'\n'"$(build_report)"
            LAST_WEEKLY=$_now
        fi
    fi

    sleep 30
done
TGSCRIPT

    sed "s#REPLACE_ME_INSTALL_DIR#$INSTALL_DIR#g" "$_tmp" > "$_tmp.sed" && mv "$_tmp.sed" "$_tmp"
    if ! chmod +x "$_tmp"; then
        log_error "Failed to make Telegram script executable"
        rm -f "$_tmp"
        return 1
    fi
    if ! mv "$_tmp" "$script_path"; then
        log_error "Failed to install Telegram script"
        rm -f "$_tmp"
        return 1
    fi
}

setup_telegram_service() {
    telegram_generate_notify_script

    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        cat > /etc/systemd/system/paqctl-telegram.service << EOF
[Unit]
Description=paqctl Telegram Notification Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$(command -v bash) ${INSTALL_DIR}/paqctl-telegram.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable paqctl-telegram.service 2>/dev/null || true
        systemctl start paqctl-telegram.service 2>/dev/null || true
        log_success "Telegram service started"
    else
        log_warn "Systemd not available. Run the Telegram daemon manually:"
        log_info "  nohup bash $INSTALL_DIR/paqctl-telegram.sh &"
    fi
}

stop_telegram_service() {
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl stop paqctl-telegram.service 2>/dev/null || true
        systemctl disable paqctl-telegram.service 2>/dev/null || true
    fi
    pkill -f "paqctl-telegram.sh" 2>/dev/null || true
    log_success "Telegram service stopped"
}

show_telegram_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}  TELEGRAM NOTIFICATIONS${NC}"
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo ""

            if [ "$TELEGRAM_ENABLED" = "true" ]; then
                echo -e "  Status: ${GREEN}Enabled${NC}"
                if command -v systemctl &>/dev/null && systemctl is-active paqctl-telegram.service &>/dev/null; then
                    echo -e "  Service: ${GREEN}Running${NC}"
                else
                    echo -e "  Service: ${RED}Stopped${NC}"
                fi
            else
                echo -e "  Status: ${DIM}Disabled${NC}"
            fi

            echo ""
            echo "  1. Setup / Change bot"
            echo "  2. Test notification"
            echo "  3. Enable & start service"
            echo "  4. Disable & stop service"
            echo "  5. Set check interval (currently: ${TELEGRAM_INTERVAL}h)"
            echo "  6. Set server label (currently: ${TELEGRAM_SERVER_LABEL:-hostname})"
            echo "  7. Toggle alerts (currently: ${TELEGRAM_ALERTS_ENABLED})"
            echo "  b. Back"
            echo ""
            redraw=false
        fi

        read -p "  Choice: " tg_choice < /dev/tty || break
        case "$tg_choice" in
            1)
                echo ""
                echo -e "${BOLD}Telegram Bot Setup${NC}"
                echo ""
                echo "  1. Open Telegram and message @BotFather"
                echo "  2. Send /newbot and follow the steps"
                echo "  3. Copy the bot token"
                echo ""
                read -p "  Enter bot token: " input < /dev/tty || true
                if [ -n "$input" ]; then
                    TELEGRAM_BOT_TOKEN="$input"
                    echo ""
                    echo "  Now send any message to your bot in Telegram..."
                    echo ""
                    for _i in $(seq 15 -1 1); do
                        printf "\r  Waiting: %2ds " "$_i"
                        sleep 1
                    done
                    printf "\r                    \r"
                    if telegram_get_chat_id; then
                        log_success "Chat ID detected: $TELEGRAM_CHAT_ID"
                        # Save
                        _safe_update_setting "TELEGRAM_BOT_TOKEN" "$TELEGRAM_BOT_TOKEN" "$INSTALL_DIR/settings.conf"
                        _safe_update_setting "TELEGRAM_CHAT_ID" "$TELEGRAM_CHAT_ID" "$INSTALL_DIR/settings.conf"
                    else
                        log_error "Could not detect chat ID. Make sure you sent a message to the bot."
                        echo ""
                        read -p "  Enter chat ID manually (or press Enter to cancel): " input < /dev/tty || true
                        if [ -n "$input" ]; then
                            TELEGRAM_CHAT_ID="$input"
                            _safe_update_setting "TELEGRAM_BOT_TOKEN" "$TELEGRAM_BOT_TOKEN" "$INSTALL_DIR/settings.conf"
                            _safe_update_setting "TELEGRAM_CHAT_ID" "$TELEGRAM_CHAT_ID" "$INSTALL_DIR/settings.conf"
                        fi
                    fi
                fi
                redraw=true
                ;;
            2)
                if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
                    log_error "Bot not configured. Run setup first."
                else
                    if telegram_test_message; then
                        log_success "Test message sent!"
                    else
                        log_error "Failed to send. Check token and chat ID."
                    fi
                fi
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            3)
                if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
                    log_error "Bot not configured. Run setup first."
                else
                    TELEGRAM_ENABLED=true
                    _safe_update_setting "TELEGRAM_ENABLED" "true" "$INSTALL_DIR/settings.conf"
                    setup_telegram_service
                fi
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            4)
                TELEGRAM_ENABLED=false
                _safe_update_setting "TELEGRAM_ENABLED" "false" "$INSTALL_DIR/settings.conf"
                stop_telegram_service
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            5)
                echo ""
                read -p "  Check interval in hours [1-24]: " input < /dev/tty || true
                if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 24 ]; then
                    TELEGRAM_INTERVAL="$input"
                    _safe_update_setting "TELEGRAM_INTERVAL" "$input" "$INSTALL_DIR/settings.conf"
                    log_success "Interval set to ${input}h"
                    # Restart service if running
                    if command -v systemctl &>/dev/null && systemctl is-active paqctl-telegram.service &>/dev/null; then
                        telegram_generate_notify_script
                        systemctl restart paqctl-telegram.service 2>/dev/null || true
                    fi
                else
                    log_warn "Invalid value"
                fi
                redraw=true
                ;;
            6)
                echo ""
                read -p "  Server label: " input < /dev/tty || true
                if [ -n "$input" ]; then
                    TELEGRAM_SERVER_LABEL="$input"
                    _safe_update_setting "TELEGRAM_SERVER_LABEL" "$input" "$INSTALL_DIR/settings.conf"
                    log_success "Label set to: $input"
                fi
                redraw=true
                ;;
            7)
                if [ "$TELEGRAM_ALERTS_ENABLED" = "true" ]; then
                    TELEGRAM_ALERTS_ENABLED=false
                else
                    TELEGRAM_ALERTS_ENABLED=true
                fi
                _safe_update_setting "TELEGRAM_ALERTS_ENABLED" "$TELEGRAM_ALERTS_ENABLED" "$INSTALL_DIR/settings.conf"
                log_info "Alerts: $TELEGRAM_ALERTS_ENABLED"
                redraw=true
                ;;
            b|B) return ;;
            "") ;;
            *) echo -e "  ${RED}Invalid choice${NC}" ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════
# Switch Backend
#═══════════════════════════════════════════════════════════════════════

switch_backend() {
    local current_backend="${BACKEND:-paqet}"
    local new_backend
    if [ "$current_backend" = "paqet" ]; then
        new_backend="gfw-knocker"
    else
        new_backend="paqet"
    fi

    # Check if the other backend is installed
    local other_installed=false
    if [ "$new_backend" = "gfw-knocker" ]; then
        if [ "$ROLE" = "server" ]; then
            [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_server.py" ] && other_installed=true
        else
            [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_client.py" ] && other_installed=true
        fi
    else
        [ -f "$INSTALL_DIR/bin/paqet" ] && other_installed=true
    fi

    if [ "$other_installed" = false ]; then
        echo ""
        echo -e "${YELLOW}${new_backend} is not installed.${NC}"
        echo ""
        echo "  Use 'Install additional backend' option to install it first."
        echo ""
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        return 0
    fi

    echo ""
    echo -e "${BOLD}Switch active backend from ${current_backend} to ${new_backend}?${NC}"
    echo ""
    echo "  This will:"
    echo "  - Stop ${current_backend}"
    echo "  - Start ${new_backend}"
    echo ""
    read -p "  Proceed? [y/N]: " confirm < /dev/tty || true
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "Cancelled"; return 0; }

    # Stop current
    stop_paqet
    _remove_firewall

    # Switch to new backend
    BACKEND="$new_backend"
    save_settings

    # Setup firewall and start new backend
    _apply_firewall
    start_paqet

    log_success "Switched to ${new_backend}"
    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
}

install_additional_backend() {
    local current_backend="${BACKEND:-paqet}"
    local new_backend
    if [ "$current_backend" = "paqet" ]; then
        new_backend="gfw-knocker"
    else
        new_backend="paqet"
    fi

    # Check if already installed
    local already_installed=false
    if [ "$new_backend" = "gfw-knocker" ]; then
        if [ "$ROLE" = "server" ]; then
            [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_server.py" ] && already_installed=true
        else
            [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_client.py" ] && already_installed=true
        fi
    else
        [ -f "$INSTALL_DIR/bin/paqet" ] && already_installed=true
    fi

    if [ "$already_installed" = true ]; then
        echo ""
        echo -e "${GREEN}${new_backend} is already installed.${NC}"
        echo ""
        echo "  Use 'Switch backend' to change the active backend."
        echo ""
        read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
        return 0
    fi

    echo ""
    echo -e "${BOLD}Install ${new_backend} alongside ${current_backend}?${NC}"
    echo ""
    echo "  This will:"
    echo "  - Keep ${current_backend} running"
    echo "  - Install ${new_backend} as an additional option"
    echo "  - You can switch between them anytime"
    echo ""
    read -p "  Proceed? [y/N]: " confirm < /dev/tty || true
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "Cancelled"; return 0; }

    echo ""
    log_info "Installing ${new_backend}..."

    if [ "$new_backend" = "gfw-knocker" ]; then
        # Collect GFK configuration for client role
        if [ "$ROLE" = "client" ]; then
            echo ""
            echo -e "${BOLD}GFK Client Configuration${NC}"
            echo -e "${DIM}(these must match your server settings)${NC}"
            echo ""

            echo -e "${BOLD}Server IP${NC} (server's public IP):"
            read -p "  IP: " input < /dev/tty || true
            if [ -z "$input" ] || ! _validate_ip "$input"; then
                log_error "Valid server IP is required."
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                return 1
            fi
            GFK_SERVER_IP="$input"

            echo -e "${BOLD}Server's VIO TCP port${NC} [45000] (must match server):"
            read -p "  Port: " input < /dev/tty || true
            GFK_VIO_PORT="${input:-45000}"
            if ! _validate_port "$GFK_VIO_PORT"; then
                log_warn "Invalid port. Using default 45000."
                GFK_VIO_PORT=45000
            fi

            echo -e "${BOLD}Local VIO client port${NC} [40000]:"
            read -p "  Port: " input < /dev/tty || true
            GFK_VIO_CLIENT_PORT="${input:-40000}"
            if ! _validate_port "$GFK_VIO_CLIENT_PORT"; then
                log_warn "Invalid port. Using default 40000."
                GFK_VIO_CLIENT_PORT=40000
            fi

            echo -e "${BOLD}Server's QUIC port${NC} [25000] (must match server):"
            read -p "  Port: " input < /dev/tty || true
            GFK_QUIC_PORT="${input:-25000}"
            if ! _validate_port "$GFK_QUIC_PORT"; then
                log_warn "Invalid port. Using default 25000."
                GFK_QUIC_PORT=25000
            fi

            echo -e "${BOLD}Local QUIC client port${NC} [20000]:"
            read -p "  Port: " input < /dev/tty || true
            GFK_QUIC_CLIENT_PORT="${input:-20000}"
            if ! _validate_port "$GFK_QUIC_CLIENT_PORT"; then
                log_warn "Invalid port. Using default 20000."
                GFK_QUIC_CLIENT_PORT=20000
            fi

            echo -e "${BOLD}QUIC auth code${NC} (from server setup):"
            read -p "  Auth code: " input < /dev/tty || true
            if [ -z "$input" ]; then
                log_error "Auth code is required."
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                return 1
            fi
            GFK_AUTH_CODE="$input"

            echo -e "${BOLD}TCP port mappings${NC} (must match server) [14000:443]:"
            read -p "  Mappings: " input < /dev/tty || true
            GFK_PORT_MAPPINGS="${input:-14000:443}"
            echo ""
        fi

        # Install GFK without changing current backend
        if ! _install_gfk_components; then
            log_error "Failed to install ${new_backend}"
            read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
            return 1
        fi
    else
        # Install paqet without changing current backend
        if ! _install_paqet_components; then
            log_error "Failed to install ${new_backend}"
            read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
            return 1
        fi
    fi

    echo ""
    log_success "${new_backend} installed successfully!"
    echo ""
    echo "  Use 'Switch backend' to activate it."
    echo ""
    read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
}

_install_paqet_components() {
    log_info "Downloading paqet binary..."
    if ! download_paqet "$PAQET_VERSION_PINNED"; then
        log_error "Failed to download paqet"
        return 1
    fi
    log_success "paqet binary installed"

    # Generate config.yaml if it doesn't exist
    if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
        echo ""
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  PAQET CONFIGURATION${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
        echo ""

        # Detect network settings
        detect_network
        local _det_iface="$DETECTED_IFACE"
        local _det_ip="$DETECTED_IP"
        local _det_mac="$DETECTED_GW_MAC"

        # Prompt for interface
        echo -e "${BOLD}Network Interface${NC} [${_det_iface:-eth0}]:"
        read -p "  Interface: " input < /dev/tty || true
        local _iface="${input:-${_det_iface:-eth0}}"

        # Prompt for local IP
        echo -e "${BOLD}Local IP${NC} [${_det_ip:-}]:"
        read -p "  IP: " input < /dev/tty || true
        local _local_ip="${input:-$_det_ip}"

        # Prompt for gateway MAC
        echo -e "${BOLD}Gateway MAC${NC} [${_det_mac:-}]:"
        read -p "  MAC: " input < /dev/tty || true
        local _gw_mac="${input:-$_det_mac}"

        # Validate MAC if provided
        if [ -n "$_gw_mac" ] && ! [[ "$_gw_mac" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
            log_warn "Invalid MAC format. Expected: aa:bb:cc:dd:ee:ff"
            read -p "  Enter valid MAC: " input < /dev/tty || true
            [ -n "$input" ] && _gw_mac="$input"
        fi

        # Generate encryption key
        local _key
        _key=$("$INSTALL_DIR/bin/paqet" secret 2>/dev/null || true)
        if [ -z "$_key" ]; then
            _key=$(openssl rand -base64 32 2>/dev/null | tr -d '=+/' | head -c 32 || true)
        fi

        if [ "$ROLE" = "server" ]; then
            # Prompt for port
            echo -e "${BOLD}Listen Port${NC} [8443]:"
            read -p "  Port: " input < /dev/tty || true
            local _port="${input:-8443}"

            # Show generated key
            echo ""
            echo -e "${GREEN}${BOLD}  Generated Encryption Key: ${_key}${NC}"
            echo -e "${YELLOW}  IMPORTANT: Save this key! Clients need it to connect.${NC}"
            echo ""
            echo -e "${BOLD}Encryption Key${NC} (press Enter to use generated key):"
            read -p "  Key: " input < /dev/tty || true
            [ -n "$input" ] && _key="$input"

            LISTEN_PORT="$_port"
            ENCRYPTION_KEY="$_key"
        else
            # Client prompts
            echo -e "${BOLD}Remote Server${NC} (IP:PORT):"
            read -p "  Server: " input < /dev/tty || true
            local _server="${input:-${REMOTE_SERVER:-}}"
            if [ -z "$_server" ]; then
                log_warn "No server specified. You must edit config.yaml later."
                _server="SERVER_IP:8443"
            fi

            echo -e "${BOLD}Encryption Key${NC} (from server):"
            read -p "  Key: " input < /dev/tty || true
            [ -n "$input" ] && _key="$input"

            echo -e "${BOLD}SOCKS5 Port${NC} [1080]:"
            read -p "  Port: " input < /dev/tty || true
            local _socks="${input:-1080}"

            REMOTE_SERVER="$_server"
            SOCKS_PORT="$_socks"
            ENCRYPTION_KEY="$_key"
        fi

        # Validate required fields
        if [ -z "$_iface" ] || [ -z "$_local_ip" ] || [ -z "$_gw_mac" ]; then
            log_error "Missing required fields (interface, IP, or MAC)"
            return 1
        fi
        if [ -z "$_key" ] || [ "${#_key}" -lt 16 ]; then
            log_error "Invalid encryption key"
            return 1
        fi

        # Helper to escape YAML values
        _escape_yaml_val() {
            local s="$1"
            if [[ "$s" =~ [:\#\[\]{}\"\'\|\>\<\&\*\!\%\@\`] ]] || [[ "$s" =~ ^[[:space:]] ]] || [[ "$s" =~ [[:space:]]$ ]]; then
                s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"
            else
                printf '%s' "$s"
            fi
        }

        local _y_iface _y_ip _y_mac _y_key
        _y_iface=$(_escape_yaml_val "$_iface")
        _y_ip=$(_escape_yaml_val "$_local_ip")
        _y_mac=$(_escape_yaml_val "$_gw_mac")
        _y_key=$(_escape_yaml_val "$_key")

        local tmp_conf
        tmp_conf=$(mktemp "$INSTALL_DIR/config.yaml.XXXXXXXX") || { log_error "Failed to create temp file"; return 1; }
        chmod 600 "$tmp_conf" 2>/dev/null

        if [ "$ROLE" = "server" ]; then
            cat > "$tmp_conf" << EOF
role: "server"

log:
  level: "info"

listen:
  addr: ":${_port}"

network:
  interface: "${_y_iface}"
  ipv4:
    addr: "${_y_ip}:${_port}"
    router_mac: "${_y_mac}"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "${_y_key}"
EOF
        else
            cat > "$tmp_conf" << EOF
role: "client"

log:
  level: "info"

socks5:
  - listen: "127.0.0.1:${_socks}"

network:
  interface: "${_y_iface}"
  ipv4:
    addr: "${_y_ip}:0"
    router_mac: "${_y_mac}"

server:
  addr: "${_server}"

transport:
  protocol: "kcp"
  kcp:
    mode: "fast"
    key: "${_y_key}"
EOF
        fi

        if ! mv "$tmp_conf" "$INSTALL_DIR/config.yaml"; then
            log_error "Failed to save config.yaml"
            rm -f "$tmp_conf"
            return 1
        fi
        chmod 600 "$INSTALL_DIR/config.yaml" 2>/dev/null

        # Update global vars for settings
        INTERFACE="$_iface"
        LOCAL_IP="$_local_ip"
        GATEWAY_MAC="$_gw_mac"

        log_success "Configuration saved to $INSTALL_DIR/config.yaml"

        # Save to settings.conf for persistence
        save_settings 2>/dev/null || true
    fi
}

check_xray_installed() {
    command -v xray &>/dev/null && return 0
    [ -x /usr/local/bin/xray ] && return 0
    [ -x /usr/local/x-ui/bin/xray-linux-amd64 ] && return 0
    return 1
}

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG_FILE="$XRAY_CONFIG_DIR/config.json"

install_xray() {
    if check_xray_installed; then
        log_info "Xray is already installed"
        return 0
    fi

    log_info "Installing Xray ${XRAY_VERSION_PINNED}..."

    local tmp_script
    tmp_script=$(mktemp)
    if ! curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o "$tmp_script"; then
        log_error "Failed to download Xray installer"
        rm -f "$tmp_script"
        return 1
    fi

    if ! bash "$tmp_script" install --version "$XRAY_VERSION_PINNED" 2>/dev/null; then
        log_error "Failed to install Xray"
        rm -f "$tmp_script"
        return 1
    fi
    rm -f "$tmp_script"

    log_success "Xray ${XRAY_VERSION_PINNED} installed"
}

configure_xray_socks() {
    local listen_port="${1:-443}"
    log_info "Configuring Xray SOCKS5 proxy on port $listen_port..."
    mkdir -p "$XRAY_CONFIG_DIR"
    cat > "$XRAY_CONFIG_FILE" << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [{
    "tag": "socks-in",
    "port": ${listen_port},
    "listen": "127.0.0.1",
    "protocol": "socks",
    "settings": { "auth": "noauth", "udp": true },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
  }],
  "outbounds": [{ "tag": "direct", "protocol": "freedom", "settings": {} }]
}
EOF
    chmod 644 "$XRAY_CONFIG_FILE"
    log_success "Xray configured (SOCKS5 on 127.0.0.1:$listen_port)"
}

_is_paqctl_standalone_xray() {
    [ -f "$XRAY_CONFIG_FILE" ] || return 1
    command -v python3 &>/dev/null || return 1
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        cfg = json.load(f)
    inbounds = cfg.get('inbounds', [])
    if not inbounds:
        sys.exit(1)
    for i in inbounds:
        if i.get('protocol') != 'socks' or i.get('listen', '0.0.0.0') != '127.0.0.1':
            sys.exit(1)
    sys.exit(0)
except:
    sys.exit(1)
" "$XRAY_CONFIG_FILE" 2>/dev/null
}

_add_xray_gfk_socks() {
    local port="$1"
    python3 -c "
import json, sys
port = int(sys.argv[1])
config_path = sys.argv[2]
try:
    with open(config_path, 'r') as f:
        cfg = json.load(f)
except:
    cfg = {'inbounds': [], 'outbounds': [{'tag': 'direct', 'protocol': 'freedom', 'settings': {}}]}
cfg.setdefault('inbounds', [])
cfg['inbounds'] = [i for i in cfg['inbounds'] if i.get('tag') != 'gfk-socks']
cfg['inbounds'].append({
    'tag': 'gfk-socks', 'port': port, 'listen': '127.0.0.1', 'protocol': 'socks',
    'settings': {'auth': 'noauth', 'udp': True},
    'sniffing': {'enabled': True, 'destOverride': ['http', 'tls']}
})
if not any(o.get('protocol') == 'freedom' for o in cfg.get('outbounds', [])):
    cfg.setdefault('outbounds', []).append({'tag': 'direct', 'protocol': 'freedom', 'settings': {}})
with open(config_path, 'w') as f:
    json.dump(cfg, f, indent=2)
" "$port" "$XRAY_CONFIG_FILE" 2>/dev/null
    if [ $? -ne 0 ]; then
        log_error "Failed to add SOCKS5 inbound to existing Xray config"
        return 1
    fi
    log_success "Added GFK SOCKS5 inbound on 127.0.0.1:$port"
}

stop_xray() {
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl stop xray 2>/dev/null || true
    else
        pkill -x xray 2>/dev/null || true
    fi
}

start_xray() {
    log_info "Starting Xray service..."
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl stop xray 2>/dev/null || true
        sleep 1
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable xray 2>/dev/null || true
        local attempt
        for attempt in 1 2 3; do
            systemctl start xray 2>/dev/null
            sleep 2
            if systemctl is-active --quiet xray; then
                log_success "Xray started"
                return 0
            fi
            [ "$attempt" -lt 3 ] && sleep 1
        done
        log_error "Failed to start Xray after 3 attempts"
        return 1
    else
        local _xray_bin=""
        [ -x /usr/local/bin/xray ] && _xray_bin="/usr/local/bin/xray"
        [ -z "$_xray_bin" ] && [ -x /usr/local/x-ui/bin/xray-linux-amd64 ] && _xray_bin="/usr/local/x-ui/bin/xray-linux-amd64"
        if [ -n "$_xray_bin" ]; then
            pkill -x xray 2>/dev/null || true
            sleep 1
            nohup "$_xray_bin" run -c "$XRAY_CONFIG_FILE" > /var/log/xray.log 2>&1 &
            sleep 2
            if pgrep -f "xray" &>/dev/null; then
                log_success "Xray started"
                return 0
            fi
        fi
        log_error "Failed to start Xray"
        return 1
    fi
}

setup_xray_for_gfk() {
    local target_port
    target_port=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d: -f2 | cut -d, -f1)

    if pgrep -x xray &>/dev/null || pgrep -f "xray-linux" &>/dev/null; then
        # Check if this is paqctl's own standalone Xray (not a real panel)
        if _is_paqctl_standalone_xray; then
            log_info "Existing Xray is paqctl's standalone install — reconfiguring..."
            stop_xray
            sleep 1
            # Fall through to standalone install path below
        else
            XRAY_PANEL_DETECTED=true
            log_info "Existing Xray detected — adding SOCKS5 alongside panel..."

            # Clean up any leftover standalone GFK xray from prior installs
            pkill -f "xray run -c.*gfk-socks.json" 2>/dev/null || true
            rm -f "${XRAY_CONFIG_DIR}/gfk-socks.json" 2>/dev/null

            # Check all existing target ports from mappings
            local mapping pairs
            IFS=',' read -ra pairs <<< "${GFK_PORT_MAPPINGS:-14000:443}"
            for mapping in "${pairs[@]}"; do
                local vio_port="${mapping%%:*}"
                local tp="${mapping##*:}"
                if ss -tln 2>/dev/null | grep -q ":${tp} "; then
                    log_success "Port $tp is listening — GFK will forward VIO port $vio_port to this port"
                else
                    log_warn "Port $tp is NOT listening — make sure your panel inbound is on port $tp"
                fi
            done

            # Find free port for SOCKS5 (starting at 10443)
            local socks_port=10443
            while ss -tln 2>/dev/null | grep -q ":${socks_port} "; do
                socks_port=$((socks_port + 1))
                if [ "$socks_port" -gt 65000 ]; then
                    log_warn "Could not find free port for SOCKS5 — panel-only mode"
                    echo ""
                    local first_vio
                    first_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d: -f1 | cut -d, -f1)
                    log_warn "For panel-to-panel: configure Iran panel outbound to 127.0.0.1:${first_vio}"
                    return 0
                fi
            done

            # Add SOCKS5 inbound to existing xray config
            _add_xray_gfk_socks "$socks_port" || {
                log_warn "Could not add SOCKS5 to panel config — panel-only mode"
                return 0
            }

            # Restart xray to load new config
            systemctl restart xray 2>/dev/null || pkill -SIGHUP xray 2>/dev/null || true
            sleep 2

            # Find next VIO port (highest existing + 1) and append SOCKS5 mapping
            local max_vio=0
            for mapping in "${pairs[@]}"; do
                local v="${mapping%%:*}"
                [ "$v" -gt "$max_vio" ] && max_vio="$v"
            done
            local socks_vio=$((max_vio + 1))
            GFK_PORT_MAPPINGS="${GFK_PORT_MAPPINGS},${socks_vio}:${socks_port}"
            GFK_SOCKS_PORT="$socks_port"
            GFK_SOCKS_VIO_PORT="$socks_vio"

            log_success "SOCKS5 proxy added on port $socks_port (VIO port $socks_vio)"
            echo ""
            log_info "Port mappings updated: ${GFK_PORT_MAPPINGS}"
            log_warn "Use these SAME mappings on the client side"
            echo ""
            local first_vio
            first_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d: -f1 | cut -d, -f1)
            log_warn "For panel-to-panel: configure Iran panel outbound to 127.0.0.1:${first_vio}"
            log_warn "For direct SOCKS5: use 127.0.0.1:${socks_vio} as your proxy on client"
            return 0
        fi
    fi

    install_xray || return 1
    configure_xray_socks "$target_port" || return 1
    start_xray || return 1
}

_install_gfk_components() {
    log_info "Installing GFK components..."

    # Auto-detect server IP if not set (critical for server-side sniffer filter)
    if [ -z "${GFK_SERVER_IP:-}" ] && [ "$ROLE" = "server" ]; then
        GFK_SERVER_IP="${LOCAL_IP:-}"
        [ -z "$GFK_SERVER_IP" ] && GFK_SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
        [ -z "$GFK_SERVER_IP" ] && GFK_SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        if [ -n "$GFK_SERVER_IP" ]; then
            log_info "Auto-detected server IP: ${GFK_SERVER_IP}"
        else
            log_error "Could not detect server IP. Set GFK_SERVER_IP manually."
            return 1
        fi
    fi

    # Auto-generate auth code if not set
    if [ -z "${GFK_AUTH_CODE:-}" ] || [ "$GFK_AUTH_CODE" = "not set" ]; then
        GFK_AUTH_CODE=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16 2>/dev/null || openssl rand -hex 8)
        log_info "Generated GFK auth code: ${GFK_AUTH_CODE}"
    fi

    # Save settings with server IP and auth code
    save_settings

    # Install Python dependencies (venv + scapy + aioquic)
    install_python_deps || return 1

    # Download GFK scripts (server and client)
    download_gfk || return 1

    # Generate TLS certificates for QUIC
    generate_gfk_certs || return 1

    # Setup Xray (server only — adds SOCKS5 alongside panel if detected)
    if [ "$ROLE" = "server" ]; then
        setup_xray_for_gfk || return 1
    elif [ "$ROLE" = "client" ]; then
        create_gfk_client_wrapper
    fi

    # Generate parameters.py config
    generate_gfk_config || return 1

    save_settings

    log_success "GFK components installed"
}

#═══════════════════════════════════════════════════════════════════════
# Uninstall
#═══════════════════════════════════════════════════════════════════════

uninstall_paqctl() {
    echo ""
    echo -e "${RED}${BOLD}  UNINSTALL PAQCTL${NC}"
    echo ""
    echo -e "  This will remove:"
    if [ "$BACKEND" = "gfw-knocker" ]; then
        echo "  - GFW-knocker scripts and config"
    else
        echo "  - paqet binary"
    fi
    echo "  - All configuration files"
    echo "  - Systemd services"
    echo "  - Firewall rules"
    echo "  - Telegram service"
    echo ""
    read -p "  Are you sure? [y/N]: " confirm < /dev/tty || true
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled"
        return 0
    fi

    # Stop services
    stop_paqet
    stop_telegram_service

    # Stop standalone GFK xray and clean up config
    pkill -f "xray run -c.*gfk-socks.json" 2>/dev/null || true
    rm -f /usr/local/etc/xray/gfk-socks.json 2>/dev/null
    # If xray is paqctl's standalone install, stop and disable it entirely
    if _is_paqctl_standalone_xray; then
        log_info "Stopping paqctl's standalone Xray..."
        systemctl stop xray 2>/dev/null || true
        systemctl disable xray 2>/dev/null || true
    elif [ -f "$XRAY_CONFIG_FILE" ] && command -v python3 &>/dev/null; then
        # Remove gfk-socks inbound from panel's xray config if present
        python3 -c "
import json, sys
try:
    with open(sys.argv[1], 'r') as f:
        cfg = json.load(f)
    orig_len = len(cfg.get('inbounds', []))
    cfg['inbounds'] = [i for i in cfg.get('inbounds', []) if i.get('tag') != 'gfk-socks']
    if len(cfg['inbounds']) < orig_len:
        with open(sys.argv[1], 'w') as f:
            json.dump(cfg, f, indent=2)
except: pass
" "$XRAY_CONFIG_FILE" 2>/dev/null
        systemctl restart xray 2>/dev/null || true
    fi

    # Remove ALL paqctl firewall rules (tagged with "paqctl" comment)
    log_info "Removing firewall rules..."
    _remove_all_paqctl_firewall_rules
    # Also try the port-specific removal for backwards compatibility
    _remove_firewall

    # Remove systemd services
    if command -v systemctl &>/dev/null; then
        systemctl stop paqctl.service 2>/dev/null || true
        systemctl disable paqctl.service 2>/dev/null || true
        systemctl stop paqctl-telegram.service 2>/dev/null || true
        systemctl disable paqctl-telegram.service 2>/dev/null || true
        rm -f /etc/systemd/system/paqctl.service
        rm -f /etc/systemd/system/paqctl-telegram.service
        systemctl daemon-reload 2>/dev/null || true
    fi

    # Remove OpenRC/SysVinit
    rm -f /etc/init.d/paqctl 2>/dev/null

    # Remove symlink
    rm -f /usr/local/bin/paqctl

    # Remove install directory
    rm -rf "${INSTALL_DIR:?}"

    echo ""
    log_success "paqctl has been completely uninstalled"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Help
#═══════════════════════════════════════════════════════════════════════

show_help() {
    echo ""
    echo -e "${BOLD}paqctl${NC} - Paqet Manager v${VERSION}"
    echo ""
    echo -e "${BOLD}Usage:${NC} sudo paqctl <command>"
    echo ""
    echo -e "${BOLD}Commands:${NC}"
    echo "  menu        Interactive menu (default)"
    echo "  status      Show service status and configuration"
    echo ""
    echo -e "${BOLD}Backend Control (individual):${NC}"
    echo "  start-paqet   Start paqet backend only"
    echo "  stop-paqet    Stop paqet backend only"
    echo "  start-gfk     Start GFK backend only"
    echo "  stop-gfk      Stop GFK backend only"
    echo "  start-all     Start both backends"
    echo "  stop-all      Stop both backends"
    echo ""
    echo -e "${BOLD}Legacy (uses active backend):${NC}"
    echo "  start       Start active backend"
    echo "  stop        Stop active backend"
    echo "  restart     Restart active backend"
    echo ""
    echo -e "${BOLD}Other:${NC}"
    echo "  logs        View logs (live)"
    echo "  health      Run health check diagnostics"
    echo "  update      Check for and install updates"
    echo "  config      Change configuration"
    echo "  secret      Generate a new encryption key"
    echo "  firewall    Manage iptables rules"
    echo "  backup      Backup configuration"
    echo "  restore     Restore from backup"
    echo "  telegram    Telegram notification settings"
    echo "  rollback    Roll back to a previous paqet version"
    echo "  ping        Test connectivity (paqet ping)"
    echo "  dump        Capture packets for diagnostics (paqet dump)"
    echo "  uninstall   Remove paqctl completely"
    echo "  version     Show version info"
    echo "  help        Show this help"
    echo ""
    echo -e "${BOLD}Paqet:${NC} https://github.com/SamNet-dev/paqctl"
    echo ""
}

show_version() {
    echo ""
    echo -e "  paqctl version:  ${BOLD}${VERSION}${NC}"
    if [ "$BACKEND" = "gfw-knocker" ]; then
        echo -e "  backend:         ${BOLD}gfw-knocker${NC}"
        local py_ver; py_ver=$(python3 --version 2>/dev/null || echo "unknown")
        echo -e "  python:          ${BOLD}${py_ver}${NC}"
    else
        echo -e "  paqet version:   ${BOLD}${PAQET_VERSION}${NC}"
        local bin_ver
        bin_ver=$("$INSTALL_DIR/bin/paqet" version 2>/dev/null || echo "unknown")
        echo -e "  paqet binary:    ${BOLD}${bin_ver}${NC}"
        if echo "$PAQET_VERSION" | grep -qi "alpha\|beta\|rc"; then
            echo ""
            echo -e "  ${YELLOW}Note: paqet is in alpha phase — expect breaking changes between versions.${NC}"
        fi
    fi
    echo ""
    echo -e "  ${DIM}paqctl by SamNet-dev: https://github.com/SamNet-dev/paqctl${NC}"
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Paqet Diagnostic Tools (ping / dump)
#═══════════════════════════════════════════════════════════════════════

run_ping() {
    echo ""
    if [ "$BACKEND" = "gfw-knocker" ]; then
        log_warn "ping diagnostic is only available for paqet backend"
        return 0
    fi
    if [ ! -x "$INSTALL_DIR/bin/paqet" ]; then
        log_error "paqet binary not found"
        return 1
    fi
    if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
        log_error "config.yaml not found. Run: sudo paqctl config"
        return 1
    fi
    log_info "Running paqet ping (Ctrl+C to stop)..."
    echo ""
    "$INSTALL_DIR/bin/paqet" ping -c "$INSTALL_DIR/config.yaml" 2>&1 || true
    echo ""
}

run_dump() {
    echo ""
    if [ "$BACKEND" = "gfw-knocker" ]; then
        log_warn "dump diagnostic is only available for paqet backend"
        return 0
    fi
    if [ ! -x "$INSTALL_DIR/bin/paqet" ]; then
        log_error "paqet binary not found"
        return 1
    fi
    if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
        log_error "config.yaml not found. Run: sudo paqctl config"
        return 1
    fi
    log_info "Running paqet dump — packet capture diagnostic (Ctrl+C to stop)..."
    echo -e "${DIM}  This shows raw packets being sent and received by paqet.${NC}"
    echo ""
    "$INSTALL_DIR/bin/paqet" dump -c "$INSTALL_DIR/config.yaml" 2>&1 || true
    echo ""
}

#═══════════════════════════════════════════════════════════════════════
# Settings Menu
#═══════════════════════════════════════════════════════════════════════

show_settings_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}  SETTINGS & TOOLS${NC}"
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "  1. Change configuration"
            echo "  2. Manage firewall rules"
            echo "  3. Generate encryption key"
            echo "  4. Backup configuration"
            echo "  5. Restore from backup"
            echo "  6. Health check"
            echo "  7. Telegram notifications"
            echo "  8. Version info"
            echo "  9. Rollback to previous version"
            echo "  p. Ping test (connectivity)"
            echo "  d. Packet dump (diagnostics)"
            echo "  a. Install additional backend"
            echo "  s. Switch backend (current: ${BACKEND})"
            echo "  u. Uninstall"
            echo ""
            echo "  b. Back to main menu"
            echo ""
            redraw=false
        fi

        read -p "  Choice: " s_choice < /dev/tty || break
        case "$s_choice" in
            1) change_config; redraw=true ;;
            2) show_firewall; redraw=true ;;
            3) generate_secret; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; redraw=true ;;
            4) backup_config; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; redraw=true ;;
            5) restore_config; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; redraw=true ;;
            6) health_check; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; redraw=true ;;
            7) show_telegram_menu; redraw=true ;;
            8) show_version; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; redraw=true ;;
            9) rollback_paqet; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; redraw=true ;;
            p|P) run_ping; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; redraw=true ;;
            d|D) run_dump; read -n 1 -s -r -p "  Press any key..." < /dev/tty || true; redraw=true ;;
            a|A) install_additional_backend; redraw=true ;;
            s|S) switch_backend; redraw=true ;;
            u|U) uninstall_paqctl; exit 0 ;;
            b|B) return ;;
            "") ;;
            *) echo -e "  ${RED}Invalid choice${NC}" ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════
# Info Menu
#═══════════════════════════════════════════════════════════════════════

show_info_menu() {
    local redraw=true
    while true; do
        if [ "$redraw" = true ]; then
            clear
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo -e "${BOLD}  INFO & HELP${NC}"
            echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
            echo ""
            echo "  1. How Paqet Works"
            echo "  2. Server vs Client Mode"
            echo "  3. Firewall Rules Explained"
            echo "  4. Troubleshooting"
            echo "  5. About"
            echo ""
            echo "  b. Back"
            echo ""
            redraw=false
        fi

        read -p "  Choice: " i_choice < /dev/tty || break
        case "$i_choice" in
            1)
                clear
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}  HOW PAQET WORKS${NC}"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "  ${BOLD}Overview:${NC}"
                echo "  Paqet is a bidirectional packet-level proxy written in Go."
                echo "  Unlike traditional proxies (Shadowsocks, V2Ray, etc.) that"
                echo "  operate at the application or transport layer, paqet works"
                echo "  at the raw socket level — below the OS network stack."
                echo ""
                echo -e "  ${BOLD}How it works step by step:${NC}"
                echo ""
                echo "  1. PACKET CRAFTING"
                echo "     Paqet uses gopacket + libpcap to craft TCP packets"
                echo "     directly, bypassing the kernel's TCP/IP stack entirely."
                echo "     This means the OS doesn't even know there's a connection."
                echo ""
                echo "  2. KCP ENCRYPTED TRANSPORT"
                echo "     All traffic between client and server is encrypted using"
                echo "     the KCP protocol with AES symmetric key encryption."
                echo "     KCP provides reliable, ordered delivery over raw packets"
                echo "     with built-in error correction and retransmission."
                echo ""
                echo "  3. CONNECTION MULTIPLEXING"
                echo "     Multiple connections are multiplexed over a single KCP"
                echo "     session using smux, reducing overhead and improving"
                echo "     performance for concurrent requests."
                echo ""
                echo "  4. FIREWALL BYPASS"
                echo "     Because it operates below the OS network stack, paqet"
                echo "     bypasses traditional firewalls (ufw, firewalld) and"
                echo "     kernel-level connection tracking (conntrack). The OS"
                echo "     firewall never sees the traffic as a 'connection'."
                echo ""
                echo "  5. SOCKS5 PROXY (Client)"
                echo "     On the client side, paqet exposes a standard SOCKS5"
                echo "     proxy that any application can use. Traffic enters"
                echo "     the SOCKS5 port, gets encrypted and sent via raw"
                echo "     packets to the server, which forwards it to the"
                echo "     destination on the open internet."
                echo ""
                echo -e "  ${DIM}Technical stack: Go, gopacket, libpcap, KCP, smux, AES${NC}"
                echo -e "  ${DIM}Project: https://github.com/SamNet-dev/paqctl${NC}"
                echo ""
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            2)
                clear
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}  SERVER VS CLIENT MODE${NC}"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "  ${GREEN}${BOLD}SERVER MODE${NC}"
                echo -e "  ${DIM}─────────────────────────────────────────────${NC}"
                echo "  The server is the exit node. It receives encrypted raw"
                echo "  packets from clients, decrypts them, and forwards the"
                echo "  traffic to the open internet. Responses are encrypted"
                echo "  and sent back to the client."
                echo ""
                echo "  Requirements:"
                echo "  - A server with a public IP address"
                echo "  - Root access (raw sockets need it)"
                echo "  - libpcap installed"
                echo "  - iptables NOTRACK + RST DROP rules (auto-managed)"
                echo "  - An open port (paqctl manages firewall rules, but you"
                echo "    may need to allow the port in your cloud provider's"
                echo "    security group / network firewall)"
                echo ""
                echo "  After setup, share with your clients:"
                echo "    - Server IP and port (e.g. 1.2.3.4:8443)"
                echo "    - Encryption key (generated during setup)"
                echo ""
                echo -e "  ${CYAN}${BOLD}CLIENT MODE${NC}"
                echo -e "  ${DIM}─────────────────────────────────────────────${NC}"
                echo "  The client connects to a paqet server and provides a"
                echo "  local SOCKS5 proxy. Applications on your machine connect"
                echo "  to the SOCKS5 port, and traffic is tunneled through"
                echo "  paqet's encrypted raw-socket connection to the server."
                echo ""
                echo "  Requirements:"
                echo "  - Server IP:PORT and encryption key from the server admin"
                echo "  - Root access (raw sockets need it)"
                echo "  - libpcap installed"
                echo ""
                echo "  Usage after setup:"
                echo "    Browser:  Set SOCKS5 proxy to 127.0.0.1:1080"
                echo "    curl:     curl --proxy socks5h://127.0.0.1:1080 URL"
                echo "    System:   Configure system proxy to SOCKS5 127.0.0.1:1080"
                echo ""
                echo -e "  ${BOLD}Data flow:${NC}"
                echo "    App -> SOCKS5(:1080) -> paqet client -> raw packets"
                echo "    -> internet -> paqet server -> destination website"
                echo ""
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            3)
                clear
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}  FIREWALL RULES EXPLAINED${NC}"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo "  Paqet requires specific iptables rules on the SERVER."
                echo "  These rules are needed because paqet crafts raw TCP"
                echo "  packets, and without them the kernel interferes."
                echo ""
                echo -e "  ${BOLD}Rule 1: PREROUTING NOTRACK${NC}"
                echo "  iptables -t raw -A PREROUTING -p tcp --dport PORT -j NOTRACK"
                echo ""
                echo "  WHY: Tells the kernel's connection tracker (conntrack) to"
                echo "  ignore incoming packets on the paqet port. Without this,"
                echo "  conntrack tries to match packets to connections it doesn't"
                echo "  know about and may drop them."
                echo ""
                echo -e "  ${BOLD}Rule 2: OUTPUT NOTRACK${NC}"
                echo "  iptables -t raw -A OUTPUT -p tcp --sport PORT -j NOTRACK"
                echo ""
                echo "  WHY: Same as above but for outgoing packets. Prevents"
                echo "  conntrack from tracking paqet's outbound raw packets."
                echo ""
                echo -e "  ${BOLD}Rule 3: RST DROP${NC}"
                echo "  iptables -t mangle -A OUTPUT -p tcp --sport PORT"
                echo "           --tcp-flags RST RST -j DROP"
                echo ""
                echo "  WHY: When the kernel sees incoming TCP SYN packets on a"
                echo "  port with no listening socket, it sends TCP RST (reset)"
                echo "  back. This would kill paqet connections. This rule drops"
                echo "  those RST packets so paqet can handle them instead."
                echo ""
                echo -e "  ${DIM}These rules are auto-managed by paqctl:${NC}"
                echo -e "  ${DIM}  - Applied on service start (ExecStartPre)${NC}"
                echo -e "  ${DIM}  - Removed on service stop (ExecStopPost)${NC}"
                echo -e "  ${DIM}  - Persisted across reboots when possible${NC}"
                echo ""
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            4)
                clear
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}  TROUBLESHOOTING${NC}"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "  ${BOLD}Service won't start:${NC}"
                echo "  1. Check logs:        sudo paqctl logs"
                echo "  2. Run health check:  sudo paqctl health"
                echo "  3. Verify libpcap:    ldconfig -p | grep libpcap"
                echo "  4. Check config:      cat /opt/paqctl/config.yaml"
                echo "  5. Test binary:       sudo /opt/paqctl/bin/paqet version"
                echo ""
                echo -e "  ${BOLD}Client can't connect to server:${NC}"
                echo "  1. Verify server IP and port are correct"
                echo "  2. Check encryption key matches exactly"
                echo "  3. Ensure server iptables rules are active:"
                echo "       sudo paqctl firewall  (on server)"
                echo "  4. Check cloud security group allows the port"
                echo "  5. Test raw connectivity:"
                echo "       sudo /opt/paqctl/bin/paqet ping -c /opt/paqctl/config.yaml"
                echo "  6. Run packet dump to see what's happening:"
                echo "       sudo /opt/paqctl/bin/paqet dump -c /opt/paqctl/config.yaml"
                echo ""
                echo -e "  ${BOLD}SOCKS5 not working (client side):${NC}"
                echo "  1. Verify client is running:  sudo paqctl status"
                echo "  2. Test the proxy directly:"
                echo "       curl -v --proxy socks5h://127.0.0.1:1080 https://httpbin.org/ip"
                echo "  3. Check SOCKS port is listening:"
                echo "       ss -tlnp | grep 1080"
                echo "  4. Check if paqet output shows errors:"
                echo "       sudo paqctl logs"
                echo ""
                echo -e "  ${BOLD}High CPU / Memory:${NC}"
                echo "  1. Check process stats:  sudo paqctl status"
                echo "  2. Restart the service:  sudo paqctl restart"
                echo "  3. Check for latest version: sudo paqctl update"
                echo ""
                echo -e "  ${BOLD}After system reboot:${NC}"
                echo "  1. paqctl auto-starts via systemd (check: systemctl status paqctl)"
                echo "  2. iptables rules are re-applied by ExecStartPre"
                echo "  3. If rules are missing: sudo paqctl firewall -> Apply"
                echo ""
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            5)
                clear
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo -e "${BOLD}  ABOUT${NC}"
                echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
                echo ""
                echo -e "  ${BOLD}paqctl v${VERSION}${NC} - Paqet Management Tool"
                echo ""
                echo -e "  ${CYAN}── Paqet ──${NC}"
                echo ""
                echo -e "  ${BOLD}Creator:${NC}    hanselime"
                echo -e "  ${BOLD}Repository:${NC} https://github.com/SamNet-dev/paqctl"
                echo -e "  ${BOLD}License:${NC}    AGPL-3.0 - Copyright (C) 2026 SamNet Technologies, LLC"
                echo -e "  ${BOLD}Language:${NC}   Go"
                echo -e "  ${BOLD}Contact:${NC}    Signal @hanselime.11"
                echo ""
                echo "  Paqet is a bidirectional packet-level proxy that uses"
                echo "  KCP over raw TCP packets with custom TCP flags."
                echo "  It operates below the OS TCP/IP stack to bypass"
                echo "  firewalls and deep packet inspection."
                echo ""
                echo "  Features:"
                echo "  - Raw TCP packet crafting via gopacket"
                echo "  - KCP + AES symmetric encryption"
                echo "  - SOCKS5 proxy for dynamic connections"
                echo "  - Connection multiplexing via smux"
                echo "  - Cross-platform (Linux, macOS, Windows)"
                echo "  - Android client: github.com/AliRezaBeigy/paqetNG"
                echo ""
                echo -e "  ${CYAN}── paqctl Management Tool ──${NC}"
                echo ""
                echo -e "  ${BOLD}Built by:${NC}   SamNet-dev"
                echo -e "  ${BOLD}Repository:${NC} https://github.com/SamNet-dev/paqctl"
                echo -e "  ${BOLD}License:${NC}    AGPL-3.0 - Copyright (C) 2026 SamNet Technologies, LLC"
                echo ""
                echo "  paqctl provides one-click installation, configuration,"
                echo "  service management, auto-updates, health monitoring,"
                echo "  and Telegram notifications for paqet."
                echo ""
                echo -e "  ${DIM}Original paqet by hanselime, improved by SamNet.${NC}"
                echo ""
                read -n 1 -s -r -p "  Press any key..." < /dev/tty || true
                redraw=true
                ;;
            b|B) return ;;
            "") ;;
            *) echo -e "  ${RED}Invalid choice${NC}" ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════
# Connection Info Display
#═══════════════════════════════════════════════════════════════════════

show_connection_info() {
    clear
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  CLIENT CONNECTION INFO${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    _load_settings

    local local_ip
    local_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

    local paqet_installed=false
    local gfk_installed=false
    [ -f "$INSTALL_DIR/bin/paqet" ] && paqet_installed=true
    if [ "$ROLE" = "server" ]; then
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_server.py" ] && gfk_installed=true
    else
        [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_client.py" ] && gfk_installed=true
    fi

    if [ "$paqet_installed" = true ]; then
        echo -e "  ${GREEN}${BOLD}━━━ PAQET ━━━${NC}"
        echo ""
        local paqet_port="${LISTEN_PORT:-8443}"
        local paqet_key="${ENCRYPTION_KEY:-not set}"
        # Try to get key from config if not in settings
        if [ "$paqet_key" = "not set" ] && [ -f "$INSTALL_DIR/config.yaml" ]; then
            paqet_key=$(grep -E "^key:" "$INSTALL_DIR/config.yaml" 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "not set")
        fi
        echo -e "  ${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${YELLOW}║${NC}  Server:  ${BOLD}${local_ip}:${paqet_port}${NC}"
        echo -e "  ${YELLOW}║${NC}  Key:     ${BOLD}${paqet_key}${NC}"
        echo -e "  ${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${DIM}Client proxy: 127.0.0.1:1080 (SOCKS5)${NC}"
        echo ""
    fi

    if [ "$gfk_installed" = true ]; then
        echo -e "  ${MAGENTA}${BOLD}━━━ GFW-KNOCKER ━━━${NC}"
        echo ""
        local gfk_ip="${GFK_SERVER_IP:-$local_ip}"
        local gfk_auth="${GFK_AUTH_CODE:-not set}"
        local gfk_mappings="${GFK_PORT_MAPPINGS:-14000:443}"
        echo -e "  ${YELLOW}╔═══════════════════════════════════════════════════════════╗${NC}"
        echo -e "  ${YELLOW}║${NC}  Server IP:  ${BOLD}${gfk_ip}${NC}"
        echo -e "  ${YELLOW}║${NC}  Auth Code:  ${BOLD}${gfk_auth}${NC}"
        echo -e "  ${YELLOW}║${NC}  Mappings:   ${BOLD}${gfk_mappings}${NC}"
        echo -e "  ${YELLOW}╚═══════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${DIM}VIO port: ${GFK_VIO_PORT:-45000} | QUIC port: ${GFK_QUIC_PORT:-25000}${NC}"
        local _gfk_proxy_port
        if [ -n "${GFK_SOCKS_VIO_PORT:-}" ]; then
            _gfk_proxy_port="$GFK_SOCKS_VIO_PORT"
        else
            _gfk_proxy_port=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f1)
        fi
        echo -e "  ${DIM}Client proxy: 127.0.0.1:${_gfk_proxy_port} (SOCKS5)${NC}"
        echo ""
    fi

    if [ "$paqet_installed" = false ] && [ "$gfk_installed" = false ]; then
        echo -e "  ${YELLOW}No backends installed yet.${NC}"
        echo ""
        echo "  Run 'sudo paqctl menu' and select 'Settings & Tools'"
        echo "  to install a backend."
        echo ""
    fi

    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
}

#═══════════════════════════════════════════════════════════════════════
# Interactive Menu
#═══════════════════════════════════════════════════════════════════════

show_menu() {
    # Auto-fix systemd service if in failed state
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        local svc_state=$(systemctl is-active paqctl.service 2>/dev/null)
        if [ "$svc_state" = "failed" ]; then
            systemctl reset-failed paqctl.service 2>/dev/null || true
        fi
    fi

    # Reload settings
    _load_settings

    local paqet_installed=false
    local gfk_installed=false
    local redraw=true

    while true; do
        if [ "$redraw" = true ]; then
            # Re-check what's installed each redraw
            paqet_installed=false
            gfk_installed=false
            [ -f "$INSTALL_DIR/bin/paqet" ] && paqet_installed=true
            if [ "$ROLE" = "server" ]; then
                [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_server.py" ] && gfk_installed=true
            else
                [ -d "$GFK_DIR" ] && [ -f "$GFK_DIR/quic_client.py" ] && gfk_installed=true
            fi

            clear
            print_header

            # Status line showing both backends
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo -e "  ${BOLD}BACKEND STATUS${NC}  (Role: ${ROLE})"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"

            # Paqet status
            if [ "$paqet_installed" = true ]; then
                local _paqet_info=""
                if [ "$ROLE" = "server" ]; then
                    _paqet_info="Port: ${LISTEN_PORT:-8443}"
                else
                    _paqet_info="Server: ${REMOTE_SERVER:-N/A}"
                fi
                if is_paqet_running; then
                    echo -e "  Paqet:       ${GREEN}● Running${NC}  |  ${_paqet_info}  |  SOCKS5: 127.0.0.1:${SOCKS_PORT:-1080}"
                else
                    echo -e "  Paqet:       ${RED}○ Stopped${NC}  |  ${_paqet_info}"
                fi
            else
                echo -e "  Paqet:       ${DIM}not installed${NC}"
            fi

            # GFK status
            if [ "$gfk_installed" = true ]; then
                if is_gfk_running; then
                    local _gfk_sv
                    if [ -n "${GFK_SOCKS_VIO_PORT:-}" ]; then
                        _gfk_sv="$GFK_SOCKS_VIO_PORT"
                    else
                        _gfk_sv=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f1)
                    fi
                    echo -e "  GFK:         ${GREEN}● Running${NC}  |  VIO: ${GFK_VIO_PORT:-45000}  |  SOCKS5: 127.0.0.1:${_gfk_sv}"
                else
                    echo -e "  GFK:         ${RED}○ Stopped${NC}  |  VIO: ${GFK_VIO_PORT:-45000}"
                fi
            else
                echo -e "  GFK:         ${DIM}not installed${NC}"
            fi

            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"

            echo ""
            echo -e "  ${CYAN}MAIN MENU${NC}"
            echo ""
            echo "  1. View status"
            echo "  2. View logs"
            echo "  3. Health check"
            echo "  4. Update"
            echo ""

            # Paqet controls
            if [ "$paqet_installed" = true ]; then
                if is_paqet_running; then
                    echo -e "  p. ${RED}Stop${NC} Paqet"
                else
                    echo -e "  p. ${GREEN}Start${NC} Paqet"
                fi
            fi

            # GFK controls
            if [ "$gfk_installed" = true ]; then
                if is_gfk_running; then
                    echo -e "  g. ${RED}Stop${NC} GFK"
                else
                    echo -e "  g. ${GREEN}Start${NC} GFK"
                fi
            fi

            # Start/Stop all
            if [ "$paqet_installed" = true ] && [ "$gfk_installed" = true ]; then
                echo ""
                if is_paqet_running && is_gfk_running; then
                    echo -e "  a. ${RED}Stop ALL${NC} backends"
                elif ! is_paqet_running && ! is_gfk_running; then
                    echo -e "  a. ${GREEN}Start ALL${NC} backends"
                else
                    echo "  a. Toggle ALL backends"
                fi
            fi

            echo ""
            echo "  8. Settings & Tools"
            echo -e "  ${YELLOW}c. Connection Info${NC}"
            echo "  i. Info & Help"
            echo -e "  ${RED}u. Uninstall${NC}"
            echo "  0. Exit"
            echo -e "${CYAN}─────────────────────────────────────────────────────────────────${NC}"
            echo ""
            redraw=false
        fi

        echo -n "  Select option: "
        if ! read choice < /dev/tty 2>/dev/null; then
            log_error "Cannot read input. If piped, run: sudo paqctl menu"
            exit 1
        fi

        case "$choice" in
            1) show_status; read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true; redraw=true ;;
            2) show_logs; redraw=true ;;
            3) health_check; read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true; redraw=true ;;
            4) update_paqet; read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true; redraw=true ;;
            p|P)
                if [ "$paqet_installed" = true ]; then
                    if is_paqet_running; then
                        stop_paqet_backend
                    else
                        start_paqet_backend
                    fi
                    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
                else
                    echo -e "  ${YELLOW}Paqet not installed${NC}"
                fi
                redraw=true
                ;;
            g|G)
                if [ "$gfk_installed" = true ]; then
                    if is_gfk_running; then
                        stop_gfk_backend
                    else
                        start_gfk_backend
                    fi
                    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
                else
                    echo -e "  ${YELLOW}GFK not installed${NC}"
                fi
                redraw=true
                ;;
            a|A)
                if [ "$paqet_installed" = true ] && [ "$gfk_installed" = true ]; then
                    if is_paqet_running && is_gfk_running; then
                        # Stop all
                        stop_paqet_backend
                        stop_gfk_backend
                    elif ! is_paqet_running && ! is_gfk_running; then
                        # Start all
                        start_paqet_backend
                        start_gfk_backend
                    else
                        # Mixed state - ask user
                        echo ""
                        echo "  1. Start all backends"
                        echo "  2. Stop all backends"
                        echo -n "  Choice: "
                        read subchoice < /dev/tty || true
                        case "$subchoice" in
                            1)
                                [ "$paqet_installed" = true ] && ! is_paqet_running && start_paqet_backend
                                [ "$gfk_installed" = true ] && ! is_gfk_running && start_gfk_backend
                                ;;
                            2)
                                is_paqet_running && stop_paqet_backend
                                is_gfk_running && stop_gfk_backend
                                ;;
                        esac
                    fi
                    read -n 1 -s -r -p "  Press any key to return..." < /dev/tty || true
                fi
                redraw=true
                ;;
            8) show_settings_menu; redraw=true ;;
            c|C) show_connection_info; redraw=true ;;
            i|I) show_info_menu; redraw=true ;;
            u|U) uninstall_paqctl; exit 0 ;;
            0) echo "  Exiting."; exit 0 ;;
            "") ;;
            *) echo -e "  ${RED}Invalid choice: ${NC}${YELLOW}$choice${NC}" ;;
        esac
    done
}

#═══════════════════════════════════════════════════════════════════════
# CLI Command Router
#═══════════════════════════════════════════════════════════════════════

case "${1:-menu}" in
    status)           show_status ;;
    start)            start_paqet ;;
    stop)             stop_paqet ;;
    restart)          restart_paqet ;;
    start-paqet)      start_paqet_backend ;;
    stop-paqet)       stop_paqet_backend ;;
    start-gfk)        start_gfk_backend ;;
    stop-gfk)         stop_gfk_backend ;;
    start-all)        start_paqet_backend; start_gfk_backend ;;
    stop-all)         stop_paqet_backend; stop_gfk_backend ;;
    logs)             show_logs ;;
    health)           health_check ;;
    update)           update_paqet ;;
    config)           change_config ;;
    secret)           generate_secret ;;
    firewall)         show_firewall ;;
    rollback)         rollback_paqet ;;
    ping)             run_ping ;;
    dump)             run_dump ;;
    backup)           backup_config ;;
    restore)          restore_config ;;
    telegram)         show_telegram_menu ;;
    uninstall)        uninstall_paqctl ;;
    version)          show_version ;;
    help|--help|-h)   show_help ;;
    menu)             show_menu ;;
    _apply-firewall)  _apply_firewall ;;
    _remove-firewall) _remove_firewall ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo "Run 'sudo paqctl help' for usage."
        exit 1
        ;;
esac
MANAGEMENT

    # Replace placeholder
    sed "s#REPLACE_ME_INSTALL_DIR#$INSTALL_DIR#g" "$tmp_script" > "$tmp_script.sed" && mv "$tmp_script.sed" "$tmp_script"

    if ! chmod +x "$tmp_script"; then
        log_error "Failed to make management script executable"
        rm -f "$tmp_script"
        return 1
    fi
    if ! mv -f "$tmp_script" "$INSTALL_DIR/paqctl"; then
        log_error "Failed to install management script"
        rm -f "$tmp_script"
        return 1
    fi

    # Create symlink
    rm -f /usr/local/bin/paqctl 2>/dev/null
    if ! ln -sf "$INSTALL_DIR/paqctl" /usr/local/bin/paqctl; then
        log_warn "Failed to create symlink /usr/local/bin/paqctl"
    fi

    log_success "Management script installed → /usr/local/bin/paqctl"
}

#═══════════════════════════════════════════════════════════════════════
# Main Installation Flow
#═══════════════════════════════════════════════════════════════════════

_load_settings() {
    [ -f "$INSTALL_DIR/settings.conf" ] || return 0
    # Safe settings loading without eval
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[A-Z_][A-Z_0-9]*$ ]] || continue
        value="${value#\"}"; value="${value%\"}"
        # Skip values with dangerous shell characters
        [[ "$value" =~ [\`\$\(] ]] && continue
        case "$key" in
            BACKEND) BACKEND="$value" ;;
            ROLE) ROLE="$value" ;;
            PAQET_VERSION) PAQET_VERSION="$value" ;;
            PAQCTL_VERSION) PAQCTL_VERSION="$value" ;;
            LISTEN_PORT) [[ "$value" =~ ^[0-9]*$ ]] && LISTEN_PORT="$value" ;;
            SOCKS_PORT) [[ "$value" =~ ^[0-9]*$ ]] && SOCKS_PORT="$value" ;;
            INTERFACE) INTERFACE="$value" ;;
            LOCAL_IP) LOCAL_IP="$value" ;;
            GATEWAY_MAC) GATEWAY_MAC="$value" ;;
            ENCRYPTION_KEY) ENCRYPTION_KEY="$value" ;;
            PAQET_TCP_LOCAL_FLAG) [[ "$value" =~ ^[FSRPAUEC]+(,[FSRPAUEC]+)*$ ]] && PAQET_TCP_LOCAL_FLAG="$value" ;;
            PAQET_TCP_REMOTE_FLAG) [[ "$value" =~ ^[FSRPAUEC]+(,[FSRPAUEC]+)*$ ]] && PAQET_TCP_REMOTE_FLAG="$value" ;;
            REMOTE_SERVER) REMOTE_SERVER="$value" ;;
            GFK_VIO_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_VIO_PORT="$value" ;;
            GFK_VIO_CLIENT_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_VIO_CLIENT_PORT="$value" ;;
            GFK_QUIC_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_QUIC_PORT="$value" ;;
            GFK_QUIC_CLIENT_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_QUIC_CLIENT_PORT="$value" ;;
            GFK_AUTH_CODE) GFK_AUTH_CODE="$value" ;;
            GFK_PORT_MAPPINGS) GFK_PORT_MAPPINGS="$value" ;;
            GFK_SOCKS_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_SOCKS_PORT="$value" ;;
            GFK_SOCKS_VIO_PORT) [[ "$value" =~ ^[0-9]*$ ]] && GFK_SOCKS_VIO_PORT="$value" ;;
            XRAY_PANEL_DETECTED) XRAY_PANEL_DETECTED="$value" ;;
            MICROSOCKS_PORT) [[ "$value" =~ ^[0-9]*$ ]] && MICROSOCKS_PORT="$value" ;;
            GFK_SERVER_IP) GFK_SERVER_IP="$value" ;;
            GFK_TCP_FLAGS) [[ "$value" =~ ^[FSRPAUEC]+$ ]] && GFK_TCP_FLAGS="$value" ;;
            TELEGRAM_BOT_TOKEN) TELEGRAM_BOT_TOKEN="$value" ;;
            TELEGRAM_CHAT_ID) TELEGRAM_CHAT_ID="$value" ;;
            TELEGRAM_INTERVAL) [[ "$value" =~ ^[0-9]+$ ]] && TELEGRAM_INTERVAL="$value" ;;
            TELEGRAM_ENABLED) TELEGRAM_ENABLED="$value" ;;
            TELEGRAM_ALERTS_ENABLED) TELEGRAM_ALERTS_ENABLED="$value" ;;
            TELEGRAM_DAILY_SUMMARY) TELEGRAM_DAILY_SUMMARY="$value" ;;
            TELEGRAM_WEEKLY_SUMMARY) TELEGRAM_WEEKLY_SUMMARY="$value" ;;
            TELEGRAM_SERVER_LABEL) TELEGRAM_SERVER_LABEL="$value" ;;
            TELEGRAM_START_HOUR) [[ "$value" =~ ^[0-9]+$ ]] && TELEGRAM_START_HOUR="$value" ;;
        esac
    done < <(grep '^[A-Z_][A-Z_0-9]*=' "$INSTALL_DIR/settings.conf")
}

# Handle --update-components flag (called during self-update)
if [ "${1:-}" = "--update-components" ]; then
    INSTALL_DIR="${INSTALL_DIR:-/opt/paqctl}"
    _load_settings
    create_management_script
    exit 0
fi

main() {
    check_root
    print_header

    # Check if already installed
    if [ -f "$INSTALL_DIR/settings.conf" ] && { [ -x "$INSTALL_DIR/bin/paqet" ] || [ -f "$GFK_DIR/mainserver.py" ]; }; then
        _load_settings
        log_info "paqctl is already installed (backend: ${BACKEND:-paqet})."
        echo ""
        echo "  1. Reinstall / Reconfigure"
        echo "  2. Open menu  (same as: sudo paqctl menu)"
        echo "  3. Exit"
        echo ""
        read -p "  Choice [1-3]: " choice < /dev/tty || true
        case "$choice" in
            1) log_info "Reinstalling..." ;;
            2) exec /usr/local/bin/paqctl menu ;;
            *) exit 0 ;;
        esac
    fi

    # Step 1: Detect OS
    log_info "Step 1/7: Detecting operating system..."
    detect_os
    echo ""

    # Step 2: Install dependencies
    log_info "Step 2/7: Installing dependencies..."
    check_dependencies
    echo ""

    # Step 3: Configuration wizard (determines backend + role + config)
    log_info "Step 3/7: Configuration..."
    run_config_wizard
    echo ""

    # Step 4: Backend-specific dependencies and download
    log_info "Step 4/7: Setting up ${BACKEND} backend..."
    if [ "$BACKEND" = "gfw-knocker" ]; then
        install_python_deps || { log_error "Failed to install Python dependencies"; exit 1; }
        download_gfk || { log_error "Failed to download GFK"; exit 1; }
        generate_gfk_certs || { log_error "Failed to generate certificates"; exit 1; }
        if [ "$ROLE" = "server" ]; then
            # Install Xray SOCKS5 proxy (adds alongside panel if detected)
            setup_xray_for_gfk || { log_error "Failed to setup Xray"; exit 1; }
            # Regenerate config if mappings changed (panel detected → SOCKS5 added)
            if [ "${XRAY_PANEL_DETECTED:-false}" = "true" ]; then
                generate_gfk_config || { log_error "Failed to regenerate GFK config"; exit 1; }
            fi
        elif [ "$ROLE" = "client" ]; then
            create_gfk_client_wrapper || { log_error "Failed to create client wrapper"; exit 1; }
        fi
        PAQET_VERSION="$GFK_VERSION_PINNED"
        log_info "Using GFK ${PAQET_VERSION} (pinned for stability)"
    else
        # Use pinned version for stability (update command can get latest)
        PAQET_VERSION="$PAQET_VERSION_PINNED"
        log_info "Installing paqet ${PAQET_VERSION} (pinned for stability)"
        download_paqet "$PAQET_VERSION"
    fi
    echo ""

    # Step 5: Apply firewall rules
    log_info "Step 5/7: Firewall setup..."
    if [ "$BACKEND" = "gfw-knocker" ]; then
        if [ "$ROLE" = "server" ]; then
            local _vio_port="${GFK_VIO_PORT:-45000}"
            log_info "Blocking VIO TCP port $_vio_port (raw socket handles it)..."
            if _is_firewalld_active; then
                firewall-cmd --direct --query-rule ipv4 raw PREROUTING 0 -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv4 raw PREROUTING 0 -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
                firewall-cmd --direct --query-rule ipv4 raw OUTPUT 0 -p tcp --sport "$_vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv4 raw OUTPUT 0 -p tcp --sport "$_vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
                firewall-cmd --direct --query-rule ipv4 filter INPUT 0 -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv4 filter INPUT 0 -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    log_warn "Failed to add VIO INPUT DROP rule via firewalld"
                firewall-cmd --direct --query-rule ipv4 filter OUTPUT 0 -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    log_warn "Failed to add VIO RST DROP rule via firewalld"
                firewall-cmd --direct --query-rule ipv6 filter INPUT 0 -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv6 filter INPUT 0 -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
                firewall-cmd --direct --query-rule ipv6 filter OUTPUT 0 -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv6 filter OUTPUT 0 -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
                persist_iptables_rules
            elif command -v iptables &>/dev/null; then
                modprobe iptable_raw 2>/dev/null || true
                iptables -t raw -C PREROUTING -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                    iptables -t raw -A PREROUTING -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
                iptables -t raw -C OUTPUT -p tcp --sport "$_vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                    iptables -t raw -A OUTPUT -p tcp --sport "$_vio_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
                iptables -C INPUT -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    iptables -A INPUT -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    log_warn "Failed to add VIO INPUT DROP rule"
                iptables -C OUTPUT -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    iptables -A OUTPUT -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    log_warn "Failed to add VIO RST DROP rule"
                if command -v ip6tables &>/dev/null; then
                    ip6tables -C INPUT -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                        ip6tables -A INPUT -p tcp --dport "$_vio_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
                    ip6tables -C OUTPUT -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                        ip6tables -A OUTPUT -p tcp --sport "$_vio_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
                fi
            else
                log_warn "iptables not found - firewall rules cannot be applied"
            fi
        else
            local _vio_client_port="${GFK_VIO_CLIENT_PORT:-40000}"
            log_info "Applying NOTRACK + DROP rules for VIO client port $_vio_client_port..."
            if _is_firewalld_active; then
                firewall-cmd --direct --query-rule ipv4 raw PREROUTING 0 -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv4 raw PREROUTING 0 -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
                firewall-cmd --direct --query-rule ipv4 raw OUTPUT 0 -p tcp --sport "$_vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv4 raw OUTPUT 0 -p tcp --sport "$_vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
                firewall-cmd --direct --query-rule ipv4 filter INPUT 0 -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv4 filter INPUT 0 -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    log_warn "Failed to add VIO client INPUT DROP rule via firewalld"
                firewall-cmd --direct --query-rule ipv4 filter OUTPUT 0 -p tcp --sport "$_vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv4 filter OUTPUT 0 -p tcp --sport "$_vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    log_warn "Failed to add VIO client RST DROP rule via firewalld"
                firewall-cmd --direct --query-rule ipv6 filter INPUT 0 -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv6 filter INPUT 0 -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
                firewall-cmd --direct --query-rule ipv6 filter OUTPUT 0 -p tcp --sport "$_vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    firewall-cmd --direct --add-rule ipv6 filter OUTPUT 0 -p tcp --sport "$_vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
                persist_iptables_rules
            elif command -v iptables &>/dev/null; then
                modprobe iptable_raw 2>/dev/null || true
                iptables -t raw -C PREROUTING -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                    iptables -t raw -A PREROUTING -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
                iptables -t raw -C OUTPUT -p tcp --sport "$_vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || \
                    iptables -t raw -A OUTPUT -p tcp --sport "$_vio_client_port" -m comment --comment "paqctl" -j NOTRACK 2>/dev/null || true
                iptables -C INPUT -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    iptables -A INPUT -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    log_warn "Failed to add VIO client INPUT DROP rule"
                iptables -C OUTPUT -p tcp --sport "$_vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    iptables -A OUTPUT -p tcp --sport "$_vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                    log_warn "Failed to add VIO client RST DROP rule"
                if command -v ip6tables &>/dev/null; then
                    ip6tables -C INPUT -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                        ip6tables -A INPUT -p tcp --dport "$_vio_client_port" -m comment --comment "paqctl" -j DROP 2>/dev/null || true
                    ip6tables -C OUTPUT -p tcp --sport "$_vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || \
                        ip6tables -A OUTPUT -p tcp --sport "$_vio_client_port" --tcp-flags RST RST -m comment --comment "paqctl" -j DROP 2>/dev/null || true
                fi
            else
                log_warn "iptables not found - firewall rules cannot be applied"
            fi
        fi
    elif [ "$ROLE" = "server" ]; then
        apply_iptables_rules "$LISTEN_PORT"
    else
        log_info "Client mode - no firewall rules needed"
    fi
    echo ""

    # Step 6: Create service + management script
    log_info "Step 6/7: Setting up service..."
    if ! mkdir -p "$INSTALL_DIR/bin" "$BACKUP_DIR"; then
        log_error "Failed to create installation directories"
        exit 1
    fi
    create_management_script
    setup_service
    setup_logrotate
    # Save settings to persist version and config
    save_settings
    echo ""

    # Step 7: Start the service
    log_info "Step 7/7: Starting ${BACKEND}..."
    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        systemctl start paqctl.service 2>/dev/null
    fi

    sleep 2

    # Final summary
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  INSTALLATION COMPLETE!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  Backend:    ${BOLD}${BACKEND}${NC}"
    echo -e "  Role:       ${BOLD}${ROLE}${NC}"
    echo -e "  Version:    ${BOLD}${PAQET_VERSION}${NC}"

    if [ "$BACKEND" = "gfw-knocker" ]; then
        if [ "$ROLE" = "server" ]; then
            local _xray_port
            _xray_port=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d: -f2 | cut -d, -f1)
            echo -e "  VIO port:   ${BOLD}${GFK_VIO_PORT}${NC}"
            echo -e "  QUIC port:  ${BOLD}${GFK_QUIC_PORT}${NC}"
            if [ "${XRAY_PANEL_DETECTED:-false}" = "true" ]; then
                echo -e "  Xray:       ${BOLD}Existing panel detected (forwarding to port ${_xray_port})${NC}"
                if [ -n "${GFK_SOCKS_VIO_PORT:-}" ]; then
                    echo -e "  SOCKS5:     ${BOLD}127.0.0.1:${GFK_SOCKS_PORT} (auto-added, VIO port ${GFK_SOCKS_VIO_PORT})${NC}"
                    echo ""
                    echo -e "  ${GREEN}✓ GFK forwards to panel + SOCKS5 proxy added${NC}"
                else
                    echo ""
                    echo -e "  ${GREEN}✓ GFK forwards to panel${NC}"
                fi
                local _first_vio
                _first_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d: -f1 | cut -d, -f1)
                echo -e "  ${YELLOW}! Panel users: configure Iran outbound → 127.0.0.1:${_first_vio}${NC}"
                if [ -n "${GFK_SOCKS_VIO_PORT:-}" ]; then
                    echo -e "  ${YELLOW}! Direct SOCKS5: use 127.0.0.1:${GFK_SOCKS_VIO_PORT} on client${NC}"
                fi
            else
                echo -e "  Xray:       ${BOLD}127.0.0.1:${_xray_port} (SOCKS5)${NC}"
                echo ""
                echo -e "  ${GREEN}✓ Xray SOCKS5 proxy installed and running${NC}"
            fi
            echo ""
            echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${YELLOW}║  ${BOLD}CLIENT CONNECTION INFO - SAVE THIS!${NC}${YELLOW}                          ║${NC}"
            echo -e "${YELLOW}╠═══════════════════════════════════════════════════════════════╣${NC}"
            echo -e "${YELLOW}║${NC}  Server IP:  ${BOLD}${GFK_SERVER_IP}${NC}"
            echo -e "${YELLOW}║${NC}  Auth Code:  ${BOLD}${GFK_AUTH_CODE}${NC}"
            echo -e "${YELLOW}║${NC}  Mappings:   ${BOLD}${GFK_PORT_MAPPINGS}${NC}"
            if [ "${XRAY_PANEL_DETECTED:-false}" = "true" ] && [ -n "${GFK_SOCKS_VIO_PORT:-}" ]; then
                echo -e "${YELLOW}║${NC}"
                echo -e "${YELLOW}║${NC}  ${GREEN}Proxy port:  127.0.0.1:${GFK_SOCKS_VIO_PORT} (SOCKS5 — use this on client)${NC}"
                local _panel_vio
                _panel_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f1)
                echo -e "${YELLOW}║${NC}  Panel port: 127.0.0.1:${_panel_vio} (vmess/vless — for panel-to-panel)"
            elif [ "${XRAY_PANEL_DETECTED:-false}" = "true" ]; then
                local _panel_vio
                _panel_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f1)
                echo -e "${YELLOW}║${NC}"
                echo -e "${YELLOW}║${NC}  Panel port: 127.0.0.1:${_panel_vio} (vmess/vless — for panel-to-panel)"
            else
                local _proxy_vio
                _proxy_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f1)
                echo -e "${YELLOW}║${NC}"
                echo -e "${YELLOW}║${NC}  ${GREEN}Proxy port:  127.0.0.1:${_proxy_vio} (SOCKS5 — use this on client)${NC}"
            fi
            echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
        else
            local _socks_vio
            if [ -n "${GFK_SOCKS_VIO_PORT:-}" ]; then
                _socks_vio="$GFK_SOCKS_VIO_PORT"
            else
                _socks_vio=$(echo "${GFK_PORT_MAPPINGS:-14000:443}" | cut -d, -f1 | cut -d: -f1)
            fi
            echo -e "  Server:     ${BOLD}${GFK_SERVER_IP}${NC}"
            echo -e "  SOCKS5:     ${BOLD}127.0.0.1:${_socks_vio}${NC}"
            echo ""
            echo -e "  ${YELLOW}Test your proxy:${NC}"
            echo -e "  ${BOLD}  curl --proxy socks5h://127.0.0.1:${_socks_vio} https://httpbin.org/ip${NC}"
        fi
    elif [ "$ROLE" = "server" ]; then
        echo -e "  Port:       ${BOLD}${LISTEN_PORT}${NC}"
        echo ""
        echo -e "${YELLOW}╔═══════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${YELLOW}║  ${BOLD}CLIENT CONNECTION INFO - SAVE THIS!${NC}${YELLOW}                          ║${NC}"
        echo -e "${YELLOW}╠═══════════════════════════════════════════════════════════════╣${NC}"
        echo -e "${YELLOW}║${NC}  Server:  ${BOLD}${LOCAL_IP}:${LISTEN_PORT}${NC}"
        echo -e "${YELLOW}║${NC}  Key:     ${BOLD}${ENCRYPTION_KEY}${NC}"
        echo -e "${YELLOW}╚═══════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${CYAN}Key also saved in: ${INSTALL_DIR}/config.yaml${NC}"
    else
        echo -e "  Server:     ${BOLD}${REMOTE_SERVER}${NC}"
        echo -e "  SOCKS5:     ${BOLD}127.0.0.1:${SOCKS_PORT}${NC}"
        echo ""
        echo -e "  ${YELLOW}Test your proxy:${NC}"
        echo -e "  ${BOLD}  curl --proxy socks5h://127.0.0.1:${SOCKS_PORT} https://httpbin.org/ip${NC}"
    fi

    echo ""
    echo -e "  ${CYAN}Management commands:${NC}"
    echo "    sudo paqctl menu       Interactive menu"
    echo "    sudo paqctl status     Check status"
    echo "    sudo paqctl health     Health check"
    echo "    sudo paqctl logs       View logs"
    echo "    sudo paqctl update     Update paqet"
    echo "    sudo paqctl help       All commands"
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${BOLD}${YELLOW}⚠ IMPORTANT: Save the connection info above before continuing!${NC}"
    echo ""
    echo -e "  ${CYAN}Press Y to open the management menu, or any other key to exit...${NC}"
    read -n 1 -r choice < /dev/tty || true
    echo ""
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        exec /usr/local/bin/paqctl menu
    else
        echo -e "  ${GREEN}Run 'sudo paqctl menu' when ready.${NC}"
        echo ""
    fi
}

# Handle command line arguments
case "${1:-}" in
    menu)
        check_root
        if [ -f "$INSTALL_DIR/settings.conf" ]; then
            _load_settings
            show_menu
        else
            echo -e "${RED}paqctl is not installed. Run the installer first.${NC}"
            exit 1
        fi
        ;;
    *)
        main "$@"
        ;;
esac
