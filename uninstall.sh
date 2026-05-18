#!/bin/sh
# uninstall.sh — full removal of podkop-macs with cleanup of all traces

set -e

echo "=== podkop-macs uninstall ==="

echo "1. Stopping podkop (to clean nftables)..."
/etc/init.d/podkop stop 2>/dev/null || true

echo "2. Cleaning Routing Excluded IPs in podkop config..."
uci delete podkop.@main[0].routing_excluded_ips 2>/dev/null || true
uci commit podkop

echo "3. Removing sync script..."
rm -f /usr/bin/podkop-sync-excluded

echo "4. Removing MAC whitelist..."
rm -f /etc/podkop-proxy-macs

echo "5. Removing LuCI page..."
rm -f /usr/lib/lua/luci/controller/podkop-macs.lua
rm -f /usr/lib/lua/luci/view/podkop_macs.htm

echo "6. Removing translations..."
rm -f /usr/lib/lua/luci/po/ru/podkop-macs.po

echo "7. Removing dnsmasq hook..."
sed -i '/podkop-sync-excluded/d' /etc/dnsmasq.conf

echo "8. Removing cron job..."
sed -i '/podkop-sync-excluded/d' /etc/crontabs/root
/etc/init.d/cron restart 2>/dev/null || true

echo "9. Restarting services..."
rm -f /tmp/luci-indexcache
/etc/init.d/rpcd restart
/etc/init.d/dnsmasq restart

echo "10. Starting podkop..."
/etc/init.d/podkop start 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "podkop-macs completely removed."
echo "Podkop restarted without filtering (all devices proxied)."
