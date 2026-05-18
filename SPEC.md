# SPEC: podkop-macs

> Specification for agent-driven development.
> Each section defines contracts, edge cases, and acceptance criteria.

---

## 1. Purpose

An add-on for [podkop](https://github.com/itdoginfo/podkop) that provides per-device routing: traffic from MAC-whitelisted devices goes through the proxy; all others go directly.

**Core invariant:** an empty whitelist safely degrades to default podkop behavior (all devices proxied).

---

## 2. Components

### 2.1. Configuration: `/etc/podkop-proxy-macs`

**Contract:**
- Plain text file, one MAC address per line
- MAC format: `xx:xx:xx:xx:xx:xx` (lowercase, hex)
- `#` starts a comment to end of line
- Empty lines are ignored
- Lines without a valid MAC in the first field are logged and ignored

**Edge cases:**
- File missing → treated as empty whitelist → all devices proxied
- File exists but all lines commented out → empty whitelist → all devices proxied
- Duplicate MACs → second and subsequent occurrences ignored

**Format:**
```
# Comment
d0:39:57:04:e9:bf  # idyuskin-workbook
de:c1:f8:12:b1:e1  # idyuskin-mac-mini
```

### 2.2. Trigger: `/usr/bin/podkop-sync-trigger`

**Contract:**
- Invoked by dnsmasq via `dhcp-script`
- Must exit in < 10ms (never block dnsmasq)
- Launches `podkop-sync-excluded` in background, at most once per 30 seconds
- Does not log (only the main script logs)

**State:** timestamp file `/tmp/podkop-sync-debounce`

**Flow:**
```
Entry → read timestamp → if < 30s ago → exit 0
      → write now → (podkop-sync-excluded)& → exit 0
```

**Edge cases:**
- Timestamp file missing (first run) → create, fork sync
- Timestamp older than 30s → update, fork sync
- `/tmp` full or unwritable → `exit 0` (safe degradation)
- Dnsmasq passes arguments (DHCP event type, etc.) → trigger ignores them

### 2.3. Sync script: `/usr/bin/podkop-sync-excluded`

**Contract (inputs/outputs):**

| Input | Source |
|---|---|
| Whitelist MACs | `/etc/podkop-proxy-macs` |
| DHCP leases | `/tmp/dhcp.leases` |
| Current excluded IPs | `uci get podkop.settings.routing_excluded_ips` |

| Output | Target |
|---|---|
| New excluded IPs | `uci set podkop.settings.routing_excluded_ips` |
| Log | `logger -t podkop-sync` |

**Flow:**

```
acquire_lock(mkdir /var/lock/podkop-sync.lock)
     │
     ├─ lock held by live process → log "skipped", exit 0
     ├─ lock held by dead process → clear lock, acquire
     └─ lock free → acquire
     
read whitelist → validate MACs → PROXY_MACS
     │
     ├─ RAW_ENTRIES > 0 && PROXY_MACS empty → log "no valid MACs", exit 0
     ├─ PROXY_MACS empty → clear routing_excluded_ips → reload → log "ALL devices", exit 0
     └─ PROXY_MACS non-empty → continue

read dhcp.leases → for each IP: MAC in whitelist? → no → add to EXCLUDED_IPS
     │
     ├─ leases missing → log "missing", exit 0
     └─ list assembled

diff(CURRENT_LIST, NEW_LIST)
     │
     ├─ identical → log "unchanged; skipped reload", exit 0
     └─ differ → uci delete + add_list + commit + reload → log "updated N devices"
```

**Edge cases:**
- `podkop.@settings[0]` does not exist → normal, `uci add_list` creates the option
- `dhcp.leases` empty (no clients) → `EXCLUDED_IPS` empty, `routing_excluded_ips` cleared, reload
- MAC in whitelist but device not in leases (offline) → ignored (no IP to add)
- Multiple devices with same IP (DHCP conflict) → each checked independently, IP may appear multiple times (UCI list allows duplicates, podkop ignores them)

**Atomicity:**
- Lock guarantees single sync instance at a time
- `uci delete` → `uci add_list` → `uci commit` — atomic UCI update
- `podkop reload` — idempotent (repeated reload is safe)

### 2.4. LuCI: page and controller

**Page: Services → Podkop MACs**

| Element | Type | Source |
|---|---|---|
| Current Leases | read-only table | `/tmp/dhcp.leases` |
| Allowed MACs | textarea | `/etc/podkop-proxy-macs` |
| Excluded IPs | read-only pre | `uci get podkop.settings.routing_excluded_ips` |
| Save | button → POST `/save` | |
| Sync now | button → POST `/sync` | |

**UI edge cases:**
- `dhcp.leases` missing → empty table with "no leases" note
- `routing_excluded_ips` missing → "[none — all devices are proxied]"
- Whitelist file unreadable → textarea empty, Save will create new
- Translations missing → fallback to English

### 2.5. Sync triggers

| Mechanism | Frequency | Latency |
|---|---|---|
| DHCP hook (dnsmasq dhcp-script) | per DHCP event, debounced 30s | up to 30s |
| Cron fallback | every 5 minutes | up to 5 min |
| Manual (LuCI Sync now button) | immediately | ~3s (reload time) |

**Priority:** DHCP hook → fastest. Cron → safety net if hook didn't fire. Manual → instant apply.

### 2.6. Install, patch, and uninstall

**install.sh** — idempotent:
- Installs both scripts (sync + trigger) with `fix_crlf` and `chmod +x`
- Creates whitelist file only if missing (never overwrites existing)
- Sets `dhcp-script` in `/etc/dnsmasq.conf` (NOT via UCI)
- Cleans stale UCI `dhcpscript` left by older versions
- Adds cron entry only if absent
- Restarts services: rpcd, dnsmasq, cron
- Runs initial sync

**uninstall.sh** — full cleanup:
- Stops podkop
- Cleans `routing_excluded_ips` from both `settings` and `main` sections (backward compat)
- Removes all files: scripts, whitelist, LuCI page, translations
- Cleans `/etc/dnsmasq.conf` from `podkop-sync` lines
- Cleans UCI `dhcpscript` if present
- Removes cron job
- Starts podkop in default state (all devices proxied)

**patch.sh** — runtime repair:
- Checks/restores scripts from repository
- Checks/creates whitelist file
- Reinstalls dnsmasq hook
- Reinstalls cron
- Restarts services
- Runs sync and prints diagnostics

---

## 3. Data flows

```
┌──────────┐    DHCP event     ┌─────────────────┐    fork     ┌──────────────────────┐
│ dnsmasq  │ ────────────────→ │ podkop-sync-     │ ─────────→ │ podkop-sync-excluded  │
│          │    < 10ms exit    │ trigger           │   async    │                      │
└──────────┘                   └─────────────────┘            │ read whitelist       │
                                                               │ read leases          │
┌──────────┐    */5 cron                                     │ diff old vs new      │
│ cron     │ ──────────────────────────────────────────────→ │ update UCI           │
└──────────┘                                                  │ podkop reload        │
                                                               └──────┬───────────────┘
┌──────────┐    POST /sync                                         │
│ LuCI     │ ──────────────────────────────────────────────────────┘
└──────────┘
```

---

## 4. Acceptance criteria

### AC-1: Basic scenario
- [ ] Whitelist contains 2 MACs, 3 devices on network
- [ ] After sync: 1 IP in `routing_excluded_ips`, 2 absent
- [ ] Excluded device traffic goes direct
- [ ] Whitelisted device traffic goes through proxy

### AC-2: Empty whitelist
- [ ] Whitelist empty or missing
- [ ] After sync: `routing_excluded_ips` cleared or absent
- [ ] All devices go through proxy

### AC-3: Reload only on changes
- [ ] Two consecutive sync calls with unchanged whitelist and leases
- [ ] Second call logs "unchanged; skipped reload" and does NOT reload podkop

### AC-4: DHCP hook debounce
- [ ] Three consecutive DHCP events within 1 second
- [ ] Trigger forks sync only once
- [ ] Dnsmasq is never blocked on any call

### AC-5: Recovery after script deletion
- [ ] Both scripts deleted
- [ ] patch.sh restores both scripts with correct permissions
- [ ] After patch: sync runs without errors

### AC-6: Uninstall
- [ ] uninstall.sh removes all files
- [ ] dnsmasq.conf and crontabs cleaned of podkop-sync
- [ ] UCI dhcpscript removed
- [ ] Podkop running, routing_excluded_ips absent
- [ ] Router functions normally (internet works)

### AC-7: Dnsmasq safety
- [ ] After install, dnsmasq starts without errors
- [ ] DHCP works (clients receive addresses)
- [ ] Trigger does not produce errors in dnsmasq logs
- [ ] No "failed to execute" entries in logs

---

## 5. Error handling

| Situation | Behavior |
|---|---|
| Whitelist file unreadable | All proxied, log "whitelist empty" |
| dhcp.leases missing | Exit unchanged, log "leases missing" |
| Lock held | Exit, log "skipped" |
| Stale lock (process dead) | Clear lock, proceed |
| `uci commit` fails | Error visible in stderr, no log written (env-dependent) |
| `podkop reload` fails | Attempt `/usr/bin/podkop reload` as fallback |
| `/tmp` full | Trigger: `exit 0`. Sync: cannot write debounce → next call will fork again |
| CRLF in scripts | `fix_crlf_file()` at install via `tr -d '\r'` |

---

## 6. Configuration versioning

**Current structure version:** v2 (podkop >= 0.7.0)

| Version | UCI section | Compatibility |
|---|---|---|
| v1 (podkop < 0.7.0) | `podkop.@main[0].routing_excluded_ips` | Deprecated |
| v2 (podkop >= 0.7.0) | `podkop.settings.routing_excluded_ips` | Current |

Uninstall cleans both sections for backward compatibility.

---

## 7. Invariants (must never be violated)

1. **Empty whitelist → all devices proxied** — default safe behavior
2. **Dnsmasq is never blocked** — trigger exits instantly
3. **Podkop is not reloaded unnecessarily** — diff before reload
4. **Install is idempotent** — repeated install.sh does not break config
5. **Uninstall returns system to original state** — uninstall.sh cleans everything
6. **Scripts never crash on missing input files** — all paths handled
