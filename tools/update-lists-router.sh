#!/bin/sh
#
# Обновление списков ZeroBlock прямо на роутере из проекта rekryt/iplist.
# В отличие от tools/fetch-lists.sh, который работает на машине разработчика
# и коммитит результат, этот скрипт ходит в источник сам — репозиторий не
# участвует вовсе.
#
#   sh update-lists-router.sh              обновить сейчас
#   sh update-lists-router.sh --install    поставить в /usr/bin и в cron
#   sh update-lists-router.sh --remove     убрать из cron
#   sh update-lists-router.sh --status     когда обновлялись, сколько строк
#
# Питон не нужен, только curl. Обновление занимает секунд двадцать.
#

set -u

SELF_PATH="/usr/bin/zeroblock-lists-update"
CRON_LINE="0 5 * * 1 $SELF_PATH --quiet"

LIST_DIR="/etc/zeroblock/lists"
STAMP="$LIST_DIR/.last-update"
LOG_TAG="zeroblock-lists"

URL_FOREIGN="${ZB_URL_FOREIGN:-https://iplist.my-handbook.ru}"
URL_RU="${ZB_URL_RU:-https://ru-iplist.my-handbook.ru}"

# Раскладка групп по секциям — та же, что в tools/build-lists.py.
G_AWG10="anime block discord googleplay torrent youtube cdn"
G_MESSENGERS="messengers meta"
G_OPERA="video art geoblock games music shop porn socials news repo ai tools"

# Если свежий список внезапно вдвое короче прежнего, это почти наверняка
# обрезанный ответ, а не реальное изменение. Такое не применяем.
SHRINK_GUARD_PCT=50

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

if [ -t 1 ] && [ "$QUIET" = "0" ]; then
	C_OFF="\033[0m"; C_RED="\033[1;31m"; C_GRN="\033[0;32m"
	C_YEL="\033[0;33m"; C_CYN="\033[0;36m"; C_DIM="\033[2m"
else
	C_OFF=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""
fi

say()  { [ "$QUIET" = "1" ] || printf "%b\n" "$*"; logger -t "$LOG_TAG" -- "$(printf '%b' "$*" | sed 's/\033\[[0-9;]*m//g')" 2>/dev/null; }
ok()   { say "  ${C_GRN}✓${C_OFF} $*"; }
info() { say "  ${C_DIM}·${C_OFF} $*"; }
warn() { say "  ${C_YEL}!${C_OFF} $*"; }
die()  { say "  ${C_RED}✗ $*${C_OFF}"; exit 1; }

groups_for() {
	case "$1" in
		awg10)      echo "$G_AWG10" ;;
		MESSENGERS) echo "$G_MESSENGERS" ;;
		opera)      echo "$G_OPERA" ;;
	esac
}

# Строк в файле, или 0.
lines() { [ -f "$1" ] && wc -l <"$1" || echo 0; }

fetch_to() {
	curl -fsSL --max-time 60 "$1" 2>/dev/null >>"$2"
}

# ------------------------------------------------------------------ СЕКЦИИ --

update_sections() {
	CHANGED=0
	for sec in awg10 MESSENGERS opera; do
		# Секции может не быть — тогда и список ей не нужен.
		if ! uci -q get "zeroblock.$sec" >/dev/null 2>&1; then
			info "$sec — секции нет, пропускаю"
			continue
		fi

		TMP="/tmp/zb-upd-$sec.$$"
		: >"$TMP"
		FAILED=0

		for g in $(groups_for "$sec"); do
			fetch_to "$URL_FOREIGN/?format=text&data=domains&group=$g" "$TMP" || FAILED=1
			fetch_to "$URL_FOREIGN/?format=text&data=cidr4&group=$g"   "$TMP" || FAILED=1
		done

		if [ "$FAILED" = "1" ]; then
			rm -f "$TMP"
			warn "$sec: часть групп не скачалась, список оставлен прежним"
			continue
		fi

		# HTML вместо списка — верный признак, что отдали страницу с ошибкой.
		if grep -qiE "<html|<!doctype" "$TMP"; then
			rm -f "$TMP"
			warn "$sec: в ответе HTML вместо списка, список оставлен прежним"
			continue
		fi

		sort -u "$TMP" | grep -vE '^\s*$' >"$TMP.clean"
		mv -f "$TMP.clean" "$TMP"

		NEW=$(lines "$TMP")
		OLD=$(lines "$LIST_DIR/zb-$sec.lst")

		if [ "$NEW" -lt 10 ]; then
			rm -f "$TMP"
			warn "$sec: пришло всего $NEW строк, это не похоже на список"
			continue
		fi
		if [ "$OLD" -gt 0 ] && [ "$((NEW * 100 / OLD))" -lt "$SHRINK_GUARD_PCT" ]; then
			rm -f "$TMP"
			warn "$sec: было $OLD строк, пришло $NEW — слишком резкое сжатие, не применяю"
			continue
		fi

		mkdir -p "$LIST_DIR"
		if [ "$NEW" = "$OLD" ] && cmp -s "$TMP" "$LIST_DIR/zb-$sec.lst"; then
			rm -f "$TMP"
			info "$sec: без изменений ($NEW строк)"
			continue
		fi

		mv -f "$TMP" "$LIST_DIR/zb-$sec.lst"
		ok "$sec: $OLD → $NEW строк"
		CHANGED=1
	done
}

# ------------------------------------------------------------- ИСКЛЮЧЕНИЯ --

update_excludes() {
	TD="/tmp/zb-upd-exdom.$$"; TI="/tmp/zb-upd-exip.$$"
	: >"$TD"; : >"$TI"

	fetch_to "$URL_RU/?format=text&data=domains" "$TD" || { rm -f "$TD" "$TI"; warn "исключения: домены не скачались"; return 0; }
	fetch_to "$URL_RU/?format=text&data=cidr4"   "$TI" || { rm -f "$TD" "$TI"; warn "исключения: подсети не скачались"; return 0; }

	if grep -qiE "<html|<!doctype" "$TD" "$TI"; then
		rm -f "$TD" "$TI"; warn "исключения: в ответе HTML, оставляю прежние"; return 0
	fi

	ND=$(lines "$TD"); NI=$(lines "$TI")
	OD=$(uci -q get zeroblock.engine.excluded_domains_text 2>/dev/null | wc -w)
	OI=$(uci -q get zeroblock.engine.excluded_ips_text 2>/dev/null | wc -w)

	if [ "$ND" -lt 10 ] || [ "$NI" -lt 5 ]; then
		rm -f "$TD" "$TI"; warn "исключения: подозрительно мало ($ND доменов, $NI сетей), не применяю"; return 0
	fi
	if [ "$OD" -gt 0 ] && [ "$((ND * 100 / OD))" -lt "$SHRINK_GUARD_PCT" ]; then
		rm -f "$TD" "$TI"; warn "исключения: было $OD доменов, пришло $ND — не применяю"; return 0
	fi

	if [ "$ND" = "$OD" ] && [ "$NI" = "$OI" ]; then
		rm -f "$TD" "$TI"; info "исключения: без изменений ($OD доменов, $OI сетей)"; return 0
	fi

	uci -q delete zeroblock.engine.excluded_domains_text 2>/dev/null
	while IFS= read -r l; do
		l=$(printf '%s' "$l" | tr -d '\r')
		case "$l" in ''|\#*) continue ;; esac
		uci add_list "zeroblock.engine.excluded_domains_text=$l"
	done <"$TD"

	uci -q delete zeroblock.engine.excluded_ips_text 2>/dev/null
	while IFS= read -r l; do
		l=$(printf '%s' "$l" | tr -d '\r')
		case "$l" in ''|\#*) continue ;; esac
		uci add_list "zeroblock.engine.excluded_ips_text=$l"
	done <"$TI"

	uci commit zeroblock
	rm -f "$TD" "$TI"
	ok "исключения: $OD → $ND доменов, $OI → $NI сетей"
	CHANGED=1
}

# ----------------------------------------------------------------- РЕЖИМЫ --

do_update() {
	[ "$(id -u)" = "0" ] || die "нужны права root"
	command -v curl >/dev/null 2>&1 || die "нужен curl"
	command -v uci  >/dev/null 2>&1 || die "нужен uci"
	[ -f /etc/init.d/zeroblock ] || die "ZeroBlock не установлен"

	say ""
	say "${C_CYN}  Обновление списков ZeroBlock из iplist${C_OFF}"
	say "${C_DIM}  $(date)${C_OFF}"
	say ""

	CHANGED=0
	update_sections
	update_excludes

	if [ "$CHANGED" = "1" ]; then
		info "применяю"
		/etc/init.d/zeroblock reload >/dev/null 2>&1
		ok "ZeroBlock перечитал конфигурацию"
	else
		info "менять нечего, перезагрузка не нужна"
	fi

	date +"%Y-%m-%d %H:%M:%S" >"$STAMP" 2>/dev/null
	say ""
}

do_install() {
	[ "$(id -u)" = "0" ] || die "нужны права root"
	SRC=$(readlink -f "$0" 2>/dev/null || echo "$0")
	if [ "$SRC" != "$SELF_PATH" ]; then
		cp "$SRC" "$SELF_PATH" || die "не смог скопировать в $SELF_PATH"
		chmod +x "$SELF_PATH"
		ok "скрипт установлен: $SELF_PATH"
	fi

	crontab -l 2>/dev/null | grep -v "zeroblock-lists-update" >/tmp/zb-cron.$$
	echo "$CRON_LINE" >>/tmp/zb-cron.$$
	crontab /tmp/zb-cron.$$ && rm -f /tmp/zb-cron.$$
	/etc/init.d/cron enable >/dev/null 2>&1
	/etc/init.d/cron restart >/dev/null 2>&1

	ok "расписание: каждый понедельник в 5:00"
	info "проверить: crontab -l"
	info "запустить вручную: $SELF_PATH"
	info "убрать: $SELF_PATH --remove"
}

do_remove() {
	[ "$(id -u)" = "0" ] || die "нужны права root"
	crontab -l 2>/dev/null | grep -v "zeroblock-lists-update" >/tmp/zb-cron.$$
	crontab /tmp/zb-cron.$$ && rm -f /tmp/zb-cron.$$
	/etc/init.d/cron restart >/dev/null 2>&1
	ok "убрано из расписания"
	info "сам скрипт остался: $SELF_PATH"
}

do_status() {
	say ""
	if [ -f "$STAMP" ]; then
		info "последнее обновление: $(cat "$STAMP")"
	else
		info "ещё ни разу не обновлялись"
	fi
	for sec in awg10 MESSENGERS opera; do
		f="$LIST_DIR/zb-$sec.lst"
		[ -f "$f" ] && info "$sec: $(lines "$f") строк"
	done
	info "исключения: $(uci -q get zeroblock.engine.excluded_domains_text 2>/dev/null | wc -w) доменов, $(uci -q get zeroblock.engine.excluded_ips_text 2>/dev/null | wc -w) сетей"
	if crontab -l 2>/dev/null | grep -q "zeroblock-lists-update"; then
		info "расписание: $(crontab -l 2>/dev/null | grep zeroblock-lists-update)"
	else
		info "расписание: не настроено"
	fi
	say ""
}

case "${1:-}" in
	--install) do_install ;;
	--remove)  do_remove ;;
	--status)  do_status ;;
	--quiet|"") do_update ;;
	*) die "неизвестный аргумент: $1 (доступны: --install, --remove, --status)" ;;
esac

exit 0
