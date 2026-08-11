#!/bin/sh
#
# Откат установки ZeroBlock + Zapret2
#
#   sh uninstall.sh              — мягкий откат: выключить ZeroBlock,
#                                  вернуть podkop, оставить пакеты на месте
#   sh uninstall.sh full         — полный откат из последнего бэкапа
#   sh uninstall.sh full <файл>  — полный откат из указанного бэкапа
#   sh uninstall.sh list         — показать доступные бэкапы
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

find_backups() {
	find "$BACKUP_ROOT" -name "sysupgrade-config.tar.gz" -type f 2>/dev/null | sort -r
}

case "$MODE" in

list)
	step "Доступные бэкапы в $BACKUP_ROOT"
	FOUND=$(find_backups)
	[ -n "$FOUND" ] || die "бэкапов не найдено"
	echo "$FOUND" | while IFS= read -r b; do
		printf "  %s  %s\n" "$(ls -lh "$b" | awk '{print $5}')" "$b"
	done
	;;

soft)
	step "Мягкий откат"

	for svc in zeroblock zapret2; do
		if [ -f "/etc/init.d/$svc" ]; then
			"/etc/init.d/$svc" stop    >/dev/null 2>&1
			"/etc/init.d/$svc" disable >/dev/null 2>&1
			ok "$svc остановлен и убран из автозапуска"
		fi
	done

	RESTORED=0
	for f in "$BACKUP_ROOT"/*/dhcp.bak "$BACKUP_ROOT"/*/etc-config.tar.gz; do
		[ -e "$f" ] || continue
		case "$f" in
			*dhcp.bak)
				cp "$f" /etc/config/dhcp && RESTORED=1 && ok "конфиг dnsmasq восстановлен из $f"
				break
				;;
		esac
	done
	if [ "$RESTORED" = "0" ]; then
		LATEST=$(find "$BACKUP_ROOT" -name "etc-config.tar.gz" -type f 2>/dev/null | sort -r | head -1)
		if [ -n "$LATEST" ]; then
			tar xzf "$LATEST" -C / etc/config/dhcp 2>/dev/null &&
				ok "конфиг dnsmasq восстановлен из $LATEST" ||
				warn "не удалось восстановить dnsmasq, поправьте вручную"
		else
			warn "бэкап dnsmasq не найден — DNS останется как есть"
		fi
	fi
	/etc/init.d/dnsmasq restart >/dev/null 2>&1

	if [ -f /etc/init.d/podkop ]; then
		/etc/init.d/podkop enable >/dev/null 2>&1
		/etc/init.d/podkop start  >/dev/null 2>&1
		ok "podkop включён обратно"
	else
		info "podkop не установлен, включать нечего"
	fi

	log ""
	ok "Готово. Пакеты ZeroBlock и Zapret2 остались в системе, но выключены."
	info "Удалить полностью:  opkg remove luci-app-zeroblock zeroblock"
	info "Полный откат:       sh uninstall.sh full"
	;;

full)
	BACKUP="${2:-}"
	if [ -z "$BACKUP" ]; then
		BACKUP=$(find_backups | head -1)
		[ -n "$BACKUP" ] || die "бэкапов не найдено в $BACKUP_ROOT"
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
	die "неизвестный режим: $MODE (доступны: soft, full, list)"
	;;

esac

exit 0
