#!/bin/sh
# myTV SUPER 开机自动切台 —— 守护进程（OpenWrt / iStoreOS 版）
#
# 工作原理：定时探测电视 IP；检测到电视由「离线」变为「在线」时，
#          等待机顶盒 ADB 就绪后，通过 ADB 打开 myTV SUPER 指定频道。
#          若机顶盒尚未起来（常见：机顶盒随电视断电，启动需 30~90s），
#          会在 BOX_WAIT 秒内持续重试；切台失败则每 RETRY_GAP 秒重试一次。
#
# 兼容性说明：本脚本运行在 busybox ash（OpenWrt 默认 shell）下，
#          不使用 bash 专有特性（无 /dev/tcp、无 [[ ]]、无数组、无 ${var//}）。
set -u

SELF_DIR="$(cd "$(dirname "$0")/.." && pwd)"       # .../mytvsuper-autostart
BASE_DIR="$(cd "$SELF_DIR/.." && pwd)"             # /usr/libexec
VAR_DIR="${VAR_DIR:-/var/lib/mytvsuper-autostart}"
LOG_USE_SYSLOG="${LOG_USE_SYSLOG:-1}"

mkdir -p "$VAR_DIR" 2>/dev/null || true
PIDFILE="$VAR_DIR/watch.pid"
LOGFILE="$VAR_DIR/watch.log"

echo $$ > "$PIDFILE" 2>/dev/null || true

# ---------- 载入配置 ----------
# 优先：uci 配置 /etc/config/mytvsuper-autostart
# 其次：/etc/mytvsuper-autostart.conf（纯 shell 变量，便于手改）
CONF_SH="/etc/mytvsuper-autostart.conf"

cfg_get() {
    # cfg_get <option> —— 从 uci 读，取不到则输出空
    command -v uci >/dev/null 2>&1 || { echo ""; return; }
    v="$(uci -q get "mytvsuper-autostart.main.$1" 2>/dev/null)"
    echo "${v:-}"
}

TV_IP="$(cfg_get tv_ip)"
BOX_IP="$(cfg_get box_ip)"
BOX_PORT="$(cfg_get box_port)"
CHANNEL="$(cfg_get channel)"
INTERVAL="$(cfg_get interval)"
COOLDOWN="$(cfg_get cooldown)"
STARTUP_TRIGGER="$(cfg_get startup_trigger)"

# uci 缺项时回落到 shell 配置文件，再回落到内置默认值
if [ -f "$CONF_SH" ]; then . "$CONF_SH"; fi

TV_IP="${TV_IP:-192.168.5.148}"
BOX_IP="${BOX_IP:-192.168.5.140}"
BOX_PORT="${BOX_PORT:-5555}"
CHANNEL="${CHANNEL:-81}"
PKG="${PKG:-com.tvb.mytvsuper.atv}"
INTERVAL="${INTERVAL:-10}"
COOLDOWN="${COOLDOWN:-300}"
OFF_THRESHOLD="${OFF_THRESHOLD:-3}"
STARTUP_TRIGGER="${STARTUP_TRIGGER:-1}"
# 注意：不要写成 "${URL_TMPL:-...live/{CHANNEL}}" —— 嵌套花括号在部分
# 实现下会被解析成多出一个 "}"，导致 am start 的 URL 错误。用中间变量规避。
URL_DEFAULT='https://www.mytvsuper.com/live/{CHANNEL}'
URL_TMPL="${URL_TMPL:-$URL_DEFAULT}"

# ---------- 频道号 -> myTV SUPER network code 映射 ----------
# 【重要】myTV SUPER 的 deep link 里 /live/ 后面跟的不是频道数字，而是
# 电视网络的字母代码（network code）。若填数字，应用匹配不到任何频道，
# 会回落到默认频道（翡翠台 81）——这正是「填 81/85 都是 81」的原因。
# 这里把常见数字频道号映射成对应代码；也支持直接填字母代码（如 C）。
channel_to_network_code() {
    case "$1" in
        # 数字频道号 -> network code
        80)   echo "TVG"  ;;   # 黃金翡翠台
        81)   echo "J"    ;;   # 翡翠台
        82)   echo "B"    ;;   # TVB Plus
        83)   echo "C"    ;;   # 無綫新聞台
        84)   echo "P"    ;;   # 明珠台
        8101) echo "JUHD" ;;   # 翡翠台 (超高清)
        18)   echo "C18"  ;;   # myTV SUPER 18台
        *)    echo "$1"   ;;   # 其它：原样透传（支持直接填字母代码）
    esac
}
BOX_WAIT="${BOX_WAIT:-120}"        # 电视开机后，等待机顶盒 ADB 就绪的最长时间（秒）
RETRY_GAP="${RETRY_GAP:-30}"       # 切台失败后的重试间隔（秒）
ADB_TIMEOUT="${ADB_TIMEOUT:-10}"   # 单条 adb 命令超时（秒）
TV_PROBE_PORT="${TV_PROBE_PORT:-5555}"  # 用 TCP 探测电视在线时使用的端口
PROBE_TIMEOUT="${PROBE_TIMEOUT:-3}"     # 单次在线探测超时（秒）

# 归一化 switch 值为 1/0
case "$STARTUP_TRIGGER" in
    true|True|TRUE|1|on|On|ON|yes|Yes|YES) STARTUP_TRIGGER=1 ;;
    *) STARTUP_TRIGGER=0 ;;
esac

# ---------- 选择 adb 二进制 ----------
# 选择 adb 的优先级：
#   1) 环境变量 ADB 显式指定（调试/自定义用）
#   2) PATH 中已有的 adb（用户自己装了 OpenWrt 官方 adb 包）
#   3) 本包自带的按架构分发的 adb
ARCH="$(uname -m)"
ADB_DIR="$SELF_DIR/adb"
case "$ARCH" in
    aarch64|arm64)
        # cortex-a53 与 generic 在 libc ABI 上等价，优先 a53
        if [ -x "$ADB_DIR/adb-aarch64-cortex-a53" ]; then
            ADB_BUNDLED="$ADB_DIR/adb-aarch64-cortex-a53"
        else
            ADB_BUNDLED="$ADB_DIR/adb-aarch64-generic"
        fi
        ;;
    x86_64|amd64)
        ADB_BUNDLED="$ADB_DIR/adb-x86_64"
        ;;
    *)
        ADB_BUNDLED="$ADB_DIR/adb-x86_64"
        ;;
esac

if [ -n "${ADB:-}" ] && [ -x "${ADB}" ]; then
    :   # 已由环境变量指定
elif command -v adb >/dev/null 2>&1; then
    ADB="$(command -v adb)"
    [ -x "$ADB" ] || chmod +x "$ADB" 2>/dev/null || true
else
    ADB="$ADB_BUNDLED"
    [ -x "$ADB" ] || chmod +x "$ADB" 2>/dev/null || true
fi

# adb 自检：能跑起来吗？（缺库时立刻暴露，避免盲等 120 秒）
ADB_ERR=""
if [ -x "$ADB" ]; then
    ADB_ERR="$("$ADB" version 2>&1 >/dev/null)"
    case "$ADB_ERR" in
        *"Error loading shared library"*|*"cannot execute"*|*"not found"*)
            # 自带的不行就试试系统 PATH 里的
            if command -v adb >/dev/null 2>&1 && [ "$(command -v adb)" != "$ADB" ]; then
                ADB="$(command -v adb)"
                ADB_ERR="$("$ADB" version 2>&1 >/dev/null)"
            fi
            ;;
    esac
else
    ADB_ERR="找不到可执行的 adb：$ADB"
fi

# ---------- HOME：adb 需要可写目录放 .android ----------
if [ -z "${HOME:-}" ] || [ ! -w "${HOME:-/nonexistent}" ]; then
    mkdir -p "$VAR_DIR/home" 2>/dev/null || true
    export HOME="$VAR_DIR/home"
fi

# ---------- 准备 adb 密钥 ----------
KEYDIR="$SELF_DIR/keys"
if [ -d "$KEYDIR" ]; then
    mkdir -p "$HOME/.android" 2>/dev/null || true
    if [ -f "$KEYDIR/adbkey" ]; then
        cp -f "$KEYDIR/adbkey" "$HOME/.android/adbkey" 2>/dev/null && \
            chmod 600 "$HOME/.android/adbkey" 2>/dev/null || true
        cp -f "$KEYDIR/adbkey.pub" "$HOME/.android/adbkey.pub" 2>/dev/null || true
    fi
fi
export ADB_VENDOR_KEYS="$KEYDIR"

# ---------- 日志 ----------
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
HAVE_LOGGER=0
command -v logger >/dev/null 2>&1 && HAVE_LOGGER=1

log() {
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$line" >> "$LOGFILE" 2>/dev/null || true
    if [ "$LOG_USE_SYSLOG" = "1" ] && [ "$HAVE_LOGGER" = "1" ]; then
        logger -t mytvsuper "$*" 2>/dev/null || true
    fi
}

rotate_log() {
    # 日志超过 3000 行时保留最后 800 行，避免长期运行无限增长
    n="$(wc -l < "$LOGFILE" 2>/dev/null || echo 0)"
    if [ "${n:-0}" -gt 3000 ]; then
        tail -n 800 "$LOGFILE" > "$LOGFILE.tmp" 2>/dev/null && \
            mv -f "$LOGFILE.tmp" "$LOGFILE" 2>/dev/null
    fi
}

# ---------- 在线探测 ----------
# OpenWrt 下 ping 需要 CAP_NET_RAW；init 脚本以 root 运行通常可用，
# 但为了稳妥仍做三级处理：ping 可用则用 ping，否则退回 TCP 探测。
# TCP 判据：端口连上 / 收到 RST（"refused"）= 主机在线；超时 = 离线。
PING_OK=""

can_ping() {
    if [ -z "$PING_OK" ]; then
        if ping -c 1 -W 1 127.0.0.1 >/dev/null 2>&1; then
            PING_OK=1
        else
            PING_OK=0
        fi
    fi
    [ "$PING_OK" = "1" ]
}

# 探测 nc 支持哪些参数（busybox 各版本差异大：-z / -w / -q 不一定都有）
NC_MODE=""
probe_nc_mode() {
    [ -n "$NC_MODE" ] && return 0
    command -v nc >/dev/null 2>&1 || { NC_MODE="none"; return 1; }
    # 用回环地址自测：优先 -z（只看端口是否开放），否则退回 -w
    if nc -z -w 1 127.0.0.1 1 >/dev/null 2>&1; then
        NC_MODE="z"
    elif echo "" | nc -w 1 127.0.0.1 1 >/dev/null 2>&1; then
        NC_MODE="w"
    else
        NC_MODE="plain"
    fi
    return 0
}

# 用 nc 做 TCP 探测
# 判据：端口开放（连上）→ 在线；收到 RST（refused）→ 主机在线；
#       超时 / 不可达 → 离线。
# 返回 0 = 主机在线，1 = 离线
tcp_alive() {
    ip="$1"; port="$2"
    probe_nc_mode || return 1

    case "$NC_MODE" in
        z)
            # busybox nc -z 只做端口探测，最干净
            if nc -z -w "$PROBE_TIMEOUT" "$ip" "$port" >/dev/null 2>&1; then
                return 0
            fi
            ;;
        w|plain)
            ;;
    esac

    # 回退：连上去看是否有响应（含 RST）
    if [ "$NC_MODE" = "plain" ]; then
        out="$( { echo "" | nc "$ip" "$port"; } 2>&1 )"
    else
        out="$( { echo "" | nc -w "$PROBE_TIMEOUT" "$ip" "$port"; } 2>&1 )"
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
    case "$out" in
        *refused*|*reset*|*Connected*|*open*|*succeeded*) return 0 ;;
    esac
    return 1
}

tv_online() {
    if can_ping; then
        ping -c 1 -W 2 "$TV_IP" >/dev/null 2>&1 && return 0
        return 1
    fi
    tcp_alive "$TV_IP" "$TV_PROBE_PORT"
}

adbsh() {
    if [ "$HAVE_TIMEOUT" -eq 1 ]; then
        timeout "$ADB_TIMEOUT" "$ADB" -s "$BOX_IP:$BOX_PORT" shell "$@" 2>&1
    else
        "$ADB" -s "$BOX_IP:$BOX_PORT" shell "$@" 2>&1
    fi
}

# 等待机顶盒 ADB 就绪：轮询 adb connect，最多 BOX_WAIT 秒
# 注意：机顶盒可能不响应 ICMP（ping 不通但 5555 端口是通的），
#       因此这里只以 adb connect 是否成功为判据，不用 ping 做门槛。
wait_box_ready() {
    # adb 本身跑不起来（缺库等）时立即失败，不做无意义的 120 秒轮询
    case "$ADB_ERR" in
        *"Error loading shared library"*|*"cannot execute"*|*"找不到可执行的 adb"*)
            log "  中止：adb 不可用（$ADB_ERR）"
            return 1
            ;;
    esac

    end=$(( $(date +%s) + BOX_WAIT ))
    tried=0

    while [ "$(date +%s)" -lt "$end" ]; do
        tried=$((tried + 1))
        "$ADB" disconnect "$BOX_IP:$BOX_PORT" >/dev/null 2>&1
        if [ "$HAVE_TIMEOUT" -eq 1 ]; then
            c="$(timeout 15 "$ADB" connect "$BOX_IP:$BOX_PORT" 2>&1 | head -1)"
        else
            c="$("$ADB" connect "$BOX_IP:$BOX_PORT" 2>&1 | head -1)"
        fi
        if [ "$tried" -eq 1 ] || [ "${c:-}" != "" ]; then
            log "  adb connect 尝试#${tried} -> ${c:-（无输出）}"
        fi

        case "$c" in
            *unauthorized*)
                # 常见于 adb daemon 未加载到密钥目录：重启 daemon 后重试
                log "  ADB 未授权，重启 adb daemon 后重试"
                "$ADB" kill-server >/dev/null 2>&1
                sleep 1
                ;;
            *connected*|*already*)
                if [ "$(adbsh 'echo ok' 2>/dev/null | tr -d '\r' | tail -1)" = "ok" ]; then
                    log "  机顶盒 ADB 就绪（第 ${tried} 次尝试）"
                    return 0
                fi
                ;;
        esac
        sleep 5
    done

    log "  等待超时：${BOX_WAIT}s 内机顶盒 $BOX_IP:$BOX_PORT 未完成 ADB 连接"
    return 1
}

# 执行一次切台，成功返回 0
fire() {
    # 用 sed 替换占位符（printf 避免 echo 对特殊字符的处理差异）
    url="$(printf '%s' "$URL_TMPL" | sed "s/{CHANNEL}/$(channel_to_network_code "$CHANNEL")/g")"
    log "触发：电视 $TV_IP 已开机 -> 让 $BOX_IP 打开频道 $CHANNEL（network code: $(channel_to_network_code "$CHANNEL")）"

    if ! wait_box_ready; then
        return 1
    fi

    # 冷启动应用，确保 VIEW intent 被正确处理
    adbsh "am force-stop $PKG" >>"$LOGFILE" 2>&1
    sleep 1

    out="$(adbsh "am start -a android.intent.action.VIEW -d '$url' -p $PKG" 2>&1 | head -3)"
    log "am start: $(echo "$out" | tr '\n' ' ')"

    case "$out" in
        *Error*|*error*) log "切台失败（am start 返回错误）"; return 1 ;;
    esac

    log "切台完成"
    return 0
}

# ---------- 主循环 ----------
state="unknown"
off_count=0
last_fire=0
last_try=0
pending=0       # 1 = 已开机但切台尚未成功，需要重试

attempt() {
    last_try="$(date +%s)"
    if fire; then
        last_fire="$last_try"
        pending=0
        return 0
    fi
    pending=1
    return 1
}

# adb daemon 会缓存启动时的密钥环境，这里重置一次，确保带上 ADB_VENDOR_KEYS
"$ADB" kill-server >/dev/null 2>&1

PROBE_MODE="TCP($TV_IP:$TV_PROBE_PORT)"
can_ping && PROBE_MODE="ping"

log "=========================================="
log "守护进程启动 (PID $$)"
log "电视=$TV_IP  机顶盒=$BOX_IP:$BOX_PORT  频道=$CHANNEL"
log "检测间隔=${INTERVAL}s  冷却=${COOLDOWN}s  离线判定=${OFF_THRESHOLD}次"
log "等待机顶盒就绪=${BOX_WAIT}s  失败重试间隔=${RETRY_GAP}s"
log "adb=$ADB  架构=$ARCH  探测方式=$PROBE_MODE"
if [ -n "$ADB_ERR" ]; then
    log "  !!! adb 自检失败：$ADB_ERR"
    log "  !!! 请执行 opkg install libopenssl3 zlib 后重启本服务"
else
    log "  adb 自检通过：$("$ADB" version 2>&1 | head -1)"
fi
log "=========================================="

while true; do
    rotate_log

    if tv_online; then
        off_count=0
        now="$(date +%s)"

        if [ "$state" != "on" ]; then
            prev="$state"
            state="on"
            if [ "$prev" = "unknown" ] && [ "$STARTUP_TRIGGER" != "1" ]; then
                log "首次检测：电视在线（按配置启动时不触发），仅记录状态为 on"
                pending=0
            elif [ $((now - last_fire)) -ge "$COOLDOWN" ]; then
                attempt
            else
                log "电视在线，但处于冷却期内（${COOLDOWN}s），本次跳过"
                pending=0
            fi
        elif [ "$pending" = "1" ] && [ $((now - last_try)) -ge "$RETRY_GAP" ]; then
            log "上次切台未成功，重试（间隔 ${RETRY_GAP}s）"
            attempt
        fi
    else
        off_count=$((off_count + 1))
        if [ "$off_count" -ge "$OFF_THRESHOLD" ] && [ "$state" != "off" ]; then
            log "电视离线（连续 ${off_count} 次无响应）"
            state="off"
            pending=0
        fi
    fi

    sleep "$INTERVAL"
done
