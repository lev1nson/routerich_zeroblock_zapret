#!/bin/sh
#
# ZeroBlock + Zapret2 — автоустановка для OpenWrt / RouteRich
# https://github.com/lev1nson/routerich_zeroblock_zapret
#
# Работает без вопросов. Все переключатели — через переменные окружения,
# см. README.md и блок DEFAULTS ниже.
#
# Запуск:
#   sh install.sh
#

set -u

VERSION="1.0.0"
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SCRIPT_DIR="."
LOG="/tmp/zeroblock-install.log"

# ---------------------------------------------------------------- DEFAULTS --

BACKUP_ROOT="${ZB_BACKUP_DIR:-/root/zeroblock-migration}"
LIST_DIR="/etc/zeroblock/lists"
DESYNC_MARK="0x40000000"
TEMP_DNS="${ZB_TEMP_DNS:-9.9.9.11}"

# xray-core требует ~29.6 МБ на /overlay. Ставим только если места хватает.
XRAY_MIN_FREE_KB=35000
# Минимум свободного места для самой установки ZeroBlock.
MIN_FREE_KB=4500

# Службы старых схем маршрутизации: останавливаем и убираем из автозапуска.
LEGACY_SERVICES="podkop podkop-plus zapret zapret-ng youtubeUnblock ruantiblock"

# Порт dns-failsafe-proxy — штатная точка входа dnsmasq в ZeroBlock.
# Все остальные локальные переопределения в dnsmasq считаются наследием
# старой схемы и удаляются (если ZB_SKIP_DNS_CLEANUP=0).
ZB_DNS_PORT="5359"

# Community-списки по секциям. ZeroBlock сам разрулит пересечения.
CL_AWG10="anime block discord googleplay torrent youtube"
CL_MESSENGERS="messengers meta"
CL_OPERA="video art geoblock games music shop porn socials news repo ai tools"

# Переключатели
ZB_SKIP_BACKUP="${ZB_SKIP_BACKUP:-0}"
ZB_SKIP_LISTS="${ZB_SKIP_LISTS:-0}"
ZB_SKIP_EXCLUDES="${ZB_SKIP_EXCLUDES:-0}"
ZB_SKIP_DNS_CLEANUP="${ZB_SKIP_DNS_CLEANUP:-0}"
ZB_KEEP_CONFIG="${ZB_KEEP_CONFIG:-0}"
ZB_INSTALL_TG="${ZB_INSTALL_TG:-0}"
ZB_REMOVE_PODKOP="${ZB_REMOVE_PODKOP:-0}"
ZB_AUTOCONFIG_WAIT="${ZB_AUTOCONFIG_WAIT:-300}"

# ------------------------------------------------------------------- ВЫВОД --

if [ -t 1 ]; then
	C_OFF="\033[0m"; C_RED="\033[1;31m"; C_GRN="\033[0;32m"
	C_YEL="\033[0;33m"; C_CYN="\033[0;36m"; C_DIM="\033[2m"
else
	C_OFF=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""
fi

WARN_COUNT=0

log()  { printf "%b\n" "$*" | tee -a "$LOG"; }
step() { printf "\n%b\n" "${C_CYN}==> $*${C_OFF}" | tee -a "$LOG"; }
ok()   { printf "%b\n" "  ${C_GRN}✓${C_OFF} $*" | tee -a "$LOG"; }
info() { printf "%b\n" "  ${C_DIM}·${C_OFF} $*" | tee -a "$LOG"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "%b\n" "  ${C_YEL}!${C_OFF} $*" | tee -a "$LOG"; }
die()  { printf "%b\n" "  ${C_RED}✗ $*${C_OFF}" | tee -a "$LOG"; exit 1; }

# uci-обёртки: uci -q delete на отсутствующем ключе возвращает не ноль,
# из-за чего под set -e падал бы весь скрипт.
udel() { uci -q delete "$1" 2>/dev/null || true; }
uget() { uci -q get "$1" 2>/dev/null || true; }

section_exists() { [ -n "$(uget "zeroblock.$1")" ]; }

free_kb() { df -k /overlay 2>/dev/null | awk 'NR==2 {print $4}'; }

# ------------------------------------------------------------------ ШАГ 1 --
# Проверки окружения

preflight() {
	step "Проверка окружения"

	[ "$(id -u)" = "0" ] || die "нужны права root"
	[ -f /etc/openwrt_release ] || die "это не OpenWrt (нет /etc/openwrt_release)"
	command -v opkg >/dev/null 2>&1 || die "opkg не найден"
	command -v uci >/dev/null 2>&1 || die "uci не найден"

	# shellcheck disable=SC1091
	. /etc/openwrt_release
	ARCH="${DISTRIB_ARCH:-unknown}"
	MODEL=$(cat /tmp/sysinfo/model 2>/dev/null || echo "неизвестно")
	info "модель:  $MODEL"
	info "прошивка: ${DISTRIB_DESCRIPTION:-?}"
	info "arch:    $ARCH"

	[ -d "$SCRIPT_DIR/packages" ] || die "не найден каталог packages/ рядом со скриптом"

	ZB_IPK=$(ls "$SCRIPT_DIR"/packages/zeroblock_*_"$ARCH".ipk 2>/dev/null | head -1)
	LUCI_IPK=$(ls "$SCRIPT_DIR"/packages/luci-app-zeroblock_*_all.ipk 2>/dev/null | head -1)
	TG_IPK=$(ls "$SCRIPT_DIR"/packages/zeroblock-tg_*_"$ARCH".ipk 2>/dev/null | head -1)

	if [ -z "$ZB_IPK" ]; then
		log ""
		log "  Вложенные пакеты собраны под другую архитектуру."
		log "  Есть в packages/:"
		ls -1 "$SCRIPT_DIR"/packages/*.ipk 2>/dev/null | sed 's|.*/|    |' | tee -a "$LOG"
		die "нет пакета zeroblock для $ARCH"
	fi
	[ -n "$LUCI_IPK" ] || die "нет пакета luci-app-zeroblock"
	ok "пакеты найдены: $(basename "$ZB_IPK")"

	FREE=$(free_kb)
	[ -n "$FREE" ] || FREE=0
	info "свободно на /overlay: $((FREE / 1024)) МБ"
	[ "$FREE" -ge "$MIN_FREE_KB" ] || die "мало места: нужно минимум $((MIN_FREE_KB / 1024)) МБ на /overlay"

	if ping -c 1 -W 3 "$TEMP_DNS" >/dev/null 2>&1; then
		ok "интернет есть"
	else
		warn "не пингуется $TEMP_DNS — установка зависимостей может не пройти"
	fi
}

# ------------------------------------------------------------------ ШАГ 2 --
# Полный бэкап

do_backup() {
	step "Бэкап текущей конфигурации"

	if [ "$ZB_SKIP_BACKUP" = "1" ]; then
		warn "пропущен (ZB_SKIP_BACKUP=1)"
		return 0
	fi

	BACKUP_DIR="$BACKUP_ROOT/$(date +%Y-%m-%d_%H-%M-%S)"
	mkdir -p "$BACKUP_DIR" || die "не могу создать $BACKUP_DIR"

	sysupgrade -b "$BACKUP_DIR/sysupgrade-config.tar.gz" >>"$LOG" 2>&1
	[ -s "$BACKUP_DIR/sysupgrade-config.tar.gz" ] || die "sysupgrade -b не создал архив"

	if tar -tzf "$BACKUP_DIR/sysupgrade-config.tar.gz" >/dev/null 2>&1; then
		N=$(tar -tzf "$BACKUP_DIR/sysupgrade-config.tar.gz" 2>/dev/null | wc -l)
		ok "sysupgrade-config.tar.gz — $N файлов, архив валиден"
	else
		die "архив бэкапа повреждён"
	fi

	tar czf "$BACKUP_DIR/etc-config.tar.gz" /etc/config /etc/zapret2 /etc/podkop >/dev/null 2>&1 ||
		tar czf "$BACKUP_DIR/etc-config.tar.gz" /etc/config >/dev/null 2>&1
	uci export >"$BACKUP_DIR/uci-export-all.txt" 2>/dev/null
	opkg list-installed >"$BACKUP_DIR/packages-installed.txt" 2>/dev/null
	{
		echo "### model";   cat /tmp/sysinfo/model 2>/dev/null
		echo "### release"; cat /etc/openwrt_release
		echo "### df";      df -h
		echo "### ip addr"; ip -d addr
		echo "### routes";  ip route; ip rule
		echo "### nft";     nft list ruleset 2>/dev/null
	} >"$BACKUP_DIR/system-state.txt" 2>&1

	ok "бэкап: $BACKUP_DIR"
	echo "$BACKUP_DIR" >/tmp/zb_backup_dir
}

# ------------------------------------------------------------------ ШАГ 3 --
# Старые схемы маршрутизации

disable_legacy() {
	step "Старые схемы маршрутизации"

	FOUND=""
	for svc in $LEGACY_SERVICES; do
		[ -f "/etc/init.d/$svc" ] || continue
		FOUND="$FOUND $svc"
		"/etc/init.d/$svc" stop    >/dev/null 2>&1
		"/etc/init.d/$svc" disable >/dev/null 2>&1
		ok "$svc — остановлен и убран из автозапуска"
	done

	# zapret2 глушим отдельно: он нам ещё нужен, но на время установки мешает
	if [ -f /etc/init.d/zapret2 ]; then
		/etc/init.d/zapret2 stop >/dev/null 2>&1
		info "zapret2 временно остановлен, включим в конце"
	fi

	[ -n "$FOUND" ] || info "ничего из старых схем не найдено — чистая система"

	if [ "$ZB_REMOVE_PODKOP" = "1" ] && opkg list-installed 2>/dev/null | grep -q "^podkop "; then
		opkg remove luci-app-podkop podkop >>"$LOG" 2>&1 && ok "podkop удалён" ||
			warn "не удалось удалить podkop, оставлен на месте"
	fi
}

# ------------------------------------------------------------------ ШАГ 4 --
# Временный DNS на время установки

dns_temp_on() {
	step "Временный DNS на время установки"

	cp /etc/config/dhcp /tmp/zb_dhcp.bak 2>/dev/null && ok "конфиг dnsmasq сохранён"
	# отдельная копия в бэкап — её использует uninstall.sh в мягком режиме
	[ -n "${BACKUP_DIR:-}" ] && cp /etc/config/dhcp "$BACKUP_DIR/dhcp.bak" 2>/dev/null

	udel dhcp.@dnsmasq[0].server
	uci set dhcp.@dnsmasq[0].noresolv='1'
	uci add_list dhcp.@dnsmasq[0].server="$TEMP_DNS"
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	sleep 2
	ok "DNS переключён на $TEMP_DNS"
}

dns_temp_off() {
	step "Возврат DNS"

	if [ ! -f /tmp/zb_dhcp.bak ]; then
		warn "нет сохранённого конфига dnsmasq, пропускаю"
		return 0
	fi

	cp /tmp/zb_dhcp.bak /etc/config/dhcp
	rm -f /tmp/zb_dhcp.bak

	if [ "$ZB_SKIP_DNS_CLEANUP" = "1" ]; then
		info "чистка переопределений пропущена (ZB_SKIP_DNS_CLEANUP=1)"
	else
		# Убираем доменные переопределения вида /*.example.com/127.0.0.1#PORT,
		# уводящие резолв мимо ZeroBlock. Точку входа ZeroBlock не трогаем.
		OLD=$(uget dhcp.@dnsmasq[0].server)
		KEEP=""; DROPPED=0
		for s in $OLD; do
			case "$s" in
				/*/127.0.0.1\#*)
					case "$s" in
						*"#$ZB_DNS_PORT") KEEP="$KEEP $s" ;;
						*) DROPPED=$((DROPPED + 1)) ;;
					esac
					;;
				*) KEEP="$KEEP $s" ;;
			esac
		done
		if [ "$DROPPED" -gt 0 ]; then
			udel dhcp.@dnsmasq[0].server
			for s in $KEEP; do uci add_list dhcp.@dnsmasq[0].server="$s"; done
			ok "убрано $DROPPED доменных переопределений от старой схемы"
		else
			info "лишних переопределений не найдено"
		fi
	fi

	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	sleep 2
	ok "DNS восстановлен: $(uget dhcp.@dnsmasq[0].server)"
}

# ------------------------------------------------------------------ ШАГ 5 --
# Установка пакетов

opkg_update() {
	i=1
	while [ "$i" -le 4 ]; do
		if opkg update >/tmp/opkg_update.log 2>&1 &&
			! grep -qiE "failed|error|unable|not found|refused|timeout" /tmp/opkg_update.log; then
			ok "репозитории обновлены (попытка $i)"
			return 0
		fi
		info "попытка $i/4 не удалась"
		i=$((i + 1))
		sleep 3
	done
	warn "opkg update не прошёл — зависимости могут не установиться"
	return 1
}

install_packages() {
	step "Установка ZeroBlock"

	opkg_update

	INSTALLED_VER=$(opkg list-installed 2>/dev/null | awk '/^zeroblock /{print $3}')
	[ -n "$INSTALLED_VER" ] && info "уже установлен zeroblock $INSTALLED_VER, переустанавливаю"

	if opkg install "$ZB_IPK" >>"$LOG" 2>&1; then
		ok "zeroblock: $(basename "$ZB_IPK")"
	else
		tail -20 "$LOG"
		die "не удалось установить zeroblock (подробности в $LOG)"
	fi

	opkg install "$LUCI_IPK" >>"$LOG" 2>&1 &&
		ok "luci-app-zeroblock: $(basename "$LUCI_IPK")" ||
		warn "luci-app-zeroblock не установился, веб-интерфейса не будет"

	if [ "$ZB_INSTALL_TG" = "1" ] && [ -n "$TG_IPK" ]; then
		opkg install "$TG_IPK" >>"$LOG" 2>&1 &&
			ok "zeroblock-tg (уведомления в Telegram)" ||
			warn "zeroblock-tg не установился"
	fi

	opkg list-installed 2>/dev/null | grep -q "^zeroblock " || die "zeroblock не появился в списке установленных"
}

# ------------------------------------------------------------------ ШАГ 6 --
# Базовый конфиг

write_config() {
	step "Базовый конфиг ZeroBlock"

	if [ "$ZB_KEEP_CONFIG" = "1" ] && [ -f /etc/config/zeroblock ]; then
		info "существующий конфиг сохранён (ZB_KEEP_CONFIG=1)"
		return 0
	fi

	/etc/init.d/zeroblock stop >/dev/null 2>&1
	[ -f /etc/config/zeroblock ] && [ -n "${BACKUP_DIR:-}" ] &&
		cp /etc/config/zeroblock "$BACKUP_DIR/zeroblock.cfg.bak" 2>/dev/null

	# чистим следы прошлых установок, но списки не трогаем
	find /etc/zeroblock -maxdepth 1 -type f -exec rm -f {} + 2>/dev/null
	rm -f /etc/config/zeroblock

	# xray-core занимает ~29.6 МБ. На большинстве роутеров он не влезает,
	# и демон будет пытаться его ставить при каждом reload.
	FREE=$(free_kb); [ -n "$FREE" ] || FREE=0
	if [ "$FREE" -ge "$XRAY_MIN_FREE_KB" ]; then
		XRAY_FLAG=1
		info "места хватает, xray-core разрешён"
	else
		XRAY_FLAG=0
		info "xray-core отключён: нужно $((XRAY_MIN_FREE_KB / 1024)) МБ, свободно $((FREE / 1024)) МБ"
	fi

	cat >/etc/config/zeroblock <<EOF

config settings 'settings'
	option log_level 'warn'
	option show_trace_logs '0'
	option health_enabled '1'
	option health_interval '600'
	option health_dns_check '1'
	option health_clash_api_check '1'
	option health_ping_ip '77.88.8.8 8.8.8.8'
	option health_opera_host 'ya.ru google.com'
	option update_interval '1d'
	option timeout_dnsmasq_restart '150'
	option timeout_xray_check '60'
	option disable_startup_check '0'
	option manage_xray '1'
	option update_time '09:00'
	option api 'v2'
	option enable_bad_interface_monitoring '0'
	option download_lists_via_proxy '0'
	option auto_fallback_two_stage '1'
	option whitelist_probe_max '100'
	option lists_failure_mode 'degrade'
	option timeout_singbox_check '60'
	option timeout_singbox_kill '15'
	option health_dns_server_check '0'
	option health_dns_test_host 'ya.ru'
	option dns_query_timeout '15'
	option singbox_double_check '0'
	option singbox_double_check_delay '15'
	option lists_tls_insecure '0'
	option opera_proxy_enabled '1'
	option timeouts_forced_to_max_v4 '1'
	option text_lists_migrated '1'
	option sub_max_proxies_capped '1'
	option autoremove_static_lease_default_v1 '1'
	option subscription_ua_migrated_v2 '1'
	option subscription_update_interval 'off'
	option dns_recovery_enabled '1'
	option health_opera '1'

config auto_config 'auto_config'
	option opera_auto_config '1'
	option awg_auto_config '1'
	option xray_auto_config '$XRAY_FLAG'
	option zapret2_auto_config '1'
	option zapret2_auto_strategies '1'
	option trusttunnel_auto_config '0'
	option naive_auto_config '0'
	option sections_auto_load '1'

config dashboard 'dashboard'

config diagnostic 'diagnostic'

config engine 'engine'
	option dns_type 'doh'
	option dns_server 'xbox-dns.ru'
	option bootstrap_dns_server '9.9.9.11'
	option dns_rewrite_ttl '60'
	option dns_strategy 'ipv4_only'
	option autoremove_static_lease '1'
	option clash_api_enabled '1'
	option clash_api_port '9090'
	option tproxy_mark '0x10000'
	option direct_mark '0x20000'
	option bt_mark '0x40000'
	option ctmark_dns '0x10000'
	option ctmark_bt '0x40000'
	option disable_output_conntrack_rules '0'
	option disable_quic '1'
	option disable_quic_gso '0'
	option MemoryMax '0'
	option MemoryHigh '0'
	option ulimit_v '0'
	option tls_fragment '0'
	option tls_record_fragment '0'
	option desync_mark '$DESYNC_MARK'
	option log_level 'warn'
	option dont_touch_dhcp '0'
	option dns_hijack '1'
	option enable_output_network_interface '0'
	option proxy_router_traffic '0'
	option ipv6_enabled '0'
	option discord_voice '1'
	option meta_force_cidr '1'
	option exclude_bittorrent '1'
	option exclude_ntp '1'
	option singbox_logging '0'
	option xray_logging '0'
	option testing_url 'https://www.gstatic.com/generate_204'
	option trusttunnel_logging '0'
	option fakeip_query_type_filter '1'
	option xray_path '/usr/bin/xray'
	option trusttunnel_path '/usr/bin/trusttunnel_client'
	option custom_config_dir '/etc/zeroblock/sing-box.d'
	option dpi_check_timeout '15'
	option adblock_convert_timeout '300'
	option fallback_probe_timeout_default '3'
	option singbox_startup_timeout '150'
	option xray_startup_timeout '60'
	option trusttunnel_startup_timeout '60'
	option version_check_timeout '31'
	option bootstrap_port_free_timeout '6'
	option singbox_sighup_wait_timeout '16'
	option subscription_timeout '60'
	option subscription_max_proxies '100'
	option subscription_user_agent 'Happ'
	option subscription_tls_insecure '0'
	option enable_yacd '0'
	option naive_startup_timeout '8'
	option naive_logging '0'
	option global_exclude_mode 'route'
	list source_network_interfaces 'br-lan'

EOF

	ok "конфиг записан (xray_auto_config=$XRAY_FLAG)"
}

# ------------------------------------------------------------------ ШАГ 7 --
# Автонастройка

wait_autoconfig() {
	step "Автонастройка ZeroBlock"

	/etc/init.d/zeroblock enable >/dev/null 2>&1
	/etc/init.d/zeroblock start  >/dev/null 2>&1

	info "жду создания секций awg10 и opera (до $ZB_AUTOCONFIG_WAIT сек)"
	elapsed=0
	while [ "$elapsed" -lt "$ZB_AUTOCONFIG_WAIT" ]; do
		if section_exists awg10 && section_exists opera; then
			ok "секции созданы за ${elapsed} сек"
			# больше догружать нечего — снимаем флаг, чтобы не дёргало API
			uci set zeroblock.auto_config.sections_auto_load=''
			uci commit zeroblock
			return 0
		fi
		sleep 5
		elapsed=$((elapsed + 5))
	done

	warn "секции не появились за $ZB_AUTOCONFIG_WAIT сек"
	warn "проверьте интернет и логи: logread -e zeroblock"
	return 1
}

# ------------------------------------------------------------------ ШАГ 8 --
# Community-списки

assign_community_lists() {
	step "Community-списки по секциям"

	# ZeroBlock не даёт одному списку принадлежать двум секциям и сам
	# разруливает пересечения при следующем rebuild.
	for pair in "awg10:$CL_AWG10" "MESSENGERS:$CL_MESSENGERS" "opera:$CL_OPERA"; do
		sec="${pair%%:*}"
		lists="${pair#*:}"
		if ! section_exists "$sec"; then
			info "$sec — секции нет, пропускаю"
			continue
		fi
		udel "zeroblock.$sec.community_lists"
		for l in $lists; do uci add_list "zeroblock.$sec.community_lists=$l"; done
		ok "$sec: $lists"
	done

	uci commit zeroblock
}

# ------------------------------------------------------------------ ШАГ 9 --
# Пользовательские списки

install_lists() {
	step "Пользовательские списки"

	if [ "$ZB_SKIP_LISTS" = "1" ]; then
		info "пропущены (ZB_SKIP_LISTS=1)"
		return 0
	fi
	if [ ! -d "$SCRIPT_DIR/lists" ]; then
		warn "каталог lists/ не найден"
		return 0
	fi

	mkdir -p "$LIST_DIR"
	COUNT=0
	for sec in awg10 MESSENGERS opera; do
		SRC="$SCRIPT_DIR/lists/zb-$sec.lst"
		[ -f "$SRC" ] || continue
		if ! section_exists "$sec"; then
			info "$sec — секции нет, список пропущен"
			continue
		fi
		cp "$SRC" "$LIST_DIR/zb-$sec.lst"
		udel "zeroblock.$sec.user_lists"
		uci add_list "zeroblock.$sec.user_lists=$LIST_DIR/zb-$sec.lst"
		uci set "zeroblock.$sec.enable_user_lists=1"
		N=$(wc -l <"$LIST_DIR/zb-$sec.lst")
		ok "$sec: $N строк"
		COUNT=$((COUNT + 1))
	done

	[ "$COUNT" -gt 0 ] && uci commit zeroblock
}

install_excludes() {
	step "Глобальные исключения (российские ресурсы — напрямую)"

	if [ "$ZB_SKIP_EXCLUDES" = "1" ]; then
		info "пропущены (ZB_SKIP_EXCLUDES=1)"
		return 0
	fi

	DOMS="$SCRIPT_DIR/lists/exclude-domains.txt"
	IPS="$SCRIPT_DIR/lists/exclude-ips.txt"

	if [ -f "$DOMS" ]; then
		udel zeroblock.engine.excluded_domains_text
		while IFS= read -r l; do
			[ -n "$l" ] && uci add_list "zeroblock.engine.excluded_domains_text=$l"
		done <"$DOMS"
		ok "доменов: $(uget zeroblock.engine.excluded_domains_text | wc -w)"
	else
		info "exclude-domains.txt не найден"
	fi

	if [ -f "$IPS" ]; then
		udel zeroblock.engine.excluded_ips_text
		while IFS= read -r l; do
			[ -n "$l" ] && uci add_list "zeroblock.engine.excluded_ips_text=$l"
		done <"$IPS"
		ok "подсетей: $(uget zeroblock.engine.excluded_ips_text | wc -w)"
	else
		info "exclude-ips.txt не найден"
	fi

	uci commit zeroblock
}

# ----------------------------------------------------------------- ШАГ 10 --
# Zapret2

setup_zapret2() {
	step "Zapret2"

	if [ ! -f /etc/init.d/zapret2 ]; then
		info "не установлен, ставлю из репозитория"
		opkg install zapret2 luci-app-zapret2 >>"$LOG" 2>&1
	fi

	if [ ! -f /etc/init.d/zapret2 ]; then
		warn "zapret2 установить не удалось"
		warn "ZeroBlock попробует сам (zapret2_auto_config=1) при следующем reload"
		return 0
	fi

	# Метка должна совпадать с zeroblock.engine.desync_mark, иначе zapret2
	# будет повторно обрабатывать соединения к прокси-эндпоинтам ZeroBlock.
	CUR=$(uget zapret2.main.desync_mark)
	if [ "$CUR" != "$DESYNC_MARK" ]; then
		uci set zapret2.main.desync_mark="$DESYNC_MARK"
		uci commit zapret2
		ok "desync_mark выставлена в $DESYNC_MARK (было: ${CUR:-пусто})"
	else
		ok "desync_mark уже $DESYNC_MARK"
	fi

	uci set zapret2.main.enabled='1'
	uci commit zapret2

	/etc/init.d/zapret2 enable >/dev/null 2>&1
	/etc/init.d/zapret2 start  >>"$LOG" 2>&1
	sleep 10

	if /etc/init.d/zapret2 status 2>&1 | grep -qi running; then
		ok "запущен, процессов nfqws: $(pgrep nfqws 2>/dev/null | wc -l)"
	else
		warn "не запустился, смотрите: logread | grep zapret2"
	fi
}

# ----------------------------------------------------------------- ШАГ 11 --
# Применение и проверка

apply_and_refresh() {
	step "Применение конфигурации"

	/etc/init.d/zeroblock restart >>"$LOG" 2>&1
	info "жду поднятия движка"
	sleep 45

	rm -rf /tmp/luci-modulecache/ 2>/dev/null
	rm -f /tmp/luci-indexcache.json 2>/dev/null
	/etc/init.d/rpcd   reload >/dev/null 2>&1
	/etc/init.d/uhttpd reload >/dev/null 2>&1
	ok "меню LuCI обновлено"
}

verify() {
	step "Проверка"

	for svc in zeroblock zapret2; do
		if [ -f "/etc/init.d/$svc" ]; then
			EN=$("/etc/init.d/$svc" enabled >/dev/null 2>&1 && echo "автозапуск" || echo "БЕЗ автозапуска")
			ST=$("/etc/init.d/$svc" status 2>&1 | head -1)
			case "$ST" in
				*running*) ok "$svc: $ST, $EN" ;;
				*)         warn "$svc: $ST, $EN" ;;
			esac
		fi
	done

	if pgrep -f "sing-box run" >/dev/null 2>&1; then
		ok "sing-box работает"
	else
		warn "sing-box не найден в процессах"
	fi

	for svc in $LEGACY_SERVICES; do
		[ -f "/etc/init.d/$svc" ] || continue
		if "/etc/init.d/$svc" enabled >/dev/null 2>&1; then
			warn "$svc всё ещё в автозапуске"
		else
			ok "$svc выключен"
		fi
	done

	if command -v awg >/dev/null 2>&1 && awg show awg10 >/dev/null 2>&1; then
		HS=$(awg show awg10 2>/dev/null | grep "latest handshake" | sed 's/^ *//')
		[ -n "$HS" ] && ok "awg10: $HS" || warn "awg10: рукопожатия ещё не было"
	fi

	R1=$(nslookup youtube.com 127.0.0.1 2>/dev/null | awk '/^Address/{print $NF}' | tail -1)
	R2=$(nslookup ya.ru 127.0.0.1 2>/dev/null | awk '/^Address/{print $NF}' | tail -1)
	[ -n "$R2" ] && ok "DNS отвечает (ya.ru → $R2)" || warn "DNS не отвечает"
	case "$R1" in
		198.18.*) ok "маршрутизация активна (youtube.com → $R1, fake-IP)" ;;
		"")       warn "youtube.com не резолвится" ;;
		*)        info "youtube.com → $R1 (не fake-IP; нормально, если списки ещё грузятся)" ;;
	esac

	FREE=$(free_kb); [ -n "$FREE" ] || FREE=0
	info "свободно на /overlay: $((FREE / 1024)) МБ"
}

summary() {
	BD=$(cat /tmp/zb_backup_dir 2>/dev/null || echo "")
	log ""
	log "${C_CYN}────────────────────────────────────────────────${C_OFF}"
	if [ "$WARN_COUNT" -eq 0 ]; then
		log "${C_GRN}  Готово. Предупреждений нет.${C_OFF}"
	else
		log "${C_YEL}  Готово. Предупреждений: $WARN_COUNT — см. вывод выше.${C_OFF}"
	fi
	log "${C_CYN}────────────────────────────────────────────────${C_OFF}"
	log ""
	log "  Веб-интерфейс:  Службы → ZeroBlock"
	log "  ${C_DIM}Если пункта нет — обновите страницу, перелогиньтесь"
	log "  или откройте админку в инкогнито-окне.${C_OFF}"
	log ""
	log "  Лог установки:  $LOG"
	if [ -n "$BD" ]; then
		log "  Бэкап:          $BD"
		log ""
		log "  Полный откат:"
		log "    ${C_DIM}sysupgrade -r $BD/sysupgrade-config.tar.gz && reboot${C_OFF}"
		log "  или:"
		log "    ${C_DIM}sh uninstall.sh full${C_OFF}"
	else
		log "  Бэкап:          не делался"
		log ""
		log "  Мягкий откат:   ${C_DIM}sh uninstall.sh${C_OFF}"
	fi
	log ""
	log "  Проверьте с телефона: YouTube, Telegram, ChatGPT,"
	log "  и отдельно банки с Госуслугами — они должны идти напрямую."
	log ""
}

# -------------------------------------------------------------------- MAIN --

: >"$LOG"
log ""
log "${C_CYN}  ZeroBlock + Zapret2 — автоустановка v$VERSION${C_OFF}"
log "${C_DIM}  $(date)${C_OFF}"

preflight
do_backup
disable_legacy
dns_temp_on
install_packages
write_config
wait_autoconfig
assign_community_lists
install_lists
install_excludes
setup_zapret2
dns_temp_off
apply_and_refresh
verify
summary

exit 0
