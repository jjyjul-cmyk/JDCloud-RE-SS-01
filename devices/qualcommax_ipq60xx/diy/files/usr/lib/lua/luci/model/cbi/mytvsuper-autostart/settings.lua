-- myTV SUPER 开机自动切台 —— 配置页面
local m, s, o

m = Map("mytvsuper-autostart", translate("myTV SUPER 开机自动切台"),
    translate("监测电视开机状态；电视开机后自动通过 ADB 让机顶盒打开 myTV SUPER 指定频道。"))

s = m:section(NamedSection, "main", "main", translate("基础设置"))
s.addremove = false

o = s:option(Flag, "enabled", translate("启用"),
    translate("关闭后不再检测，但配置保留。"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "tv_ip", translate("电视 IP"),
    translate("用 ping / TCP 判断电视开关机。"))
o.datatype = "ip4addr"
o.default = "192.168.5.148"
o.rmempty = false

o = s:option(Value, "box_ip", translate("机顶盒 IP"),
    translate("运行 myTV SUPER 的设备。"))
o.datatype = "ip4addr"
o.default = "192.168.5.140"
o.rmempty = false

o = s:option(Value, "box_port", translate("机顶盒 ADB 端口"))
o.datatype = "port"
o.default = "5555"
o.rmempty = false

o = s:option(Value, "channel", translate("开机后打开的频道号"))
o.datatype = "uinteger"
o.default = "81"
o.rmempty = false

o = s:option(Value, "interval", translate("检测间隔（秒）"))
o.datatype = "uinteger"
o.default = "10"
o.rmempty = false

o = s:option(Value, "cooldown", translate("重复触发冷却时间（秒）"),
    translate("防止短时间内反复切台。"))
o.datatype = "uinteger"
o.default = "300"
o.rmempty = false

o = s:option(Flag, "startup_trigger", translate("启动时若电视已在线，也立即切台一次"))
o.default = "1"
o.rmempty = false

-- 保存后重启守护进程，使新配置立即生效
function m.on_after_commit(self)
    local sys = require "luci.sys"
    local enabled = self.uci:get("mytvsuper-autostart", "main", "enabled")

    if enabled == "1" then
        sys.call("/etc/init.d/mytvsuper-autostart enable")
        sys.call("/etc/init.d/mytvsuper-autostart restart")
    else
        sys.call("/etc/init.d/mytvsuper-autostart stop")
        sys.call("/etc/init.d/mytvsuper-autostart disable")
    end
end

return m
