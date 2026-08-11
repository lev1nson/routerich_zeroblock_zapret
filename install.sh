#!/bin/sh
#
# ZeroBlock + Zapret2 — автоустановка для OpenWrt / RouteRich
# https://github.com/lev1nson/routerich_zeroblock_zapret
#
# Работает без вопросов. Все переключатели — через переменные окружения,
# см. README.md и блок DEFAULTS ниже.
#
# Поддерживает opkg (OpenWrt 24.10 и старше) и apk (OpenWrt 25.12 и новее).
# Пакеты берёт из вложенных .ipk при совпадении архитектуры, иначе из фидов
# роутера.
#
# Запуск:
#   sh install.sh
#
# По SSH лучше через setsid, чтобы обрыв связи не убил установку:
#   setsid sh install.sh
#

set -u

VERSION="1.2.1"
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || SCRIPT_DIR="."
LOG="/tmp/zeroblock-install.log"
LOCK="/tmp/zb-install.lock"
DHCP_BAK="/tmp/zb_dhcp.bak"
SAVED_SECTIONS="/tmp/zb_saved_sections.conf"

# ---------------------------------------------------------------- DEFAULTS --

BACKUP_ROOT="${ZB_BACKUP_DIR:-/root/zeroblock-migration}"
BACKUP_KEEP=3
LIST_DIR="/etc/zeroblock/lists"
DESYNC_MARK="0x40000000"
TEMP_DNS="${ZB_TEMP_DNS:-9.9.9.11}"

# xray-core требует ~29.6 МБ. Ставим, только если места заведомо хватает.
XRAY_MIN_FREE_KB=35000
# Минимум свободного места для чистой установки: сам ZeroBlock плюс
# зависимости (sing-box, opera-proxy, conntrack и прочее).
MIN_FREE_KB=4500
# Для переустановки поверх уже стоящего ZeroBlock зависимости уже на месте,
# нужно место только под распаковку самого пакета.
MIN_FREE_REINSTALL_KB=1800

# Службы старых схем обхода блокировок: останавливаем и убираем из автозапуска.
# Все они так или иначе лезут в nftables и маршрутизацию и конфликтуют
# с ZeroBlock. Пакеты при этом остаются в системе.
LEGACY_SERVICES="podkop podkop-plus zapret zapret-ng nikita byedpi youtubeUnblock
	ruantiblock passwall passwall2 openclash xkeen v2raya shadowsocks-libev
	shadowsocksr-libev tun2socks"

# Порт dns-failsafe-proxy — штатная точка входа dnsmasq в ZeroBlock.
# Остальные локальные переопределения в dnsmasq считаются наследием
# старой схемы и удаляются (если ZB_SKIP_DNS_CLEANUP=0).
ZB_DNS_PORT="5359"

# Community-списки по секциям. ZeroBlock сам разрулит пересечения.
CL_AWG10="anime block discord googleplay torrent youtube"
CL_MESSENGERS="messengers meta"
CL_OPERA="video art geoblock games music shop porn socials news repo ai tools"

# Секции, которым раздаём списки.
SECTIONS="awg10 MESSENGERS opera"

# ------------------------------------------------------------------- ВЫВОД --

if [ -t 1 ]; then
	C_OFF="\033[0m"; C_RED="\033[1;31m"; C_GRN="\033[0;32m"
	C_YEL="\033[0;33m"; C_CYN="\033[0;36m"; C_DIM="\033[2m"
else
	C_OFF=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""
fi

WARN_COUNT=0
AUTOCONFIG_FAILED=0
DNS_SWAPPED=0
PKG_UPDATED=0

log()  { printf "%b\n" "$*" | tee -a "$LOG"; }
step() { printf "\n%b\n" "${C_CYN}==> $*${C_OFF}" | tee -a "$LOG"; }
ok()   { printf "%b\n" "  ${C_GRN}✓${C_OFF} $*" | tee -a "$LOG"; }
info() { printf "%b\n" "  ${C_DIM}·${C_OFF} $*" | tee -a "$LOG"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); printf "%b\n" "  ${C_YEL}!${C_OFF} $*" | tee -a "$LOG"; }
die()  { printf "%b\n" "  ${C_RED}✗ $*${C_OFF}" | tee -a "$LOG"; exit 1; }

# Приводит значение переключателя к 0/1: принимаем 1/y/yes/true/on.
flag() {
	case "$1" in
		1|y|Y|yes|YES|true|TRUE|on|ON) echo 1 ;;
		*) echo 0 ;;
	esac
}

# Целое число или значение по умолчанию.
num() {
	case "$1" in
		''|*[!0-9]*) echo "$2" ;;
		*) echo "$1" ;;
	esac
}

ZB_SKIP_BACKUP=$(flag "${ZB_SKIP_BACKUP:-0}")
ZB_SKIP_LISTS=$(flag "${ZB_SKIP_LISTS:-0}")
ZB_SKIP_EXCLUDES=$(flag "${ZB_SKIP_EXCLUDES:-0}")
ZB_SKIP_DNS_CLEANUP=$(flag "${ZB_SKIP_DNS_CLEANUP:-0}")
ZB_SKIP_LEGACY=$(flag "${ZB_SKIP_LEGACY:-0}")
ZB_KEEP_CONFIG=$(flag "${ZB_KEEP_CONFIG:-0}")
ZB_INSTALL_TG=$(flag "${ZB_INSTALL_TG:-0}")
ZB_REMOVE_PODKOP=$(flag "${ZB_REMOVE_PODKOP:-0}")
ZB_PREFER_REPO=$(flag "${ZB_PREFER_REPO:-0}")
ZB_FORCE=$(flag "${ZB_FORCE:-0}")
ZB_AUTOCONFIG_WAIT=$(num "${ZB_AUTOCONFIG_WAIT:-300}" 300)

# --------------------------------------------------------- АВАРИЙНЫЙ ВЫХОД --
# Скрипт надолго подменяет DNS. Если его прибьют на середине (обрыв SSH,
# Ctrl-C, ошибка), роутер останется с чужим резолвером и без прежних
# серверов. Возвращаем всё на место в любом случае.

on_exit() {
	rc=$?
	trap - EXIT INT TERM HUP

	if [ "$rc" != "0" ] && [ "$DNS_SWAPPED" = "1" ] && [ -f "$DHCP_BAK" ]; then
		printf "\n  ${C_YEL}! аварийное завершение (код %s) — возвращаю DNS${C_OFF}\n" "$rc" | tee -a "$LOG"
		cp "$DHCP_BAK" /etc/config/dhcp 2>/dev/null && rm -f "$DHCP_BAK"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		printf "  ${C_YEL}! состояние промежуточное. Откат: sh uninstall.sh${C_OFF}\n" | tee -a "$LOG"
		printf "  ${C_DIM}  лог: %s${C_OFF}\n" "$LOG" | tee -a "$LOG"
	fi

	rmdir "$LOCK" 2>/dev/null
	exit "$rc"
}

# ------------------------------------------------------------ ХЕЛПЕРЫ UCI --

# uci -q delete на отсутствующем ключе возвращает не ноль — глушим.
udel() { uci -q delete "$1" 2>/dev/null || true; }
uget() { uci -q get "$1" 2>/dev/null || true; }

section_exists() { [ -n "$(uget "zeroblock.$1")" ]; }

count_sections() { uci show zeroblock 2>/dev/null | grep -c '=section$'; }

svc_enabled() { [ -f "/etc/init.d/$1" ] && "/etc/init.d/$1" enabled >/dev/null 2>&1; }

# procd печатает "running", "not running", "inactive", "active with no
# instances". Наивный grep -i running матчит и "not running" — то есть
# рапортует об успехе на мёртвой службе.
svc_running() {
	[ -f "/etc/init.d/$1" ] || return 1
	"/etc/init.d/$1" running >/dev/null 2>&1 && return 0
	case "$("/etc/init.d/$1" status 2>&1)" in
		*"not running"*|*inactive*|*unknown*) return 1 ;;
		*[Rr]unning*) return 0 ;;
		*) return 1 ;;
	esac
}

# --------------------------------------------------- СЛОЙ ПАКЕТНОГО МЕНЕДЖЕРА
# OpenWrt 24.10 и старше — opkg и .ipk.
# OpenWrt 25.12 и новее — apk и .apk.

PKGM=""

detect_pkgm() {
	if command -v apk >/dev/null 2>&1 && apk --version >/dev/null 2>&1; then
		PKGM="apk"
	elif command -v opkg >/dev/null 2>&1; then
		PKGM="opkg"
	else
		die "не найден ни apk, ни opkg — не понимаю, как ставить пакеты"
	fi
}

pkg_update() {
	[ "$PKG_UPDATED" = "1" ] && return 0
	i=1
	while [ "$i" -le 4 ]; do
		if [ "$PKGM" = "apk" ]; then
			apk update >/tmp/pkg_update.log 2>&1 && { PKG_UPDATED=1; return 0; }
		else
			if opkg update >/tmp/pkg_update.log 2>&1 &&
				! grep -qiE "failed|error|unable|not found|refused|timeout" /tmp/pkg_update.log; then
				PKG_UPDATED=1
				return 0
			fi
		fi
		i=$((i + 1))
		[ "$i" -le 4 ] && sleep 3
	done
	return 1
}

pkg_installed() {
	if [ "$PKGM" = "apk" ]; then
		[ -n "$(apk info -e "$1" 2>/dev/null)" ]
	else
		opkg list-installed 2>/dev/null | awk -v p="$1" '$1 == p { f = 1 } END { exit !f }'
	fi
}

pkg_version() {
	if [ "$PKGM" = "apk" ]; then
		apk list -I "$1" 2>/dev/null | head -1 | awk '{print $1}' | sed "s/^$1-//"
	else
		opkg list-installed 2>/dev/null | awk -v p="$1" '$1 == p { print $3; exit }'
	fi
}

pkg_available() {
	if [ "$PKGM" = "apk" ]; then
		apk list "$1" 2>/dev/null | grep -q .
	else
		opkg list 2>/dev/null | awk -v p="$1" '$1 == p { f = 1 } END { exit !f }'
	fi
}

pkg_install_repo() {
	if [ "$PKGM" = "apk" ]; then
		apk add "$@" >>"$LOG" 2>&1
	else
		opkg install "$@" >>"$LOG" 2>&1
	fi
}

# --force-reinstall: иначе opkg на совпадающей версии молча ничего не делает,
# а мы обещали переустановку.
pkg_install_file() {
	if [ "$PKGM" = "apk" ]; then
		apk add --allow-untrusted "$1" >>"$LOG" 2>&1
	else
		opkg install --force-reinstall "$1" >>"$LOG" 2>&1 || opkg install "$1" >>"$LOG" 2>&1
	fi
}

pkg_remove() {
	if [ "$PKGM" = "apk" ]; then
		apk del "$@" >>"$LOG" 2>&1
	else
		opkg remove "$@" >>"$LOG" 2>&1
	fi
}

# ------------------------------------------------- ОПРЕДЕЛЕНИЕ ХАРАКТЕРИСТИК

# Раздел, куда реально пишутся пакеты: на большинстве роутеров /overlay,
# на x86 и подобных — просто корень.
pkg_root() {
	if [ -d /overlay ] && df -k /overlay >/dev/null 2>&1; then
		echo "/overlay"
	else
		echo "/"
	fi
}

# Свободно килобайт. Обязательно возвращать число: в busybox ash
# арифметика над нечисловой строкой ФАТАЛЬНА — скрипт умирает на месте.
free_kb() {
	FKB=$(df -k "$(pkg_root)" 2>/dev/null | tail -1 | awk '{print $(NF-2)}')
	case "$FKB" in
		''|*[!0-9]*) echo 0 ;;
		*) echo "$FKB" ;;
	esac
}

free_mb() { echo $(( $(free_kb) / 1024 )); }

detect_board() {
	MODEL=$(cat /tmp/sysinfo/model 2>/dev/null)
	[ -n "$MODEL" ] || MODEL=$(tr -d '\000' </proc/device-tree/model 2>/dev/null)
	[ -n "$MODEL" ] || MODEL="неизвестно"

	RELEASE=""
	ARCH=""
	if [ -f /etc/openwrt_release ]; then
		# shellcheck disable=SC1091
		. /etc/openwrt_release
		RELEASE="${DISTRIB_DESCRIPTION:-}"
		ARCH="${DISTRIB_ARCH:-}"
	fi
	[ -n "$RELEASE" ] || RELEASE=$(grep PRETTY_NAME /usr/lib/os-release 2>/dev/null | cut -d'"' -f2)
	[ -n "$RELEASE" ] || RELEASE="неизвестно"

	if [ -z "$ARCH" ]; then
		if [ "$PKGM" = "apk" ]; then
			ARCH=$(apk --print-arch 2>/dev/null)
		else
			ARCH=$(opkg print-architecture 2>/dev/null | awk '$3 > 1 && $2 != "all" {print $2}' | tail -1)
		fi
	fi
	[ -n "$ARCH" ] || ARCH=$(uname -m)
}

# LAN-мост может называться не br-lan. Функция вызывается внутри heredoc,
# поэтому НИЧЕГО кроме имени интерфейса в stdout выводить нельзя.
lan_iface() {
	IF=$(uget network.lan.device)
	[ -n "$IF" ] || IF=$(uget network.lan.ifname)
	[ -n "$IF" ] || IF=$(ubus call network.interface.lan status 2>/dev/null |
		sed -n 's/.*"l3_device": *"\([^"]*\)".*/\1/p' | head -1)
	if [ -n "$IF" ] && [ -e "/sys/class/net/$IF" ]; then
		echo "$IF"
		return 0
	fi
	[ -e /sys/class/net/br-lan ] && { echo "br-lan"; return 0; }
	echo "${IF:-br-lan}"
}

# Адрес из ответа nslookup. Служебную строку "Address: 127.0.0.1:53"
# (это адрес самого сервера) отбрасываем, иначе мёртвый резолвер выглядит
# как работающий.
dns_a() {
	nslookup "$1" 127.0.0.1 2>/dev/null |
		sed -n '/^Name:/,$p' | awk '/^Address/{print $NF}' | tail -1
}

# ------------------------------------------------------------------ ШАГ 1 --

preflight() {
	step "Проверка окружения"

	[ "$(id -u)" = "0" ] || die "нужны права root"
	command -v uci >/dev/null 2>&1 || die "uci не найден — это не OpenWrt"

	detect_pkgm
	detect_board

	info "модель:    $MODEL"
	info "прошивка:  $RELEASE"
	info "arch:      $ARCH"
	info "пакеты:    $PKGM"

	# ZeroBlock строит правила на nftables. На прошивках с iptables/fw3
	# он не заработает.
	if ! command -v nft >/dev/null 2>&1; then
		if [ "$ZB_FORCE" = "1" ]; then
			warn "nft не найден (нужен nftables/fw4), продолжаю из-за ZB_FORCE=1"
		else
			die "не найден nft: ZeroBlock требует nftables (fw4). Запустить всё равно: ZB_FORCE=1 sh install.sh"
		fi
	fi

	# Секции с disable_fakeip опираются на dnsmasq nftset. Обычный dnsmasq
	# его не умеет — нужен dnsmasq-full.
	if command -v dnsmasq >/dev/null 2>&1; then
		if dnsmasq --version 2>/dev/null | grep -qi "nftset"; then
			ok "dnsmasq с поддержкой nftset"
		else
			warn "dnsmasq без nftset — часть правил не заработает, поставьте dnsmasq-full"
		fi
	else
		warn "dnsmasq не найден — DNS-перехват ZeroBlock работать не будет"
	fi

	LI=$(lan_iface)
	if [ -e "/sys/class/net/$LI" ]; then
		info "LAN:       $LI"
	else
		warn "интерфейс $LI не существует — ZeroBlock может не увидеть трафик LAN"
	fi

	resolve_packages

	# Переустановка поверх рабочей системы требует куда меньше места,
	# чем первая установка со всеми зависимостями.
	if pkg_installed zeroblock; then
		NEED_KB="$MIN_FREE_REINSTALL_KB"
		info "ZeroBlock уже установлен — режим переустановки"
	else
		NEED_KB="$MIN_FREE_KB"
	fi

	FREE=$(free_kb)
	info "свободно:  $((FREE / 1024)) МБ на $(pkg_root), нужно $((NEED_KB / 1024)) МБ"
	if [ "$FREE" -lt "$NEED_KB" ]; then
		[ "$ZB_FORCE" = "1" ] ||
			die "мало места: нужно минимум $((NEED_KB / 1024)) МБ. Всё равно: ZB_FORCE=1 sh install.sh"
		warn "мало места, продолжаю из-за ZB_FORCE=1"
	fi

	if ping -c 1 -W 3 "$TEMP_DNS" >/dev/null 2>&1; then
		ok "интернет есть"
	else
		warn "не пингуется $TEMP_DNS — установка зависимостей может не пройти"
	fi
}

# Решает, откуда брать ZeroBlock: вложенный файл или фиды роутера.
resolve_packages() {
	ZB_IPK=""; LUCI_IPK=""; TG_IPK=""; SOURCE=""

	# Вложенные .ipk годятся только для opkg и только при совпадении арки.
	if [ "$PKGM" = "opkg" ] && [ "$ZB_PREFER_REPO" != "1" ] && [ -d "$SCRIPT_DIR/packages" ]; then
		ZB_IPK=$(ls "$SCRIPT_DIR"/packages/zeroblock_*_"$ARCH".ipk 2>/dev/null | head -1)
		LUCI_IPK=$(ls "$SCRIPT_DIR"/packages/luci-app-zeroblock_*_all.ipk 2>/dev/null | head -1)
		TG_IPK=$(ls "$SCRIPT_DIR"/packages/zeroblock-tg_*_"$ARCH".ipk 2>/dev/null | head -1)
	fi

	if [ -n "$ZB_IPK" ] && [ -n "$LUCI_IPK" ]; then
		SOURCE="file"
		ok "источник: вложенный пакет $(basename "$ZB_IPK")"
		return 0
	fi

	# Иначе — фиды роутера. Индекс мог ни разу не обновляться.
	pkg_update || warn "не удалось обновить индекс пакетов"
	if pkg_available zeroblock; then
		SOURCE="repo"
		ok "источник: репозиторий роутера ($PKGM)"
		return 0
	fi

	log ""
	log "  ZeroBlock не найден ни во вложенных пакетах, ни в фидах роутера."
	log "  У вас: arch ${C_YEL}$ARCH${C_OFF}, пакетный менеджер ${C_YEL}$PKGM${C_OFF}."
	log ""
	log "  В packages/ лежит:"
	ls -1 "$SCRIPT_DIR"/packages/ 2>/dev/null | sed 's|^|    |' | tee -a "$LOG"
	log ""
	log "  ZeroBlock официально публикуется только для mediatek/filogic:"
	log "    https://packages.routerich.ru/"
	log ""
	log "  Что можно сделать:"
	log "    1. Подключить фид RouteRich, если ваше устройство им поддерживается"
	log "    2. Положить свои .ipk/.apk в packages/ и запустить снова"
	die "нет подходящего пакета zeroblock для $ARCH"
}

# ------------------------------------------------------------------ ШАГ 2 --

do_backup() {
	step "Бэкап текущей конфигурации"

	BACKUP_DIR=""

	if [ "$ZB_SKIP_BACKUP" = "1" ]; then
		warn "пропущен (ZB_SKIP_BACKUP=1) — откатиться будет нечем"
		return 0
	fi

	# До синхронизации времени дата будет из 1970-х, а uninstall.sh выбирает
	# последний бэкап сортировкой по имени.
	Y=$(date +%Y 2>/dev/null)
	case "$(num "$Y" 0)" in
		0|1[0-9][0-9][0-9]) warn "часы роутера не синхронизированы ($Y) — имя каталога бэкапа будет странным" ;;
	esac

	# Ротация ДО создания нового бэкапа: старые архивы лежат на том же
	# разделе, куда мы сейчас будем ставить пакеты.
	rotate_backups "$((BACKUP_KEEP - 1))"

	OLDMASK=$(umask)
	umask 077
	BACKUP_DIR="$BACKUP_ROOT/$(date +%Y-%m-%d_%H-%M-%S)-$$"
	mkdir -p "$BACKUP_DIR" || { umask "$OLDMASK"; die "не могу создать $BACKUP_DIR"; }

	if command -v sysupgrade >/dev/null 2>&1; then
		sysupgrade -b "$BACKUP_DIR/sysupgrade-config.tar.gz" >>"$LOG" 2>&1
	fi

	if [ -s "$BACKUP_DIR/sysupgrade-config.tar.gz" ] &&
		tar -tzf "$BACKUP_DIR/sysupgrade-config.tar.gz" >/dev/null 2>&1; then
		N=$(tar -tzf "$BACKUP_DIR/sysupgrade-config.tar.gz" 2>/dev/null | wc -l)
		ok "sysupgrade-config.tar.gz — $N файлов, архив валиден"
	else
		# На нестандартных сборках sysupgrade может отсутствовать или падать.
		rm -f "$BACKUP_DIR/sysupgrade-config.tar.gz"
		warn "sysupgrade -b недоступен, делаю обычный архив /etc"
		tar czf "$BACKUP_DIR/etc-full.tar.gz" /etc >/dev/null 2>&1 ||
			{ umask "$OLDMASK"; die "не удалось сделать даже архив /etc — прерываюсь, чтобы не оставить вас без отката"; }
		ok "etc-full.tar.gz создан"
	fi

	tar czf "$BACKUP_DIR/etc-config.tar.gz" /etc/config /etc/zapret2 /etc/podkop >/dev/null 2>&1 ||
		tar czf "$BACKUP_DIR/etc-config.tar.gz" /etc/config >/dev/null 2>&1
	cp /etc/config/dhcp "$BACKUP_DIR/dhcp.bak" 2>/dev/null
	uci export >"$BACKUP_DIR/uci-export-all.txt" 2>/dev/null
	if [ "$PKGM" = "apk" ]; then
		apk list -I >"$BACKUP_DIR/packages-installed.txt" 2>/dev/null
	else
		opkg list-installed >"$BACKUP_DIR/packages-installed.txt" 2>/dev/null
	fi
	{
		echo "### model";   echo "$MODEL"
		echo "### release"; echo "$RELEASE"; echo "arch=$ARCH pkgm=$PKGM"
		echo "### df";      df -h
		echo "### ip addr"; ip -d addr 2>/dev/null
		echo "### routes";  ip route 2>/dev/null; ip rule 2>/dev/null
		echo "### nft";     nft list ruleset 2>/dev/null
	} >"$BACKUP_DIR/system-state.txt" 2>&1
	umask "$OLDMASK"

	ok "бэкап: $BACKUP_DIR"
	echo "$BACKUP_DIR" >/tmp/zb_backup_dir

	# Проверка места ДО бэкапа уже пройдена, но сам бэкап занял место.
	FREE=$(free_kb)
	if [ "$FREE" -lt "$NEED_KB" ]; then
		warn "после бэкапа осталось $((FREE / 1024)) МБ, нужно $((NEED_KB / 1024)) МБ"
		log ""
		log "  Что занимает место (крупнейшее в /root):"
		du -sk "$BACKUP_ROOT" /root/* 2>/dev/null | sort -rn | head -5 |
			awk '{printf "    %6.1f МБ  %s\n", $1/1024, $2}' | tee -a "$LOG"
		log ""
		log "  Варианты:"
		log "    ${C_DIM}rm -rf $BACKUP_ROOT${C_OFF}                 удалить бэкапы этого скрипта"
		log "    ${C_DIM}ZB_BACKUP_DIR=/tmp/zb-backup sh install.sh${C_OFF}  бэкап в /tmp (не переживёт ребут)"
		log "    ${C_DIM}ZB_FORCE=1 sh install.sh${C_OFF}                    рискнуть"
		log ""
		[ "$ZB_FORCE" = "1" ] || die "места не хватит на установку"
	fi
}

# Оставляет не более $1 каталогов бэкапов, удаляя самые старые.
rotate_backups() {
	KEEP=$(num "${1:-2}" 2)
	COUNT=$(num "$(ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | wc -l)" 0)
	[ "$COUNT" -gt "$KEEP" ] || return 0
	ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort | head -n "$((COUNT - KEEP))" |
		while IFS= read -r d; do rm -rf "$d"; done
	info "старых бэкапов удалено: $((COUNT - KEEP)), оставлено $KEEP"
}

# ------------------------------------------------------------------ ШАГ 3 --

install_packages() {
	step "Установка ZeroBlock"

	pkg_update || warn "не удалось обновить индекс пакетов — зависимости могут не установиться"

	CUR=$(pkg_version zeroblock)
	[ -n "$CUR" ] && info "уже установлен zeroblock $CUR, переустанавливаю"

	if [ "$SOURCE" = "file" ]; then
		pkg_install_file "$ZB_IPK" || { tail -20 "$LOG"; die "не удалось установить zeroblock (подробности в $LOG)"; }
		ok "zeroblock: $(basename "$ZB_IPK")"

		pkg_install_file "$LUCI_IPK" && ok "luci-app-zeroblock установлен" ||
			warn "luci-app-zeroblock не установился, веб-интерфейса не будет"

		if [ "$ZB_INSTALL_TG" = "1" ] && [ -n "$TG_IPK" ]; then
			pkg_install_file "$TG_IPK" && ok "zeroblock-tg (уведомления в Telegram)" ||
				warn "zeroblock-tg не установился"
		fi
	else
		pkg_install_repo zeroblock || { tail -20 "$LOG"; die "не удалось установить zeroblock из репозитория"; }
		ok "zeroblock: $(pkg_version zeroblock)"

		pkg_install_repo luci-app-zeroblock && ok "luci-app-zeroblock установлен" ||
			warn "luci-app-zeroblock не установился, веб-интерфейса не будет"

		if [ "$ZB_INSTALL_TG" = "1" ]; then
			pkg_install_repo zeroblock-tg && ok "zeroblock-tg (уведомления в Telegram)" ||
				warn "zeroblock-tg недоступен"
		fi
	fi

	pkg_installed zeroblock || die "zeroblock не появился в списке установленных"
	[ -f /etc/init.d/zeroblock ] || die "нет /etc/init.d/zeroblock — установка прошла криво"

	# postinst мог поднять службу рядом с ещё живой старой схемой.
	/etc/init.d/zeroblock stop >/dev/null 2>&1
}

# ------------------------------------------------------------------ ШАГ 4 --

disable_legacy() {
	step "Старые схемы обхода блокировок"

	if [ "$ZB_SKIP_LEGACY" = "1" ]; then
		warn "пропущено (ZB_SKIP_LEGACY=1) — конфликты с ZeroBlock вероятны"
		return 0
	fi

	FOUND=""
	for svc in $LEGACY_SERVICES; do
		[ -f "/etc/init.d/$svc" ] || continue
		FOUND="$FOUND $svc"
		"/etc/init.d/$svc" stop    >/dev/null 2>&1
		"/etc/init.d/$svc" disable >/dev/null 2>&1
		ok "$svc — остановлен и убран из автозапуска"
	done

	# Список нужен uninstall.sh, чтобы вернуть именно то, что выключили.
	if [ -n "$FOUND" ] && [ -n "${BACKUP_DIR:-}" ]; then
		for s in $FOUND; do echo "$s"; done >"$BACKUP_DIR/disabled-services.txt"
	fi

	# zapret2 глушим отдельно: он нам ещё нужен, но на время установки мешает.
	if [ -f /etc/init.d/zapret2 ]; then
		/etc/init.d/zapret2 stop >/dev/null 2>&1
		info "zapret2 временно остановлен, включим в конце"
	fi

	[ -n "$FOUND" ] || info "ничего из старых схем не найдено — чистая система"

	# Диагностика на случай, если старая схема оставила за собой правила.
	{
		echo "### ip rule после disable_legacy"; ip rule 2>/dev/null
		echo "### nft таблицы"; nft list tables 2>/dev/null
	} >>"$LOG" 2>&1

	if [ "$ZB_REMOVE_PODKOP" = "1" ] && pkg_installed podkop; then
		pkg_remove luci-app-podkop podkop && ok "podkop удалён" ||
			warn "не удалось удалить podkop, оставлен на месте"
	fi
}

# ------------------------------------------------------------------ ШАГ 5 --

dns_temp_on() {
	step "Временный DNS на время установки"

	if [ ! -f /etc/config/dhcp ]; then
		warn "нет /etc/config/dhcp — пропускаю подмену DNS"
		return 0
	fi

	# Незакоммиченная дельта от прошлого прогона иначе всплывёт при commit.
	uci -q revert dhcp 2>/dev/null

	if ! cp /etc/config/dhcp "$DHCP_BAK" 2>/dev/null || [ ! -s "$DHCP_BAK" ]; then
		rm -f "$DHCP_BAK"
		warn "не смог сохранить /etc/config/dhcp — DNS не трогаю"
		return 0
	fi

	# Подменять резолвер, не проверив, что новый работает, — верный способ
	# оставить весь дом без DNS на десять минут.
	if ! nslookup ya.ru "$TEMP_DNS" >/dev/null 2>&1; then
		rm -f "$DHCP_BAK"
		warn "$TEMP_DNS не отвечает на DNS-запросы — оставляю текущий DNS как есть"
		return 0
	fi

	ok "конфиг dnsmasq сохранён"

	udel "dhcp.@dnsmasq[0].server"
	uci set "dhcp.@dnsmasq[0].noresolv=1"
	uci add_list "dhcp.@dnsmasq[0].server=$TEMP_DNS"
	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	sleep 3

	if [ -z "$(dns_a ya.ru)" ]; then
		warn "после подмены резолв не работает — откатываю dnsmasq"
		cp "$DHCP_BAK" /etc/config/dhcp
		rm -f "$DHCP_BAK"
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
		return 0
	fi

	DNS_SWAPPED=1
	ok "DNS переключён на $TEMP_DNS"
}

dns_temp_off() {
	step "Возврат DNS"

	if [ "$DNS_SWAPPED" != "1" ] || [ ! -f "$DHCP_BAK" ]; then
		info "подмены DNS не было, пропускаю"
		return 0
	fi

	# Файл целиком не восстанавливаем: пока шла установка, ZeroBlock мог
	# прописать в dnsmasq свою точку входа, и она бы потерялась.
	# Возвращаем только то, что меняли сами.
	OLDRESOLV=$(awk '/option[ \t]+noresolv/{print $3}' "$DHCP_BAK" | head -1 | tr -d "'\"")
	SRV=$(awk '/list[ \t]+server/{print $3}' "$DHCP_BAK" | tr -d "'\"")

	DROPPED=0
	udel "dhcp.@dnsmasq[0].server"
	if [ -n "$OLDRESOLV" ]; then
		uci set "dhcp.@dnsmasq[0].noresolv=$OLDRESOLV"
	else
		udel "dhcp.@dnsmasq[0].noresolv"
	fi

	for s in $SRV; do
		# свой временный сервер обратно не тащим
		[ "$s" = "$TEMP_DNS" ] && continue

		if [ "$ZB_SKIP_DNS_CLEANUP" != "1" ]; then
			# доменные переопределения на локальный резолвер старой схемы
			case "$s" in
				/*/127.0.0.1*)
					case "$s" in
						*"#$ZB_DNS_PORT") ;;
						*) DROPPED=$((DROPPED + 1)); continue ;;
					esac
					;;
			esac
		fi
		uci add_list "dhcp.@dnsmasq[0].server=$s"
	done

	if [ "$DROPPED" -gt 0 ]; then
		ok "убрано $DROPPED доменных переопределений от старой схемы"
	else
		info "лишних переопределений не найдено"
	fi

	uci commit dhcp
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	sleep 3
	rm -f "$DHCP_BAK"
	DNS_SWAPPED=0

	if [ -n "$(dns_a ya.ru)" ]; then
		ok "DNS восстановлен и отвечает"
	else
		warn "после возврата DNS не резолвит — проверьте /etc/config/dhcp"
	fi
}

# ------------------------------------------------------------------ ШАГ 6 --

write_config() {
	step "Базовый конфиг ZeroBlock"

	if [ "$ZB_KEEP_CONFIG" = "1" ] && [ -f /etc/config/zeroblock ]; then
		info "существующий конфиг сохранён (ZB_KEEP_CONFIG=1)"
		return 0
	fi

	/etc/init.d/zeroblock stop >/dev/null 2>&1
	uci -q revert zeroblock 2>/dev/null

	[ -f /etc/config/zeroblock ] && [ -n "${BACKUP_DIR:-}" ] &&
		cp /etc/config/zeroblock "$BACKUP_DIR/zeroblock.cfg.bak" 2>/dev/null

	# Сохраняем существующие секции маршрутизации. Автонастройка догружает
	# только canonical-секции с сервера, а всё, что было создано руками или
	# приехало раньше (например MESSENGERS с подсетями Telegram), иначе
	# потерялось бы вместе со старым конфигом.
	rm -f "$SAVED_SECTIONS"
	if [ -f /etc/config/zeroblock ]; then
		awk 'BEGIN{q=sprintf("%c",39)}
			/^config /{ t=$2; gsub(q,"",t); keep = (t == "section") }
			keep' /etc/config/zeroblock >"$SAVED_SECTIONS" 2>/dev/null
		N=$(grep -c "^config " "$SAVED_SECTIONS" 2>/dev/null) || N=0
		N=$(num "$N" 0)
		[ "$N" -gt 0 ] && info "сохранено секций маршрутизации: $N"
	fi

	# Только собственные временные артефакты. Файлы самого пакета не трогаем:
	# на части сборок busybox find не умеет -exec {} +, и «чистка» либо
	# молча не работает, либо сносит только что установленное.
	rm -f /etc/zeroblock/*.tmp /etc/zeroblock/*.bak /etc/zeroblock/*.old 2>/dev/null
	rm -f /etc/config/zeroblock

	FREE=$(free_kb)
	if [ "$FREE" -ge "$XRAY_MIN_FREE_KB" ]; then
		XRAY_FLAG=1
		info "места хватает, xray-core разрешён"
	else
		XRAY_FLAG=0
		info "xray-core отключён: нужно $((XRAY_MIN_FREE_KB / 1024)) МБ, свободно $((FREE / 1024)) МБ"
	fi

	LANIF=$(lan_iface)

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
	list source_network_interfaces '$LANIF'

EOF

	if ! uci show zeroblock >/dev/null 2>&1; then
		[ -n "${BACKUP_DIR:-}" ] && [ -f "$BACKUP_DIR/zeroblock.cfg.bak" ] &&
			cp "$BACKUP_DIR/zeroblock.cfg.bak" /etc/config/zeroblock
		die "записанный конфиг невалиден, вернул прежний"
	fi
	ok "конфиг записан (xray_auto_config=$XRAY_FLAG, LAN=$LANIF)"
}

# ------------------------------------------------------------------ ШАГ 7 --

wait_autoconfig() {
	step "Автонастройка ZeroBlock"

	/etc/init.d/zeroblock enable >/dev/null 2>&1
	/etc/init.d/zeroblock start  >/dev/null 2>&1

	info "жду создания секций awg10 и opera (до $ZB_AUTOCONFIG_WAIT сек)"
	elapsed=0
	READY=0
	while [ "$elapsed" -lt "$ZB_AUTOCONFIG_WAIT" ]; do
		if section_exists awg10 && section_exists opera; then
			ok "базовые секции созданы за ${elapsed} сек"
			READY=1
			break
		fi
		sleep 5
		elapsed=$((elapsed + 5))
	done

	if [ "$READY" = "0" ]; then
		AUTOCONFIG_FAILED=1
		warn "секции не появились за $ZB_AUTOCONFIG_WAIT сек"
		warn "проверьте интернет и логи: logread -e zeroblock"
		restore_missing_sections
		return 0
	fi

	# awg10 и opera приходят первыми, остальные canonical-секции могут
	# подтянуться на несколько секунд позже. Флаг sections_auto_load не
	# снимаем — иначе догрузка обрывается на полпути.
	info "жду догрузки остальных секций"
	PREV=$(count_sections)
	settle=0
	while [ "$settle" -lt 60 ]; do
		sleep 10
		settle=$((settle + 10))
		NOW=$(count_sections)
		[ "$NOW" = "$PREV" ] && break
		PREV="$NOW"
	done

	restore_missing_sections
	ok "секций маршрутизации: $(count_sections)"
}

# Возвращает секции, которые были до переустановки, но не появились снова.
restore_missing_sections() {
	[ -f "$SAVED_SECTIONS" ] || return 0

	RESTORED=0
	NAMES=$(awk 'BEGIN{q=sprintf("%c",39)}
		/^config section /{ n=$3; gsub(q,"",n); if (n != "") print n }' "$SAVED_SECTIONS")

	for name in $NAMES; do
		section_exists "$name" && continue

		/etc/init.d/zeroblock stop >/dev/null 2>&1
		if ! cp /etc/config/zeroblock /tmp/zb_pre_restore.conf 2>/dev/null; then
			warn "не смог подстраховаться копией конфига — секцию $name не восстанавливаю"
			continue
		fi

		printf "\n" >>/etc/config/zeroblock
		awk -v want="$name" 'BEGIN{q=sprintf("%c",39)}
			/^config /{ n=$3; gsub(q,"",n); t=$2; gsub(q,"",t); inside = (t == "section" && n == want) }
			inside' "$SAVED_SECTIONS" >>/etc/config/zeroblock

		if uci show zeroblock >/dev/null 2>&1; then
			ok "восстановлена секция $name (автонастройка её не вернула)"
			RESTORED=$((RESTORED + 1))
		else
			warn "секция $name сделала конфиг невалидным — откатываю"
			cp /tmp/zb_pre_restore.conf /etc/config/zeroblock 2>/dev/null
		fi
		rm -f /tmp/zb_pre_restore.conf
	done

	if [ "$RESTORED" -gt 0 ]; then
		/etc/init.d/zeroblock start >/dev/null 2>&1
		sleep 20
	fi
}

# ------------------------------------------------------------------ ШАГ 8 --

assign_community_lists() {
	step "Community-списки по секциям"

	if [ "$ZB_KEEP_CONFIG" = "1" ]; then
		info "пропущено (ZB_KEEP_CONFIG=1)"
		return 0
	fi

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

install_lists() {
	step "Пользовательские списки"

	if [ "$ZB_SKIP_LISTS" = "1" ]; then
		info "пропущены (ZB_SKIP_LISTS=1)"
		return 0
	fi
	if [ "$ZB_KEEP_CONFIG" = "1" ]; then
		info "пропущено (ZB_KEEP_CONFIG=1)"
		return 0
	fi
	if [ ! -d "$SCRIPT_DIR/lists" ]; then
		warn "каталог lists/ не найден"
		return 0
	fi

	mkdir -p "$LIST_DIR"
	COUNT=0
	for sec in $SECTIONS; do
		SRC="$SCRIPT_DIR/lists/zb-$sec.lst"
		[ -f "$SRC" ] || continue
		if ! section_exists "$sec"; then
			info "$sec — секции нет, список пропущен"
			continue
		fi
		tr -d '\r' <"$SRC" >"$LIST_DIR/zb-$sec.lst"
		udel "zeroblock.$sec.user_lists"
		uci add_list "zeroblock.$sec.user_lists=$LIST_DIR/zb-$sec.lst"
		uci set "zeroblock.$sec.enable_user_lists=1"
		ok "$sec: $(wc -l <"$LIST_DIR/zb-$sec.lst") строк"
		COUNT=$((COUNT + 1))
	done

	if [ "$COUNT" -gt 0 ]; then
		uci commit zeroblock
	else
		warn "ни один список не подключён"
	fi
}

# Читает файл в uci-список, пропуская пустые строки, комментарии и CR.
load_text_list() {
	_key="$1"; _file="$2"; _n=0
	udel "$_key"
	while IFS= read -r l || [ -n "$l" ]; do
		l=$(printf '%s' "$l" | tr -d '\r')
		case "$l" in ''|\#*) continue ;; esac
		uci add_list "$_key=$l"
		_n=$((_n + 1))
	done <"$_file"
	echo "$_n"
}

install_excludes() {
	step "Глобальные исключения (российские ресурсы — напрямую)"

	if [ "$ZB_SKIP_EXCLUDES" = "1" ]; then
		info "пропущены (ZB_SKIP_EXCLUDES=1)"
		return 0
	fi
	if [ "$ZB_KEEP_CONFIG" = "1" ]; then
		info "пропущено (ZB_KEEP_CONFIG=1)"
		return 0
	fi

	DOMS="$SCRIPT_DIR/lists/exclude-domains.txt"
	IPS="$SCRIPT_DIR/lists/exclude-ips.txt"

	if [ -f "$DOMS" ]; then
		ok "доменов: $(load_text_list zeroblock.engine.excluded_domains_text "$DOMS")"
	else
		info "exclude-domains.txt не найден"
	fi

	if [ -f "$IPS" ]; then
		ok "подсетей: $(load_text_list zeroblock.engine.excluded_ips_text "$IPS")"
	else
		info "exclude-ips.txt не найден"
	fi

	uci commit zeroblock
}

# ----------------------------------------------------------------- ШАГ 10 --

setup_zapret2() {
	step "Zapret2"

	if [ ! -f /etc/init.d/zapret2 ]; then
		if pkg_available zapret2; then
			info "не установлен, ставлю из репозитория"
			pkg_install_repo zapret2 luci-app-zapret2 || pkg_install_repo zapret2
		else
			warn "zapret2 недоступен в фидах вашей прошивки"
			warn "ZeroBlock попробует поставить его сам (zapret2_auto_config=1)"
			return 0
		fi
	fi

	if [ ! -f /etc/init.d/zapret2 ]; then
		warn "zapret2 установить не удалось — DPI-обход для прямого трафика работать не будет"
		return 0
	fi

	# Метка должна совпадать с zeroblock.engine.desync_mark, иначе zapret2
	# будет повторно обрабатывать соединения к прокси-эндпоинтам ZeroBlock.
	WANT=$(uget zeroblock.engine.desync_mark)
	[ -n "$WANT" ] || WANT="$DESYNC_MARK"

	if [ -z "$(uget zapret2.main)" ]; then
		warn "в /etc/config/zapret2 нет секции 'main' — desync_mark не выставлен"
		warn "свяжите вручную: uci set zapret2.main.desync_mark=$WANT"
	else
		CUR=$(uget zapret2.main.desync_mark)
		if [ "$CUR" != "$WANT" ]; then
			if uci set "zapret2.main.desync_mark=$WANT" 2>/dev/null; then
				ok "desync_mark выставлена в $WANT (было: ${CUR:-пусто})"
			else
				warn "не удалось выставить desync_mark"
			fi
		else
			ok "desync_mark уже $WANT"
		fi
		uci set zapret2.main.enabled='1' 2>/dev/null || warn "не удалось включить zapret2 в uci"
		uci commit zapret2
	fi

	/etc/init.d/zapret2 enable >/dev/null 2>&1
	/etc/init.d/zapret2 start  >>"$LOG" 2>&1
	sleep 10

	if svc_running zapret2; then
		ok "запущен, процессов nfqws: $(pgrep nfqws 2>/dev/null | wc -l)"
	else
		warn "не запустился, смотрите: logread | grep zapret2"
	fi
}

# ----------------------------------------------------------------- ШАГ 11 --

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
		[ -f "/etc/init.d/$svc" ] || continue
		EN=$(svc_enabled "$svc" && echo "автозапуск" || echo "БЕЗ автозапуска")
		if svc_running "$svc"; then
			ok "$svc: running, $EN"
		else
			warn "$svc: не запущен, $EN"
		fi
	done

	if pgrep -f "sing-box" >/dev/null 2>&1; then
		ok "sing-box работает"
	else
		warn "sing-box не найден в процессах"
	fi

	NSEC=$(count_sections)
	if [ "$(num "$NSEC" 0)" -ge 2 ]; then
		ok "секций маршрутизации: $NSEC"
	else
		warn "секций всего $NSEC — часть сервисов не будет маршрутизироваться"
	fi

	for svc in $LEGACY_SERVICES; do
		[ -f "/etc/init.d/$svc" ] || continue
		svc_enabled "$svc" && warn "$svc всё ещё в автозапуске" || ok "$svc выключен"
	done

	if command -v awg >/dev/null 2>&1 && awg show awg10 >/dev/null 2>&1; then
		HS=$(awg show awg10 2>/dev/null | grep "latest handshake" | sed 's/^ *//')
		[ -n "$HS" ] && ok "awg10: $HS" || warn "awg10: рукопожатия ещё не было"
	fi

	R1=$(dns_a youtube.com)
	R2=$(dns_a ya.ru)
	[ -n "$R2" ] && ok "DNS отвечает (ya.ru → $R2)" || warn "DNS не отвечает"
	case "$R1" in
		198.18.*) ok "маршрутизация активна (youtube.com → $R1, fake-IP)" ;;
		"")       warn "youtube.com не резолвится" ;;
		*)        info "youtube.com → $R1 (не fake-IP; нормально, если списки ещё грузятся)" ;;
	esac

	# Фактическая проверка выхода: если у секции поднят mixed proxy,
	# сравниваем внешний адрес через него и напрямую.
	MP=""; MPSEC=""
	for sec in $SECTIONS; do
		[ "$(uget "zeroblock.$sec.enable_mixed_proxy")" = "1" ] || continue
		MP=$(uget "zeroblock.$sec.mixed_port")
		[ -n "$MP" ] && { MPSEC="$sec"; break; }
	done
	if [ -n "$MP" ] && command -v curl >/dev/null 2>&1; then
		VIA=$(curl -s --max-time 15 --proxy "http://127.0.0.1:$MP" https://api.ipify.org 2>/dev/null)
		DIR=$(curl -s --max-time 15 https://api.ipify.org 2>/dev/null)
		if [ -n "$VIA" ] && [ -n "$DIR" ]; then
			if [ "$VIA" != "$DIR" ]; then
				ok "трафик реально идёт в обход: $MPSEC → $VIA, напрямую → $DIR"
			else
				warn "выход через $MPSEC совпал с прямым ($DIR) — обход не работает"
			fi
		else
			info "проверку выхода сделать не удалось (нет ответа от api.ipify.org)"
		fi
	fi

	info "свободно: $(free_mb) МБ"
}

summary() {
	BD=$(cat /tmp/zb_backup_dir 2>/dev/null || echo "")
	log ""
	log "${C_CYN}────────────────────────────────────────────────${C_OFF}"
	if [ "$AUTOCONFIG_FAILED" = "1" ]; then
		log "${C_RED}  ZeroBlock не настроился: секции маршрутизации не созданы.${C_OFF}"
		log "${C_RED}  Обход сейчас НЕ работает, старые схемы выключены.${C_OFF}"
	elif [ "$WARN_COUNT" -eq 0 ]; then
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

	if [ -n "$BD" ] && [ -f "$BD/sysupgrade-config.tar.gz" ]; then
		log "  Бэкап:          $BD"
		log ""
		log "  Полный откат:"
		log "    ${C_DIM}sysupgrade -r $BD/sysupgrade-config.tar.gz && reboot${C_OFF}"
		log "  или:            ${C_DIM}sh uninstall.sh full${C_OFF}"
	elif [ -n "$BD" ]; then
		log "  Бэкап:          $BD ${C_YEL}(без sysupgrade-архива)${C_OFF}"
		log ""
		log "  Откат вручную:  ${C_DIM}tar xzf $BD/etc-full.tar.gz -C / && reboot${C_OFF}"
	else
		log "  Бэкап:          не делался"
	fi
	log "  Мягкий откат:   ${C_DIM}sh uninstall.sh${C_OFF}"
	log ""
	if [ "$AUTOCONFIG_FAILED" != "1" ]; then
		log "  Проверьте с телефона: YouTube, Telegram, ChatGPT,"
		log "  и отдельно банки с Госуслугами — они должны идти напрямую."
		log ""
	fi
}

# -------------------------------------------------------------------- MAIN --

mkdir "$LOCK" 2>/dev/null || die "установка уже запущена (если это не так: rmdir $LOCK)"
trap on_exit EXIT INT TERM HUP

[ -f "$LOG" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
: >"$LOG"
rm -f /tmp/zb_backup_dir "$SAVED_SECTIONS" /tmp/zb_pre_restore.conf

log ""
log "${C_CYN}  ZeroBlock + Zapret2 — автоустановка v$VERSION${C_OFF}"
log "${C_DIM}  $(date)${C_OFF}"

preflight
do_backup
install_packages      # ставим, пока рабочая схема ещё жива
disable_legacy        # ломаем только после того, как замена лежит на диске
dns_temp_on
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
