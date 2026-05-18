#!/bin/sh
# install.sh — install podkop-macs extension for podkop
# Requirements: OpenWRT 24.10, podkop already installed

set -e

REPO="https://github.com/devizdus/podkop-macs"
BRANCH="main"
TMP_DIR="/tmp/podkop-macs-install"
SYNC_SCRIPT="/usr/bin/podkop-sync-excluded"
TRIGGER_SCRIPT="/usr/bin/podkop-sync-trigger"
DHCP_SCRIPT_LINE="dhcp-script=/usr/bin/podkop-sync-trigger"

fix_crlf_file() {
    f="$1"
    [ -f "$f" ] || return 0
    tr -d '\r' < "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}

configure_dnsmasq_hook() {
    # Clean old podkop hooks (both direct sync-excluded and trigger) from dnsmasq.conf.
    if [ -f /etc/dnsmasq.conf ]; then
        fix_crlf_file /etc/dnsmasq.conf
        grep -v 'podkop-sync' /etc/dnsmasq.conf > /etc/dnsmasq.conf.tmp
        mv /etc/dnsmasq.conf.tmp /etc/dnsmasq.conf
        # Add debounced trigger (never blocks dnsmasq).
        echo "$DHCP_SCRIPT_LINE" >> /etc/dnsmasq.conf
    fi

    # Remove any stale UCI dhcpscript option (safety: older patches may have set it).
    if uci -q get dhcp.@dnsmasq[0].dhcpscript >/dev/null 2>&1; then
        uci delete dhcp.@dnsmasq[0].dhcpscript
        uci commit dhcp
    fi
}

echo "=== podkop-macs install ==="

# Check podkop
if ! which podkop > /dev/null 2>&1; then
    echo "ERROR: podkop not found. Install podkop first:"
    echo "  sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)"
    exit 1
fi

echo "1. Downloading repository..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
wget -q -O "$TMP_DIR/source.tar.gz" "${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
tar xzf "$TMP_DIR/source.tar.gz" -C "$TMP_DIR"
SRC_DIR="$TMP_DIR/podkop-macs-${BRANCH}"

echo "2. Installing sync scripts..."
cp "$SRC_DIR/files/usr/bin/podkop-sync-excluded" "$SYNC_SCRIPT"
fix_crlf_file "$SYNC_SCRIPT"
chmod +x "$SYNC_SCRIPT"
cp "$SRC_DIR/files/usr/bin/podkop-sync-trigger" "$TRIGGER_SCRIPT"
fix_crlf_file "$TRIGGER_SCRIPT"
chmod +x "$TRIGGER_SCRIPT"

echo "3. Installing default MAC whitelist (empty)..."
if [ ! -f /etc/podkop-proxy-macs ]; then
    cp "$SRC_DIR/files/etc/podkop-proxy-macs" /etc/podkop-proxy-macs
fi

echo "4. Installing LuCI page..."
mkdir -p /usr/lib/lua/luci/controller
cp "$SRC_DIR/luci/controller/podkop-macs.lua" /usr/lib/lua/luci/controller/podkop-macs.lua

mkdir -p /usr/lib/lua/luci/view/podkop_macs
cp "$SRC_DIR/luci/view/podkop_macs.htm" /usr/lib/lua/luci/view/podkop_macs.htm

if [ -f "$SRC_DIR/luci/po/ru/podkop_macs.po" ]; then
    mkdir -p /usr/lib/lua/luci/po/ru
    cp "$SRC_DIR/luci/po/ru/podkop_macs.po" /usr/lib/lua/luci/po/ru/podkop-macs.po
fi

echo "5. Configuring dnsmasq dhcp-script (debounced, non-blocking trigger)..."
configure_dnsmasq_hook

echo "6. Adding cron fallback..."
if ! grep -q "podkop-sync-excluded" /etc/crontabs/root 2>/dev/null; then
    echo "*/5 * * * * /usr/bin/podkop-sync-excluded" >> /etc/crontabs/root
fi
fix_crlf_file /etc/crontabs/root

echo "7. Cleaning temp files..."
rm -rf "$TMP_DIR"

echo "8. Restarting services..."
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
/etc/init.d/dnsmasq restart
/etc/init.d/cron restart 2>/dev/null || true

echo "9. Running initial sync..."
"$SYNC_SCRIPT"

echo ""
echo "=== Done ==="
echo "LuCI page: Services → Podkop MACs"
echo "Config file: /etc/podkop-proxy-macs"
