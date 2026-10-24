module("luci.controller.anti_ad", package.seeall)

function index()
	if not nixio.fs.access("/usr/bin/anti-ad") then
		return
	end

	entry({"admin", "services", "anti_ad"}, template("anti_ad"), _("anti-AD 广告过滤"), 60).leaf = true
	entry({"admin", "services", "anti_ad", "run"}, post("run_action")).leaf = true
end

-- 保存开关 / 增删时段 / 改时间，然后重建 crontab
function run_action()
	local c = require("luci.model.uci").cursor()
	c:load("anti-ad")

	local action = luci.http.formvalue("action") or "save"

	-- 先收集现有时段（不在 foreach 里改，避免遍历中被修改）
	local names = {}
	c:foreach("anti-ad", "timeslot", function(s)
		names[#names + 1] = s[".name"]
	end)

	-- 1. 保存现有时段的表单值
	for _, n in ipairs(names) do
		local day   = luci.http.formvalue("day_" .. n)
		local start = luci.http.formvalue("start_" .. n)
		local stop  = luci.http.formvalue("stop_" .. n)
		if day and day ~= "" then
			c:set("anti-ad", n, "day", day)
		end
		if start and start ~= "" then
			c:set("anti-ad", n, "start", start)
		end
		if stop and stop ~= "" then
			c:set("anti-ad", n, "stop", stop)
		end
	end

	-- 2. 增 / 删
	if action == "add" then
		local s = c:add("anti-ad", "timeslot")
		c:set("anti-ad", s, "day", "daily")
		c:set("anti-ad", s, "start", "18:30")
		c:set("anti-ad", s, "stop", "19:30")
	elseif action:sub(1, 4) == "del:" then
		local n = action:sub(5)
		if n ~= "" then
			c:delete("anti-ad", n)
		end
	end

	-- 3. 总开关只在「保存」时改，增删时段不碰当前运行状态
	if action == "save" then
		local st = (luci.http.formvalue("enabled") == "1") and "1" or "0"
		c:set("anti-ad", "main", "enabled", st)
		c:commit("anti-ad")
		luci.sys.call("/usr/bin/anti-ad " .. ((st == "1") and "on" or "off") .. " >/dev/null 2>&1")
	else
		c:commit("anti-ad")
	end

	-- 4. 按新时段重建 crontab
	luci.sys.call("/usr/bin/anti-ad-schedule apply >/dev/null 2>&1")

	luci.http.redirect(luci.dispatcher.build_url("admin/services/anti_ad"))
end
