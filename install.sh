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
cat > /usr/bin/podkop-sync-excluded << 'SYNCSCRIPT'
#!/bin/sh
# podkop-sync-excluded — synchronize Routing Excluded IPs in podkop
# based on MAC whitelist and current DHCP leases.

PROXY_MACS_FILE="/etc/podkop-proxy-macs"
LEASES_FILE="/tmp/dhcp.leases"
PODKOP_SECTION="main"

log_msg() {
    logger -t podkop-sync "$1"
}

# Read allowed MACs (skip comments and empty lines, lowercase)
PROXY_MACS=$(grep -v '^#' "$PROXY_MACS_FILE" 2>/dev/null | grep -v '^$' | awk '{print $1}' | tr '[:upper:]' '[:lower:]')

# If whitelist is empty — enable proxy for all devices (clear excluded)
if [ -z "$PROXY_MACS" ]; then
    uci delete podkop.@"$PODKOP_SECTION"[0].routing_excluded_ips 2>/dev/null
    uci commit podkop
    /etc/init.d/podkop reload 2>/dev/null || /usr/bin/podkop reload 2>/dev/null
    log_msg "Proxy enabled for ALL devices (whitelist empty)"
    exit 0
fi

# Collect IPs whose MAC is NOT in whitelist
EXCLUDED_IPS=""
while read -r expiry mac ip hostname rest; do
    [ -z "$ip" ] && continue
    mac_lower=$(echo "$mac" | tr '[:upper:]' '[:lower:]')
    FOUND=0
    for proxy_mac in $PROXY_MACS; do
        if [ "$mac_lower" = "$proxy_mac" ]; then
            FOUND=1
            break
        fi
    done
    if [ "$FOUND" = "0" ]; then
        EXCLUDED_IPS="$EXCLUDED_IPS $ip"
    fi
done < "$LEASES_FILE"

# Update podkop: clear old list, add new
uci delete podkop.@"$PODKOP_SECTION"[0].routing_excluded_ips 2>/dev/null
for ip in $EXCLUDED_IPS; do
    uci add_list podkop.@"$PODKOP_SECTION"[0].routing_excluded_ips="$ip"
done
uci commit podkop

# Apply
/etc/init.d/podkop reload 2>/dev/null || /usr/bin/podkop reload 2>/dev/null

COUNT=$(echo "$EXCLUDED_IPS" | wc -w)
log_msg "Excluded IPs updated: $COUNT devices"
SYNCSCRIPT
chmod +x /usr/bin/podkop-sync-excluded

echo "2. Installing default MAC whitelist (empty)..."
if [ ! -f /etc/podkop-proxy-macs ]; then
    cat > /etc/podkop-proxy-macs << 'CONFIG'
# Podkop MAC whitelist
# Add one MAC address per line. Devices with MACs listed here will use the proxy.
# All other devices are automatically excluded.
# Lines starting with # are comments. Empty lines are ignored.
#
# Example:
# aa:bb:cc:dd:ee:ff  # my-laptop
CONFIG
fi

echo "3. Installing LuCI page..."
mkdir -p /usr/lib/lua/luci/controller
cat > /usr/lib/lua/luci/controller/podkop-macs.lua << 'LUA'
module("luci.controller.podkop-macs", package.seeall)

function index()
    entry({"admin", "services", "podkop_macs"},
          template("podkop_macs"),
          _("Podkop MACs"), 80)
    entry({"admin", "services", "podkop_macs", "save"},
          call("action_save"))
    entry({"admin", "services", "podkop_macs", "sync"},
          call("action_sync"))
end

function action_save()
    local macs = luci.http.formvalue("macs")
    local file = io.open("/etc/podkop-proxy-macs", "w")
    if file then
        file:write(macs)
        file:close()
    end
    luci.http.redirect(luci.dispatcher.build_url("admin/services/podkop_macs"))
end

function action_sync()
    os.execute("/usr/bin/podkop-sync-excluded &")
    luci.http.redirect(luci.dispatcher.build_url("admin/services/podkop_macs"))
end
LUA

mkdir -p /usr/lib/lua/luci/view/podkop_macs
cat > /usr/lib/lua/luci/view/podkop_macs.htm << 'HTM'
<%+header%>

<h2><%:Podkop MAC Filter%></h2>
<p><%:Only devices with MAC addresses listed below will use the proxy. All other devices are automatically excluded.%></p>

<div class="cbi-section" style="background:#f0f7ff;border:1px solid #b8d4f0;padding:12px;border-radius:4px;margin-bottom:12px;">
    <p style="margin:0;">
        <strong>podkop-macs</strong> — <%: extension for podkop that restricts proxy to selected devices by MAC address. %>
        <%: Add the MAC addresses of devices that should use the proxy below. All other devices are automatically excluded.%>
    </p>
    <p style="margin:6px 0 0 0;font-size:13px;color:#666;">
        GitHub: <a href="https://github.com/devizdus/podkop-macs" target="_blank">devizdus/podkop-macs</a>
    </p>
</div>

<hr>

<h3><%:Current leases (for reference)%></h3>
<pre style="background:#f5f5f5;padding:10px;border-radius:4px;max-height:150px;overflow:auto;">
<%
local leases = io.open("/tmp/dhcp.leases")
if leases then
    for line in leases:lines() do
        local expiry, mac, ip, hostname = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
        if mac and ip then
            hostname = hostname or ""
            luci.http.write(string.format("%-18s  %-15s  %s\n", mac, ip, hostname))
        end
    end
    leases:close()
else
    luci.http.write("[no leases file]\n")
end
%>
</pre>

<hr>

<h3><%:Allowed MACs (one per line)%></h3>
<form method="post" action="<%=luci.dispatcher.build_url("admin/services/podkop_macs/save")%>">
    <textarea name="macs" rows="12" style="width:100%;font-family:monospace;font-size:13px;"><%
        local f = io.open("/etc/podkop-proxy-macs")
        if f then
            luci.http.write(f:read("*a"))
            f:close()
        end
    %></textarea>
    <br><br>
    <input type="submit" class="cbi-button cbi-button-save" value="<%:Save%>">
</form>

<br>

<h3><%:Excluded IPs (generated automatically)%></h3>
<pre style="background:#f5f5f5;padding:10px;border-radius:4px;max-height:150px;overflow:auto;">
<%
local uci = require("luci.model.uci").cursor()
local ips = uci:get_list("podkop", "main", "routing_excluded_ips")
if ips then
    for _, ip in ipairs(ips) do
        luci.http.write(ip .. "\n")
    end
else
    luci.http.write("[none — all devices are proxied]\n")
end
%>
</pre>

<br>
<form method="post" action="<%=luci.dispatcher.build_url("admin/services/podkop_macs/sync")%>">
    <input type="submit" class="cbi-button cbi-button-apply" value="<%:Sync now%>">
</form>

<%+footer%>
HTM

# Translations
mkdir -p /usr/lib/lua/luci/po/ru
cat > /usr/lib/lua/luci/po/ru/podkop-macs.po << 'PO'
msgid "Podkop MACs"
msgstr "Podkop — MAC-адреса"

msgid "Podkop MAC Filter"
msgstr "Podkop — фильтр по MAC-адресам"

msgid "Only devices with MAC addresses listed below will use the proxy. All other devices are automatically excluded."
msgstr "Только устройства с MAC-адресами из списка ниже будут использовать прокси. Все остальные исключаются автоматически."

msgid " extension for podkop that restricts proxy to selected devices by MAC address. "
msgstr " — расширение для podkop, ограничивающее проксирование выбранными устройствами по MAC-адресу."

msgid " Add the MAC addresses of devices that should use the proxy below. All other devices are automatically excluded."
msgstr " Добавьте ниже MAC-адреса устройств, которые должны использовать прокси. Все остальные исключаются автоматически."

msgid "Current leases (for reference)"
msgstr "Текущие устройства (для справки)"

msgid "Allowed MACs (one per line)"
msgstr "Разрешённые MAC-адреса (по одному на строку)"

msgid "Excluded IPs (generated automatically)"
msgstr "Исключённые IP (генерируется автоматически)"

msgid "Save"
msgstr "Сохранить"

msgid "Sync now"
msgstr "Синхронизировать сейчас"
PO

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
