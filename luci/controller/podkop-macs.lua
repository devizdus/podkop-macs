module("luci.controller.podkop-macs", package.seeall)

function index()
    entry({"admin", "services", "podkop_macs"},
          template("podkop_macs"),
          _("Podkop MACs"), 80)
    entry({"admin", "services", "podkop_macs", "save"},
          call("action_save"))
    entry({"admin", "services", "podkop_macs", "sync_start"},
          call("action_sync_start"))
    entry({"admin", "services", "podkop_macs", "sync_logs"},
          call("action_sync_logs"))
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

function action_sync_start()
    os.execute("/usr/bin/podkop-sync-excluded &")
    luci.http.prepare_content("application/json")
    luci.http.write('{"status":"started"}')
end

function action_sync_logs()
    local sys = require("luci.sys")
    local logs = sys.exec("logread -e 'podkop-sync' | tail -n 30 2>/dev/null")
    logs = (logs or ""):gsub("%s+$", "")
    if logs == "" then
        logs = "[no podkop-sync entries yet]"
    end

    luci.http.prepare_content("text/plain")
    luci.http.write(logs .. "\n")
end
