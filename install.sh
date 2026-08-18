#!/usr/bin/env bash
# Monero full node + Tor middle/guard relay installer
# Target: Debian 13 (Trixie) amd64
#
# Refs:
#   https://docs.getmonero.org/running-node/monerod-systemd/
#   https://docs.getmonero.org/running-node/monerod-tori2p/
#   https://community.torproject.org/relay/setup/guard/debian-ubuntu/
#   https://support.torproject.org/little-t-tor/getting-started/installing/
#   https://community.torproject.org/relay/setup/guard/debian-ubuntu/updates/

set -euo pipefail

# --- constants ---
MONERO_VERSION="0.18.5.1"
MONERO_ARCHIVE="monero-linux-x64-v${MONERO_VERSION}.tar.bz2"
MONERO_URL="https://downloads.getmonero.org/cli/linux64"
MONERO_SHA256="22a7dda7b0cb699fdd6b7674c3b4a4465b337cc98a54983523b759e1e7cc9958"
MONERO_GPG_KEY_URL="https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc"
MONERO_HASHES_URL="https://www.getmonero.org/downloads/hashes.txt"
DEBIAN_CODENAME="trixie"

# tor bandwidth defaults
TOR_BANDWIDTH_RATE="8 MBytes"
TOR_BANDWIDTH_BURST="10 MBytes"
TOR_ORPORT="9001"

# --- helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
bail() { log_error "$*"; exit 1; }

confirm() {
    local response
    read -rp "$(echo -e "${YELLOW}$1 [y/N]:${NC} ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

# --- preflight ---
preflight() {
    log_info "Pre-flight checks..."
    [[ "$(id -u)" -eq 0 ]] || bail "Must be run as root"

    [[ -f /etc/os-release ]] || bail "/etc/os-release not found"
    source /etc/os-release
    [[ "${ID}" == "debian" ]] || bail "Debian required. Detected: ${ID}"
    log_info "OS: ${PRETTY_NAME}"

    local arch; arch="$(dpkg --print-architecture)"
    [[ "${arch}" == "amd64" ]] || bail "amd64 required. Detected: ${arch}"

    local avail_gb
    avail_gb=$(df -BG --output=avail /var/lib 2>/dev/null | tail -1 | tr -d ' G')
    if [[ "${avail_gb}" -lt 300 ]]; then
        log_warn "${avail_gb} GiB available. Full chain is ~250 GiB and growing."
        confirm "Continue?" || exit 1
    fi

    local ram_mb
    ram_mb=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [[ "${ram_mb}" -lt 3500 ]]; then
        log_warn "${ram_mb} MiB RAM. 4+ GiB recommended."
        confirm "Continue?" || exit 1
    fi

    log_ok "Pre-flight passed"
}

# --- interactive config ---
gather_input() {
    echo ""
    log_info "=== Tor Relay Configuration ==="
    echo ""

    while true; do
        read -rp "Relay nickname (1-19 chars, alphanumeric): " TOR_NICKNAME
        [[ "${TOR_NICKNAME}" =~ ^[a-zA-Z0-9]{1,19}$ ]] && break
        log_warn "Invalid. 1-19 alphanumeric characters."
    done

    while true; do
        read -rp "Contact email (published on relay): " TOR_CONTACT
        [[ -n "${TOR_CONTACT}" ]] && break
        log_warn "Required by Tor Project."
    done

    echo ""
    log_info "Bandwidth: ${TOR_BANDWIDTH_RATE} rate / ${TOR_BANDWIDTH_BURST} burst"
    if confirm "Change?"; then
        read -rp "BandwidthRate (e.g. '5 MBytes'): " TOR_BANDWIDTH_RATE
        read -rp "BandwidthBurst (e.g. '10 MBytes'): " TOR_BANDWIDTH_BURST
    fi

    echo ""
    log_info "ORPort: ${TOR_ORPORT}"
    if confirm "Change?"; then
        read -rp "ORPort: " TOR_ORPORT
    fi

    echo ""
    log_info "Summary:"
    log_info "  Nickname:  ${TOR_NICKNAME}"
    log_info "  Contact:   ${TOR_CONTACT}"
    log_info "  ORPort:    ${TOR_ORPORT}"
    log_info "  Bandwidth: ${TOR_BANDWIDTH_RATE} / ${TOR_BANDWIDTH_BURST}"
    log_info "  Monero:    Full unpruned node, restricted RPC"
    echo ""
    confirm "Proceed?" || exit 0
}

# --- 1. base packages ---
install_base() {
    log_info "=== Step 1: System update & packages ==="
    apt update
    apt upgrade -y
    apt install -y \
        apt-transport-https gnupg curl wget bzip2 \
        unattended-upgrades apt-listchanges \
        ufw net-tools nyx jq htop
    log_ok "Done"
}

# --- 2. automatic updates ---
configure_auto_updates() {
    log_info "=== Step 2: Automatic security updates ==="

    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=TorProject";
};
Unattended-Upgrade::Package-Blacklist {
};
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
EOF

    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::AutocleanInterval "5";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Verbose "1";
EOF

    log_ok "Auto-updates: Debian security + TorProject, reboot at 04:00"
}

# --- 3. install tor ---
install_tor() {
    log_info "=== Step 3: Tor (from torproject.org repo) ==="

    wget -qO- https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc \
        | gpg --dearmor \
        | tee /usr/share/keyrings/deb.torproject.org-keyring.gpg >/dev/null

    cat > /etc/apt/sources.list.d/tor.sources << EOF
Types: deb deb-src
URIs: https://deb.torproject.org/torproject.org/
Suites: ${DEBIAN_CODENAME}
Components: main
Signed-By: /usr/share/keyrings/deb.torproject.org-keyring.gpg
EOF

    apt update
    apt install -y tor deb.torproject.org-keyring
    systemctl stop tor@default || true
    log_ok "Tor installed"
}

# --- 4. configure tor relay ---
configure_tor_relay() {
    log_info "=== Step 4: Tor relay config ==="

    [[ -f /etc/tor/torrc ]] && cp /etc/tor/torrc /etc/tor/torrc.backup.$(date +%s)

    # Relay instance (tor@default) -- relay only, no hidden services
    cat > /etc/tor/torrc << EOF
Nickname    ${TOR_NICKNAME}
ContactInfo ${TOR_CONTACT}

ORPort      ${TOR_ORPORT} IPv4Only
ExitRelay   0
SocksPort   0

BandwidthRate  ${TOR_BANDWIDTH_RATE}
BandwidthBurst ${TOR_BANDWIDTH_BURST}

# nyx
ControlPort 127.0.0.1:9051
CookieAuthentication 1

Log notice syslog
DataDirectory /var/lib/tor
EOF

    # Monero instance (tor@monero) -- hidden service + SOCKS only, no relay
    log_info "Creating tor@monero instance for hidden service..."
    tor-instance-create monero

    cat > /etc/tor/instances/monero/torrc << 'EOF'
SocksPort   127.0.0.1:9050

HiddenServiceDir /var/lib/tor-instances/monero/monerod
HiddenServicePort 18089 127.0.0.1:18089
HiddenServicePort 18084 127.0.0.1:18084

Log notice syslog
EOF

    log_ok "Tor relay: tor@default (ORPort ${TOR_ORPORT})"
    log_ok "Tor hidden service: tor@monero (separate process)"
}

# --- 5. install monero ---
install_monero() {
    log_info "=== Step 5: Monero CLI v${MONERO_VERSION} ==="

    local tmpdir; tmpdir=$(mktemp -d); cd "${tmpdir}"

    log_info "Downloading..."
    wget -q --show-progress -O "${MONERO_ARCHIVE}" "${MONERO_URL}"

    # SHA256 from https://www.getmonero.org/downloads/hashes.txt
    log_info "Verifying SHA256..."
    echo "${MONERO_SHA256}  ${MONERO_ARCHIVE}" | sha256sum -c - \
        || bail "SHA256 mismatch"
    log_ok "SHA256 OK"

    # GPG verify the hashes file
    log_info "GPG verification..."
    wget -q -O hashes.txt "${MONERO_HASHES_URL}"
    wget -q -O binaryfate.asc "${MONERO_GPG_KEY_URL}"
    gpg --import binaryfate.asc 2>/dev/null
    if gpg --verify hashes.txt 2>/dev/null; then
        log_ok "GPG signature valid"
    else
        log_warn "GPG verification failed (key may not be trusted). SHA256 still matched."
        confirm "Continue?" || { rm -rf "${tmpdir}"; exit 1; }
    fi

    # system user + dirs
    id -u monero &>/dev/null || useradd --system --shell /usr/sbin/nologin monero
    mkdir -pm 750 /etc/monero /var/lib/monero /var/log/monero
    chown root:monero /etc/monero
    chown monero:monero /var/lib/monero /var/log/monero

    # install binaries
    tar -xjf "${MONERO_ARCHIVE}"
    local extracted_dir
    extracted_dir=$(find . -maxdepth 1 -type d -name 'monero-x86_64-*' | head -1)
    [[ -n "${extracted_dir}" ]] || bail "Extraction failed"
    cp "${extracted_dir}"/* /usr/local/bin/
    chown root:root /usr/local/bin/monero*
    rm -rf "${tmpdir}"

    log_ok "Monero v${MONERO_VERSION} -> /usr/local/bin/"
}

# --- 6. configure monero ---
configure_monero() {
    log_info "=== Step 6: Monero config ==="

    cat > /etc/monero/monerod.conf << 'EOF'
# /etc/monero/monerod.conf
# Ref: https://docs.getmonero.org/running-node/monerod-systemd/

data-dir=/var/lib/monero/bitmonero

check-updates=disabled
enable-dns-blocklist=1

log-file=/var/log/monero/monero.log
log-level=0
max-log-file-size=2147483648

# P2P on all interfaces (block/tx relay only, no wallet ops)
p2p-bind-ip=0.0.0.0
p2p-bind-port=18080

# Local only RPC
rpc-bind-ip=127.0.0.1
rpc-bind-port=18081

# Restricted RPC on all interfaces (dangerous methods blocked)
# Also reachable via Tor hidden service
rpc-restricted-bind-ip=0.0.0.0
rpc-restricted-bind-port=18089
rpc-ssl=autodetect

no-zmq=1

# Broadcast txs via Tor
tx-proxy=tor,127.0.0.1:9050,12,disable_noise

# Populated automatically after first Tor start
# anonymous-inbound=PLACEHOLDER.onion:18084,127.0.0.1:18084,24

max-txpool-weight=2684354560

out-peers=8
in-peers=32
limit-rate-up=1048576
limit-rate-down=1048576

# Don't ban wallets reconnecting over Tor
disable-rpc-ban=1
EOF

    chown root:monero /etc/monero/monerod.conf
    chmod 640 /etc/monero/monerod.conf
    log_ok "Config -> /etc/monero/monerod.conf"
}

# --- 7. systemd ---
create_systemd_services() {
    log_info "=== Step 7: Systemd services ==="

    cat > /etc/systemd/system/monerod.service << 'EOF'
[Unit]
Description=Monero Daemon
After=network-online.target tor@monero.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/monerod --config-file /etc/monero/monerod.conf --non-interactive
Restart=always
RestartSec=30
User=monero
Group=monero
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log_ok "monerod.service created"
}

# --- 8. start + wire up onion address ---
start_services() {
    log_info "=== Step 8: Starting services ==="

    # start relay
    systemctl enable tor@default
    systemctl start tor@default

    # start monero tor instance
    systemctl enable tor@monero
    systemctl start tor@monero

    # wait for hidden service hostname
    log_info "Waiting for Tor hidden service..."
    local attempts=0
    while [[ ! -f /var/lib/tor-instances/monero/monerod/hostname ]] && [[ ${attempts} -lt 30 ]]; do
        sleep 2
        attempts=$((attempts + 1))
    done

    if [[ -f /var/lib/tor-instances/monero/monerod/hostname ]]; then
        local onion_addr
        onion_addr=$(cat /var/lib/tor-instances/monero/monerod/hostname)
        log_ok "Onion: ${onion_addr}"

        # inject into monerod config
        sed -i "s|^# anonymous-inbound=PLACEHOLDER.*|anonymous-inbound=${onion_addr}:18084,127.0.0.1:18084,24|" \
            /etc/monero/monerod.conf
        grep -q "^anonymous-inbound=${onion_addr}" /etc/monero/monerod.conf \
            || bail "Failed to inject onion address into monerod.conf"
        log_ok "anonymous-inbound set"
    else
        bail "Hidden service hostname not generated after 60s"
    fi

    systemctl enable monerod
    systemctl start monerod
    sleep 3
    if systemctl is-active --quiet monerod; then
        log_ok "monerod running"
    else
        log_error "monerod failed to start"
        log_error "  journalctl -u monerod --no-pager -n 30"
        log_error "  tail -n 30 /var/log/monero/monero.log"
    fi
}

# --- 9. firewall ---
configure_firewall() {
    log_info "=== Step 9: Firewall ==="

    echo ""
    log_info "ufw rules:"
    log_info "  22/tcp    SSH"
    log_info "  ${TOR_ORPORT}/tcp    Tor ORPort"
    log_info "  18080/tcp Monero P2P"
    log_info "  18089/tcp Monero restricted RPC"
    log_info "  default deny incoming, allow outgoing"
    echo ""

    if confirm "Apply ufw rules?"; then
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow 22/tcp comment 'SSH'
        ufw allow "${TOR_ORPORT}/tcp" comment 'Tor ORPort'
        ufw allow 18080/tcp comment 'Monero P2P'
        ufw allow 18089/tcp comment 'Monero Restricted RPC'
        ufw --force enable
        log_ok "ufw enabled"
    fi

    echo ""
    log_warn "Port-forward ${TOR_ORPORT}/tcp on your router or the relay won't work."
}

# --- 10. monitoring script ---
install_monitor_script() {
    log_info "=== Step 10: Monitoring ==="

    cat > /usr/local/bin/node-status << 'SCRIPT'
#!/usr/bin/env bash
# node-status [monero|tor|system|all]

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
divider() { echo -e "${BLUE}$(printf '=%.0s' {1..70})${NC}"; }

check_monero() {
    divider
    echo -e "${CYAN} MONERO${NC}"
    divider

    if ! systemctl is-active --quiet monerod; then
        echo -e "  Service: ${RED}STOPPED${NC}"
        journalctl -u monerod --no-pager -n 5 2>/dev/null
        return
    fi
    echo -e "  Service: ${GREEN}RUNNING${NC}"
    echo -e "  Since:   $(systemctl show monerod --property=ActiveEnterTimestamp --value 2>/dev/null)"

    local info
    info=$(curl -s --max-time 5 -X POST http://127.0.0.1:18081/json_rpc \
        -d '{"jsonrpc":"2.0","id":"0","method":"get_info"}' \
        -H 'Content-Type: application/json' 2>/dev/null)

    if [[ -n "${info}" ]] && command -v jq &>/dev/null; then
        local h th
        h=$(echo "${info}" | jq -r '.result.height // "?"')
        th=$(echo "${info}" | jq -r '.result.target_height // "?"')
        if [[ "${th}" == "0" ]] || [[ "${th}" == "${h}" ]]; then
            echo -e "  Synced:  ${GREEN}YES${NC} (${h})"
        else
            echo -e "  Synced:  ${YELLOW}${h}/${th}${NC}"
        fi
        echo "  Tx pool: $(echo "${info}" | jq -r '.result.tx_pool_size // "?"')"
        echo "  Out/In:  $(echo "${info}" | jq -r '.result.outgoing_connections_count // "?"')/$(echo "${info}" | jq -r '.result.incoming_connections_count // "?"')"
        local db; db=$(echo "${info}" | jq -r '.result.database_size // 0')
        [[ "${db}" -gt 0 ]] && echo "  DB:      $(echo "${db}" | awk '{printf "%.1f GiB", $1/1073741824}')"
    else
        echo -e "  RPC:     ${YELLOW}not responding${NC}"
    fi
    if [[ -f /var/lib/tor-instances/monero/monerod/hostname ]]; then
        local o; o=$(cat /var/lib/tor-instances/monero/monerod/hostname)
        echo "  RPC:     ${o}:18089"
    fi
    echo ""
    echo "  See also: monerod --config-file /etc/monero/monerod.conf status"
    echo "            tail -f /var/log/monero/monero.log"
    echo ""
}

check_tor() {
    divider
    echo -e "${CYAN} TOR RELAY${NC}"
    divider

    if ! systemctl is-active --quiet tor@default; then
        echo -e "  Service: ${RED}STOPPED${NC}"
        journalctl -u tor@default --no-pager -n 5 2>/dev/null
        return
    fi
    echo -e "  Service: ${GREEN}RUNNING${NC}"
    echo -e "  Since:   $(systemctl show tor@default --property=ActiveEnterTimestamp --value 2>/dev/null)"

    [[ -f /var/lib/tor/fingerprint ]] && echo "  FP:      $(cat /var/lib/tor/fingerprint)"

    if sudo journalctl -u tor@default --no-pager 2>/dev/null | grep -q "is reachable from the outside"; then
        echo -e "  ORPort:  ${GREEN}reachable${NC}"
    else
        echo -e "  ORPort:  ${YELLOW}not confirmed (check port forward)${NC}"
    fi
    echo ""
    echo "  See also: sudo nyx"
    echo "            journalctl -fu tor@default"
    echo ""

    divider
    echo -e "${CYAN} MONERO ONION (tor@monero)${NC}"
    divider

    if ! systemctl is-active --quiet tor@monero; then
        echo -e "  Service: ${RED}STOPPED${NC}"
        journalctl -u tor@monero --no-pager -n 5 2>/dev/null
        return
    fi
    echo -e "  Service: ${GREEN}RUNNING${NC}"
    echo -e "  Since:   $(systemctl show tor@monero --property=ActiveEnterTimestamp --value 2>/dev/null)"

    if [[ -f /var/lib/tor-instances/monero/monerod/hostname ]]; then
        local o; o=$(cat /var/lib/tor-instances/monero/monerod/hostname)
        echo "  Onion:   ${o}"
        echo "           :18089 (RPC)  :18084 (P2P)"
    fi
    echo ""
    echo "  See also: journalctl -fu tor@monero"
    echo ""
}

check_system() {
    divider
    echo -e "${CYAN} SYSTEM${NC}"
    divider
    echo "  Host:    $(hostname)"
    echo "  Uptime:  $(uptime -p)"
    echo "  Load:    $(cut -d' ' -f1-3 /proc/loadavg)"
    local mt mu
    mt=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mu=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{print t-a}' /proc/meminfo)
    echo "  Memory:  $((mu*100/mt))% ($(( mu/1024 ))/$(( mt/1024 )) MiB)"
    echo "  Disk:    $(df -h /var/lib | tail -1 | awk '{print $3"/"$2" ("$5")"}')"
    if systemctl is-active --quiet unattended-upgrades; then
        echo -e "  Updates: ${GREEN}auto${NC}"
    else
        echo -e "  Updates: ${YELLOW}inactive${NC}"
    fi
    echo ""
}

case "${1:-all}" in
    monero) check_monero ;;
    tor)    check_tor ;;
    system) check_system ;;
    all)    check_system; check_tor; check_monero ;;
    *)      echo "Usage: node-status [monero|tor|system|all]"; exit 1 ;;
esac
SCRIPT

    chmod +x /usr/local/bin/node-status
    log_ok "node-status installed"
}

# --- 11. summary ---
print_summary() {
    echo ""
    echo -e "${GREEN}======== INSTALL COMPLETE ========${NC}"
    echo ""
    echo "  systemctl status tor@default   # relay"
    echo "  systemctl status tor@monero    # hidden service"
    echo "  systemctl status monerod"
    echo ""
    echo "  node-status              # quick overview"
    echo "  sudo nyx                 # tor live monitor"
    echo "  tail -f /var/log/monero/monero.log"
    echo ""
    echo "  Wallet (clearnet): YOUR_IP:18089"
    if [[ -f /var/lib/tor-instances/monero/monerod/hostname ]]; then
        echo "  Wallet (tor):      $(cat /var/lib/tor-instances/monero/monerod/hostname):18089"
    fi
    echo ""
    echo "  Backups:"
    echo "    /var/lib/tor-instances/monero/monerod/  # onion keys"
    echo "    /var/lib/tor/keys/                     # relay identity"
    echo ""
    echo "  Port-forward ${TOR_ORPORT}/tcp on your router."
    echo "  Relay appears on metrics.torproject.org/rs.html after ~3 hours."
    echo ""
    echo "  Updates: Debian + Tor auto. Monero manual (getmonero.org/downloads/)."
    echo ""
}

# --- main ---
main() {
    echo ""
    log_info "Monero Full Node + Tor Relay Installer (Debian 13 amd64)"
    echo ""
    preflight
    gather_input
    install_base
    configure_auto_updates
    install_tor
    configure_tor_relay
    install_monero
    configure_monero
    create_systemd_services
    start_services
    configure_firewall
    install_monitor_script
    print_summary
}

main "$@"
