#!/bin/sh
#
# Откат установки ZeroBlock + Zapret2
#
#   sh uninstall.sh              — мягкий откат: выключить ZeroBlock,
#                                  вернуть прежние схемы и DNS
#   sh uninstall.sh full         — полный откат из последнего бэкапа
#   sh uninstall.sh full <файл>  — полный откат из указанного бэкапа
#   sh uninstall.sh list         — показать доступные бэкапы
#   sh uninstall.sh purge        — мягкий откат + удаление пакетов ZeroBlock
#
# Полный откат делает sysupgrade -r и требует перезагрузки: он вернёт ВСЕ
# настройки роутера на момент бэкапа, не только то, что касается ZeroBlock.
#

set -u

BACKUP_ROOT="${ZB_BACKUP_DIR:-/root/zeroblock-migration}"
MODE="${1:-soft}"

if [ -t 1 ]; then
	C_OFF="\033[0m"; C_RED="\033[1;31m"; C_GRN="\033[0;32m"
	C_YEL="\033[0;33m"; C_CYN="\033[0;36m"; C_DIM="\033[2m"
else
	C_OFF=""; C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_DIM=""
fi

log()  { printf "%b\n" "$*"; }
step() { printf "\n%b\n" "${C_CYN}==> $*${C_OFF}"; }
ok()   { printf "%b\n" "  ${C_GRN}✓${C_OFF} $*"; }
info() { printf "%b\n" "  ${C_DIM}·${C_OFF} $*"; }
warn() { printf "%b\n" "  ${C_YEL}!${C_OFF} $*"; }
die()  { printf "%b\n" "  ${C_RED}✗ $*${C_OFF}"; exit 1; }

[ "$(id -u)" = "0" ] || die "нужны права root"

if command -v apk >/dev/null 2>&1 && apk --version >/dev/null 2>&1; then
	PKGM="apk"; PKG_RM="apk del"
else
	PKGM="opkg"; PKG_RM="opkg remove"
fi

# Все каталоги бэкапов, свежие первыми.
backup_dirs() { ls -1d "$BACKUP_ROOT"/*/ 2>/dev/null | sort -r; }

find_backups() {
	backup_dirs | while IFS= read -r d; do
		[ -f "$d/sysupgrade-config.tar.gz" ] && echo "$d/sysupgrade-config.tar.gz"
	done
}

# Самый свежий файл с указанным именем среди бэкапов.
latest_file() {
	backup_dirs | while IFS= read -r d; do
		[ -f "$d/$1" ] && { echo "$d/$1"; break; }
	done
}

soft_rollback() {
	step "Мягкий откат"

	for svc in zeroblock zapret2; do
		if [ -f "/etc/init.d/$svc" ]; then
			"/etc/init.d/$svc" stop    >/dev/null 2>&1
			"/etc/init.d/$svc" disable >/dev/null 2>&1
			ok "$svc остановлен и убран из автозапуска"
		fi
	done

	# DNS: берём самый СВЕЖИЙ бэкап, а не первый попавшийся.
	DHCP=$(latest_file dhcp.bak)
	if [ -n "$DHCP" ]; then
		cp "$DHCP" /etc/config/dhcp && ok "конфиг dnsmasq восстановлен из $DHCP"
	else
		ETC=$(latest_file etc-config.tar.gz)
		if [ -n "$ETC" ]; then
			tar xzf "$ETC" -C / etc/config/dhcp 2>/dev/null &&
				ok "конфиг dnsmasq восстановлен из $ETC" ||
				warn "не удалось восстановить dnsmasq, поправьте вручную"
		else
			warn "бэкап dnsmasq не найден — DNS останется как есть"
		fi
	fi
	/etc/init.d/dnsmasq restart >/dev/null 2>&1

	# Возвращаем ровно те службы, которые выключал install.sh.
	SVCLIST=$(latest_file disabled-services.txt)
	RESTORED=0
	if [ -n "$SVCLIST" ]; then
		while IFS= read -r svc || [ -n "$svc" ]; do
			[ -n "$svc" ] || continue
			[ -f "/etc/init.d/$svc" ] || continue
			"/etc/init.d/$svc" enable >/dev/null 2>&1
			"/etc/init.d/$svc" start  >/dev/null 2>&1
			ok "$svc включён обратно"
			RESTORED=$((RESTORED + 1))
		done <"$SVCLIST"
	fi

	if [ "$RESTORED" = "0" ]; then
		if [ -f /etc/init.d/podkop ]; then
			/etc/init.d/podkop enable >/dev/null 2>&1
			/etc/init.d/podkop start  >/dev/null 2>&1
			ok "podkop включён обратно"
		else
			info "список выключённых служб не найден и podkop не установлен"
			info "если у вас был passwall / openclash / xkeen — включите вручную"
		fi
	fi
}

case "$MODE" in

list)
	step "Доступные бэкапы в $BACKUP_ROOT"
	FOUND=$(backup_dirs)
	[ -n "$FOUND" ] || die "бэкапов не найдено"
	echo "$FOUND" | while IFS= read -r d; do
		if [ -f "$d/sysupgrade-config.tar.gz" ]; then
			printf "  %-8s %s\n" "$(ls -lh "$d/sysupgrade-config.tar.gz" | awk '{print $5}')" "$d"
		else
			printf "  %-8s %s %s\n" "—" "$d" "${C_YEL}(без sysupgrade-архива)${C_OFF}"
		fi
	done
	;;

soft)
	soft_rollback
	log ""
	ok "Готово. Пакеты ZeroBlock и Zapret2 остались в системе, но выключены."
	info "Удалить полностью:  sh uninstall.sh purge"
	info "Полный откат:       sh uninstall.sh full"
	;;

purge)
	soft_rollback
	step "Удаление пакетов"
	$PKG_RM luci-app-zeroblock zeroblock-tg zeroblock >/dev/null 2>&1 &&
		ok "пакеты ZeroBlock удалены ($PKGM)" ||
		warn "не удалось удалить пакеты, попробуйте вручную: $PKG_RM zeroblock"
	rm -rf /etc/zeroblock /etc/config/zeroblock 2>/dev/null
	ok "конфиги и списки удалены"
	info "zapret2 оставлен — он может использоваться сам по себе"
	;;

full)
	BACKUP="${2:-}"
	if [ -z "$BACKUP" ]; then
		BACKUP=$(find_backups | head -1)
		if [ -z "$BACKUP" ]; then
			ALT=$(latest_file etc-full.tar.gz)
			[ -n "$ALT" ] && {
				warn "sysupgrade-архива нет, но есть $ALT"
				warn "распакуйте вручную: tar xzf $ALT -C / && reboot"
			}
			die "полных бэкапов не найдено в $BACKUP_ROOT"
		fi
		info "выбран последний: $BACKUP"
	fi
	[ -f "$BACKUP" ] || die "файл не найден: $BACKUP"
	tar -tzf "$BACKUP" >/dev/null 2>&1 || die "архив повреждён: $BACKUP"

	step "Полный откат из $BACKUP"
	warn "будут восстановлены ВСЕ настройки роутера на момент бэкапа"

	if sysupgrade -r "$BACKUP"; then
		ok "конфигурация восстановлена"
		log ""
		log "  ${C_YEL}Нужна перезагрузка. Выполните:${C_OFF}  reboot"
	else
		die "sysupgrade -r завершился с ошибкой"
	fi
	;;

*)
	die "неизвестный режим: $MODE (доступны: soft, full, purge, list)"
	;;

esac

exit 0
