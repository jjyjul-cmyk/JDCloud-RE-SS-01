-- myTV SUPER 开机自动切台 —— LuCI 控制器
-- 在「服务」菜单下增加配置入口与状态查看

module("luci.controller.mytvsuper-autostart", package.seeall)

function index()
    if not nixio.fs.access("/etc/config/mytvsuper-autostart") then
        return
    end

    local page = entry({"admin", "services", "mytvsuper-autostart"},
                        cbi("mytvsuper-autostart/settings"),
                        _("myTV SUPER 开机自动切台"), 60)
    page.dependent = true

    entry({"admin", "services", "mytvsuper-autostart", "status"},
          call("action_status")).leaf = true
end

-- 返回服务运行状态与最近日志（供页面 AJAX 调用）
function action_status()
    local fs = require "nixio.fs"
    local sys = require "luci.sys"

    local running = false
    local pidfile = "/var/lib/mytvsuper-autostart/watch.pid"
    if fs.access(pidfile) then
        local pid = (fs.readfile(pidfile) or ""):gsub("%s+", "")
        if pid ~= "" and sys.process.signal(tonumber(pid), 0) then
            running = true
        end
    end

    local log = ""
    local lf = "/var/lib/mytvsuper-autostart/watch.log"
    if fs.access(lf) then
        log = sys.exec("tail -n 40 " .. lf) or ""
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json({
        running = running,
        version = "1.0.0",
        log = log
    })
end
