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
