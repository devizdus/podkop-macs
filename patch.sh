#!/bin/sh
# patch.sh — repair common runtime issues for podkop-macs on OpenWrt

set -e

REPO="https://github.com/devizdus/podkop-macs"
BRANCH="main"
TMP_DIR="/tmp/podkop-macs-patch"
SYNC_SCRIPT="/usr/bin/podkop-sync-excluded"
HOOK_LINE="dhcp-script=/usr/bin/podkop-sync-excluded"

echo "=== podkop-macs patch ==="

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: required command not found: $1"
        exit 1
    }
}

fix_crlf_file() {
    f="$1"
    [ -f "$f" ] || return 0
    sed -i 's/\r$//' "$f"
}

ensure_sync_script() {
    if [ ! -s "$SYNC_SCRIPT" ]; then
        echo "1. Sync script is missing; downloading and restoring..."
        need_cmd wget
        need_cmd tar
        rm -rf "$TMP_DIR"
        mkdir -p "$TMP_DIR"
        wget -q -O "$TMP_DIR/source.tar.gz" "${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
        tar xzf "$TMP_DIR/source.tar.gz" -C "$TMP_DIR"
        cp "$TMP_DIR/podkop-macs-${BRANCH}/files/usr/bin/podkop-sync-excluded" "$SYNC_SCRIPT"
    else
        echo "1. Sync script exists."
    fi

    chmod +x "$SYNC_SCRIPT"
    fix_crlf_file "$SYNC_SCRIPT"
}

ensure_whitelist_file() {
    echo "2. Ensuring whitelist file exists..."
    if [ ! -f /etc/podkop-proxy-macs ]; then
        cat > /etc/podkop-proxy-macs <<'EOF'
# Podkop MAC whitelist
# Add one MAC address per line. Devices with MACs listed here will use the proxy.
# All other devices are automatically excluded.
EOF
    fi
    fix_crlf_file /etc/podkop-proxy-macs
}

ensure_dnsmasq_hook() {
    echo "3. Repairing dnsmasq hook configuration..."

    if [ -f /etc/dnsmasq.conf ]; then
        fix_crlf_file /etc/dnsmasq.conf
        sed -i '/podkop-sync-excluded/d' /etc/dnsmasq.conf
        echo "$HOOK_LINE" >> /etc/dnsmasq.conf
    fi

    # Prefer UCI-managed dnsmasq option when available.
    if uci -q show dhcp >/dev/null 2>&1; then
        if uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
            uci set dhcp.@dnsmasq[0].dhcpscript="$SYNC_SCRIPT"
            uci commit dhcp
        fi
    fi
}

ensure_cron_fallback() {
    echo "4. Ensuring cron fallback exists..."
    touch /etc/crontabs/root
    fix_crlf_file /etc/crontabs/root
    sed -i '/podkop-sync-excluded/d' /etc/crontabs/root
    echo "*/5 * * * * /usr/bin/podkop-sync-excluded" >> /etc/crontabs/root
}

restart_services() {
    echo "5. Restarting services..."
    rm -f /tmp/luci-indexcache
    /etc/init.d/rpcd restart
    /etc/init.d/dnsmasq restart
    /etc/init.d/cron restart 2>/dev/null || true
}

run_sync_and_check() {
    echo "6. Running sync and printing status..."
    "$SYNC_SCRIPT" || true

    echo "--- UCI excluded IPs ---"
    uci -q show podkop | grep 'routing_excluded_ips' || echo "[none]"

    echo "--- Last podkop-sync logs ---"
    logread -e 'podkop-sync' | tail -n 20 || true
}

cleanup_tmp() {
    rm -rf "$TMP_DIR"
}

need_cmd sed
need_cmd uci

ensure_sync_script
ensure_whitelist_file
ensure_dnsmasq_hook
ensure_cron_fallback
restart_services
run_sync_and_check
cleanup_tmp

echo ""
echo "=== Patch complete ==="
echo "If Excluded IPs are still empty in LuCI, update the LuCI files from this repository and clear /tmp/luci-indexcache."
