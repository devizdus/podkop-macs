#!/bin/sh
# install.sh — install podkop-macs extension for podkop
# Requirements: OpenWRT 24.10, podkop already installed

set -e

echo "=== podkop-macs install ==="

# Check podkop
if ! which podkop > /dev/null 2>&1; then
    echo "ERROR: podkop not found. Install podkop first:"
    echo "  sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh)"
    exit 1
fi

echo "1. Installing sync script..."
cp files/usr/bin/podkop-sync-excluded /usr/bin/podkop-sync-excluded
chmod +x /usr/bin/podkop-sync-excluded

echo "2. Installing default MAC whitelist (empty)..."
if [ ! -f /etc/podkop-proxy-macs ]; then
    cp files/etc/podkop-proxy-macs /etc/podkop-proxy-macs
fi

echo "3. Installing LuCI page..."
mkdir -p /usr/lib/lua/luci/controller
mkdir -p /usr/lib/lua/luci/view/podkop_macs
cp luci/controller/podkop-macs.lua /usr/lib/lua/luci/controller/podkop-macs.lua
cp luci/view/podkop_macs.htm /usr/lib/lua/luci/view/podkop_macs.htm

# Translations (optional)
if [ -d luci/po/ru ]; then
    mkdir -p /usr/lib/lua/luci/po/ru
    cp luci/po/ru/podkop_macs.po /usr/lib/lua/luci/po/ru/podkop-macs.po
fi

echo "4. Configuring dnsmasq auto-sync..."
if ! grep -q "podkop-sync-excluded" /etc/dnsmasq.conf 2>/dev/null; then
    echo "dhcp-script=/usr/bin/podkop-sync-excluded" >> /etc/dnsmasq.conf
fi

echo "5. Adding cron fallback..."
if ! grep -q "podkop-sync-excluded" /etc/crontabs/root 2>/dev/null; then
    echo "*/5 * * * * /usr/bin/podkop-sync-excluded" >> /etc/crontabs/root
fi

echo "6. Restarting services..."
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
/etc/init.d/dnsmasq restart
/etc/init.d/cron restart 2>/dev/null || true

echo "7. Running initial sync..."
/usr/bin/podkop-sync-excluded

echo ""
echo "=== Done ==="
echo "LuCI page: Services → Podkop MACs"
echo "Config file: /etc/podkop-proxy-macs"
