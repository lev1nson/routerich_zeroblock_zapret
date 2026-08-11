#!/bin/sh
#
# Обновление списков из проекта rekryt/iplist.
#
# Скачивает свежие выгрузки и пересобирает lists/*.lst конвертером.
# Запускать на своей машине, не на роутере: результат коммитится в репозиторий.
#
#   sh tools/fetch-lists.sh
#
# Источники (оба — инстансы https://github.com/rekryt/iplist):
#   iplist.my-handbook.ru     — зарубежные ресурсы, идут через VPN и прокси
#   ru-iplist.my-handbook.ru  — российские, идут напрямую мимо прокси
#

set -u

ROOT=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd) || ROOT="."
SRC="$ROOT/lists/src"

URL_FOREIGN="${ZB_URL_FOREIGN:-https://iplist.my-handbook.ru/?format=json}"
URL_RU="${ZB_URL_RU:-https://ru-iplist.my-handbook.ru/?format=json}"

if [ -t 1 ]; then
	C_OFF="\033[0m"; C_RED="\033[1;31m"; C_GRN="\033[0;32m"; C_DIM="\033[2m"
else
	C_OFF=""; C_RED=""; C_GRN=""; C_DIM=""
fi

ok()   { printf "%b\n" "  ${C_GRN}✓${C_OFF} $*"; }
info() { printf "%b\n" "  ${C_DIM}·${C_OFF} $*"; }
die()  { printf "%b\n" "  ${C_RED}✗ $*${C_OFF}"; exit 1; }

command -v curl >/dev/null 2>&1 || die "нужен curl"
command -v python3 >/dev/null 2>&1 || die "нужен python3"

mkdir -p "$SRC"

# Скачивает во временный файл и подменяет исходник только если пришёл
# валидный JSON — иначе полусохранённый ответ затрёт рабочие списки.
fetch() {
	_url="$1"; _dst="$2"; _label="$3"
	printf "%b" "  ${C_DIM}·${C_OFF} качаю $_label... "

	_tmp="$_dst.new"
	if ! curl -fsSL --max-time 180 -o "$_tmp" "$_url"; then
		rm -f "$_tmp"
		printf "%b\n" "${C_RED}не скачалось${C_OFF}"
		return 1
	fi

	if ! python3 -c "
import json, sys
d = json.load(open('$_tmp'))
if not isinstance(d, dict) or not d:
    sys.exit(1)
" 2>/dev/null; then
		rm -f "$_tmp"
		printf "%b\n" "${C_RED}пришёл не тот JSON${C_OFF}"
		return 1
	fi

	_n=$(python3 -c "import json; print(len(json.load(open('$_tmp'))))")
	_old=0
	[ -f "$_dst" ] && _old=$(python3 -c "import json; print(len(json.load(open('$_dst'))))" 2>/dev/null || echo 0)

	mv -f "$_tmp" "$_dst"
	if [ "$_old" -gt 0 ] && [ "$_n" != "$_old" ]; then
		printf "%b\n" "${C_GRN}$_n сервисов${C_OFF} (было $_old)"
	else
		printf "%b\n" "${C_GRN}$_n сервисов${C_OFF}"
	fi
}

printf "\n%b\n\n" "  Обновление списков из rekryt/iplist"

FAIL=0
fetch "$URL_FOREIGN" "$SRC/ip-list.json"           "зарубежные" || FAIL=1
fetch "$URL_RU"      "$SRC/ip-list-ru-internal.json" "российские" || FAIL=1

if [ "$FAIL" = "1" ]; then
	die "что-то не скачалось, списки не пересобираю — прежние остались нетронутыми"
fi

echo
info "пересобираю списки"
echo
python3 "$ROOT/tools/build-lists.py" --src-dir "$SRC" --out-dir "$ROOT/lists" || die "конвертер упал"

echo
ok "готово"
info "проверьте изменения: git diff --stat lists/"
info "и закоммитьте, если всё разумно"
