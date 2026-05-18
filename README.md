# podkop-macs — per-device proxy routing for podkop

Adds MAC-address filtering to [podkop](https://github.com/itdoginfo/podkop) on OpenWrt 24.10.
Choose **which devices** go through the proxy — all others are routed directly.

## Quick install

```sh
sh <(wget -O - https://raw.githubusercontent.com/devizdus/podkop-macs/main/install.sh)
```

Requires podkop already installed. Compatible with podkop >= 0.7.0.

## How it works

1. You maintain a whitelist of MAC addresses (`/etc/podkop-proxy-macs`)
2. On every DHCP event, the sync script compares active leases against the whitelist
3. IPs whose MAC is **not** in the whitelist are added to podkop's `routing_excluded_ips`
4. Podkop routes excluded IPs directly — whitelisted devices go through the proxy

Changes are applied in near real-time (debounced DHCP hook) with a cron fallback every 5 minutes.

## Usage

1. Open **Services → Podkop MACs** in LuCI
2. Copy a MAC from the **Current leases** table
3. Paste into **Allowed MACs**, click **Save**
4. Click **Sync now** — or wait for the next automatic sync

**Empty whitelist = all devices proxied** (podkop default behavior). Safe by default.

## Files

| Path | Purpose |
|---|---|
| `/etc/podkop-proxy-macs` | MAC whitelist (one per line, `#` comments) |
| `/usr/bin/podkop-sync-excluded` | Core sync: leases → excluded IPs |
| `/usr/bin/podkop-sync-trigger` | DHCP hook: debounces and backgrounds sync |

## Limits

- IPv4 only (DHCP leases)
- Requires dnsmasq (odhcpd not supported)
- Relies on MAC addresses — devices with MAC randomization will be excluded

## Uninstall

```sh
sh <(wget -O - https://raw.githubusercontent.com/devizdus/podkop-macs/main/uninstall.sh)
```

Cleans all files, restores podkop to default (all devices proxied).

## License

MIT
