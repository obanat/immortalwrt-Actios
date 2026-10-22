#!/bin/sh
# /etc/led.sh
#
# LED 状态指示 (rc.local 常驻轮询版, 取代原 hotplug.d/99-wwan-wifi-led 方案)
#
#   每 POLL_INTERVAL(10s) 秒读一次两个网卡的状态:
#     蓝灯 blue:wan   <- wwan0     (4G 上行)     持有公网 IPv6
#     绿灯 green:wlan <- phy0-sta0 (WiFi STA)    已关联 AP 且持有公网 IPv6
#
#   条件满足   -> LED 以 1s 亮 / 1s 灭 闪烁 (kernel timer trigger 1000/1000)
#   条件不满足 -> LED 熄灭
#
# 亮灯条件: 网卡持有 IPV6_PREFIXES 前缀的公网 IPv6 (默认 240e/2408/2409);
#           私网 IPv4、link-local (fe80::)、ULA (fd00::) 均不亮灯。
#
# 开机启动: 在 /etc/rc.local 的 exit 0 之前加一行:
#     /etc/led.sh &
#
# 手动入口:
#   /etc/led.sh &      常驻轮询 (同 rc.local 方式, 单实例, 可重复执行)
#   /etc/led.sh once   立即按当前状态同步一次 LED, 不常驻
#   /etc/led.sh debug  打印两网卡地址/前缀匹配/LED/运行状态 (排障用)
#
# 说明: 状态未变化时不写 sysfs, 不会反复重置闪烁相位;
#       需要 kernel timer trigger (OpenWrt 默认编入 kmod-ledtrig-timer)。

BLUE_LED="blue:wan"
GREEN_LED="green:wlan"

WAN_DEV="wwan0"         # 蓝灯监控的网卡 (4G 上行)
STA_DEV="phy0-sta0"     # 绿灯监控的网卡 (WiFi STA)

IPV6_PREFIXES="240e 2408 2409"   # 认可的公网 IPv6 前缀(空格分隔)

POLL_INTERVAL=10        # 轮询周期(秒)
BLINK_DELAY=1000        # 闪烁半周期 ms: 1000 亮 + 1000 灭 => 亮1s灭1s

LOCK_DIR="/tmp/led.lock"        # 常驻单实例锁(目录)
PID_FILE="$LOCK_DIR/pid"

# 读取 LED 当前生效的 trigger (去掉方括号, 如 [timer] -> timer)
led_trigger() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "/sys/class/leds/$1/trigger" 2>/dev/null
}

led_blink() {            # $1=LED名 $2=半周期ms
	local d="/sys/class/leds/$1"
	[ -d "$d" ] || return 0
	[ "$(led_trigger "$1")" = timer ] || echo timer > "$d/trigger" 2>/dev/null
	[ "$(cat "$d/delay_on" 2>/dev/null)" = "$2" ] || echo "$2" > "$d/delay_on" 2>/dev/null
	[ "$(cat "$d/delay_off" 2>/dev/null)" = "$2" ] || echo "$2" > "$d/delay_off" 2>/dev/null
}

led_off() {
	local d="/sys/class/leds/$1"
	[ -d "$d" ] || return 0
	[ "$(led_trigger "$1")" = none ] || echo none > "$d/trigger" 2>/dev/null
}

# 网卡是否持有指定前缀的公网 IPv6
# (只认 IPV6_PREFIXES 里列出的前缀; link-local / ULA / 其它前缀都不算)
dev_has_public_ipv6() {
	local addrs addr pfx
	addrs=$(ip -6 addr show dev "$1" 2>/dev/null \
		| awk '/inet6/ {print $2}' | cut -d/ -f1 | tr 'A-Z' 'a-z')
	[ -n "$addrs" ] || return 1
	for addr in $addrs; do
		for pfx in $IPV6_PREFIXES; do
			case "$addr" in
				$pfx*) return 0 ;;
			esac
		done
	done
	return 1
}

# WiFi STA 在线 = 已关联 AP 且持有公网 IPv6
# (IPv6 地址断开后可能残留到 valid_lft 到期, 加 iw 关联检测可及时灭灯)
sta_online() {
	dev_has_public_ipv6 "$STA_DEV" || return 1
	if command -v iw >/dev/null 2>&1; then
		iw dev "$STA_DEV" link 2>/dev/null | grep -q '^Connected' || return 1
	fi
	return 0
}

# 按网卡当前实际状态同步两个 LED (幂等: 状态未变不写 sysfs)
sync_all() {
	if dev_has_public_ipv6 "$WAN_DEV"; then
		led_blink "$BLUE_LED" "$BLINK_DELAY"
	else
		led_off "$BLUE_LED"
	fi

	if sta_online; then
		led_blink "$GREEN_LED" "$BLINK_DELAY"
	else
		led_off "$GREEN_LED"
	fi
}

# ---- 手动入口 ----
case "$1" in
	once)
		sync_all
		exit 0
		;;
	debug)
		echo "== 运行状态 =="
		if [ -d "$LOCK_DIR" ]; then
			pid=$(cat "$PID_FILE" 2>/dev/null)
			if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
				echo "   常驻进程: running (pid=$pid)"
			else
				echo "   常驻进程: stopped (残留僵锁 $LOCK_DIR)"
			fi
		else
			echo "   常驻进程: stopped"
		fi
		if command -v iw >/dev/null 2>&1; then
			echo "   iw: 可用"
		else
			echo "   iw: 缺失 -> 绿灯退化为只按 IPv6 判定"
		fi
		echo ""
		echo "== LED =="
		for l in "$BLUE_LED" "$GREEN_LED"; do
			echo "   $l: trigger=$(led_trigger "$l")"
		done
		echo ""
		echo "== WAN_DEV=$WAN_DEV (蓝灯) =="
		ip -6 addr show dev "$WAN_DEV" 2>/dev/null | grep inet6 || echo "   (无 inet6 / 网卡不存在)"
		if dev_has_public_ipv6 "$WAN_DEV"; then echo "   => 蓝灯应闪"; else echo "   => 蓝灯应灭"; fi
		echo ""
		echo "== STA_DEV=$STA_DEV (绿灯) =="
		ip -6 addr show dev "$STA_DEV" 2>/dev/null | grep inet6 || echo "   (无 inet6 / 网卡不存在)"
		if command -v iw >/dev/null 2>&1; then
			iw dev "$STA_DEV" link 2>/dev/null | head -n 1
		fi
		if sta_online; then echo "   => 绿灯应闪"; else echo "   => 绿灯应灭"; fi
		echo ""
		echo "== 全系统 inet6 概览 =="
		ip -6 addr show | awk '/^[0-9]+:/{d=$2} /inet6/{print d, $2}'
		exit 0
		;;
esac

# ---- 常驻模式 (rc.local / 手动 & 方式进入) ----

# 单实例: 已有常驻进程则直接退出; 僵锁(进程已死)自动接管
if [ -d "$LOCK_DIR" ]; then
	oldpid=$(cat "$PID_FILE" 2>/dev/null)
	if [ -n "$oldpid" ] && [ -d "/proc/$oldpid" ]; then
		echo "led.sh already running (pid=$oldpid)" >&2
		exit 0
	fi
	rm -rf "$LOCK_DIR"
fi
mkdir "$LOCK_DIR" 2>/dev/null
echo $$ > "$PID_FILE"
trap 'rm -rf "$LOCK_DIR" 2>/dev/null' EXIT
trap 'exit' INT TERM

while true; do
	sync_all
	sleep "$POLL_INTERVAL"
done
