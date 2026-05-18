#!/bin/sh
# install.sh — install podkop-macs extension for podkop
# Requirements: OpenWRT 24.10, podkop already installed

set -e

REPO="https://github.com/devizdus/podkop-macs"
BRANCH="main"
TMP_DIR="/tmp/podkop-macs-install"

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

echo "2. Installing sync script..."
cp "$SRC_DIR/files/usr/bin/podkop-sync-excluded" /usr/bin/podkop-sync-excluded
chmod +x /usr/bin/podkop-sync-excluded

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

echo "5. Configuring dnsmasq auto-sync..."
if ! grep -q "podkop-sync-excluded" /etc/dnsmasq.conf 2>/dev/null; then
    echo "dhcp-script=/usr/bin/podkop-sync-excluded" >> /etc/dnsmasq.conf
fi

echo "6. Adding cron fallback..."
if ! grep -q "podkop-sync-excluded" /etc/crontabs/root 2>/dev/null; then
    echo "*/5 * * * * /usr/bin/podkop-sync-excluded" >> /etc/crontabs/root
fi

echo "7. Cleaning temp files..."
rm -rf "$TMP_DIR"

echo "8. Restarting services..."
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
/etc/init.d/dnsmasq restart
/etc/init.d/cron restart 2>/dev/null || true

echo "9. Running initial sync..."
/usr/bin/podkop-sync-excluded

echo ""
echo "=== Done ==="
echo "LuCI page: Services → Podkop MACs"
echo "Config file: /etc/podkop-proxy-macs"
