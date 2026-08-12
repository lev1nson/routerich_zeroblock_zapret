#!/usr/bin/env python3
"""
Собирает списки для ZeroBlock из JSON формата podkop/getIPList.

На вход:
  lists/src/ip-list.json            — зарубежные ресурсы (идут через прокси/VPN)
  lists/src/ip-list-ru-internal.json — российские ресурсы (идут напрямую)

На выход:
  lists/zb-awg10.lst        — mixed-список для секции awg10 (VPN)
  lists/zb-MESSENGERS.lst   — mixed-список для секции MESSENGERS
  lists/zb-opera.lst        — mixed-список для секции opera (proxy)
  lists/exclude-domains.txt — глобальные исключения по доменам
  lists/exclude-ips.txt     — глобальные исключения по подсетям

Сервисы раскладываются по секциям в соответствии с тем, какой секции
принадлежит одноимённый community-список ZeroBlock.

Запуск:
    python3 tools/build-lists.py
    python3 tools/build-lists.py --src-dir lists/src --out-dir lists
"""

import argparse
import ipaddress
import json
import sys
from pathlib import Path

# Раскладка групп по секциям ZeroBlock.
# Ключ — имя секции, значение — группы из поля "group" исходного JSON.
SECTION_GROUPS = {
    "awg10": {
        "anime", "block", "discord", "googleplay", "torrent", "youtube", "cdn",
        "porn",
    },
    "MESSENGERS": {
        "messengers", "meta",
    },
    "opera": {
        "video", "art", "geoblock", "games", "music", "shop",
        "socials", "news", "repo", "ai", "tools",
    },
}


def load(path: Path) -> dict:
    if not path.is_file():
        sys.exit(f"ОШИБКА: не найден {path}")
    with path.open(encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        sys.exit(f"ОШИБКА: {path} — ожидался объект верхнего уровня")
    return data


def collect(entries, ipv6=False):
    """Возвращает (домены, сети, одиночные IP не покрытые сетями)."""
    domains, nets, hosts = set(), set(), set()

    for entry in entries:
        for dom in entry.get("domains", []):
            dom = dom.strip().lower().lstrip(".")
            # отсекаем мусор: пустые строки и записи без точки (голые TLD
            # превратились бы в domain_suffix, матчащий всю зону)
            if dom and "." in dom and " " not in dom:
                domains.add(dom)

        cidr_keys = ["cidr4"] + (["cidr6"] if ipv6 else [])
        for key in cidr_keys:
            for cidr in entry.get(key, []):
                try:
                    nets.add(ipaddress.ip_network(cidr, strict=False))
                except ValueError:
                    pass

        ip_keys = ["ip4"] + (["ip6"] if ipv6 else [])
        for key in ip_keys:
            for addr in entry.get(key, []):
                try:
                    hosts.add(ipaddress.ip_address(addr))
                except ValueError:
                    pass

    # одиночные IP, уже покрытые сетями, в список не попадают
    extra = {h for h in hosts if not any(h in n for n in nets)}

    v4 = ipaddress.collapse_addresses(n for n in nets if n.version == 4)
    v6 = ipaddress.collapse_addresses(n for n in nets if n.version == 6)
    nets = set(v4) | set(v6)

    return domains, nets, extra


def sort_nets(nets):
    return sorted(nets, key=lambda n: (n.version, int(n.network_address), n.prefixlen))


def write_lines(path: Path, lines):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(lines)


def main():
    ap = argparse.ArgumentParser(description="Сборка списков ZeroBlock из JSON podkop/getIPList")
    ap.add_argument("--src-dir", default="lists/src", help="каталог с исходными JSON")
    ap.add_argument("--out-dir", default="lists", help="каталог для готовых списков")
    ap.add_argument("--ipv6", action="store_true", help="включить IPv6 (по умолчанию отброшен)")
    args = ap.parse_args()

    src, out = Path(args.src_dir), Path(args.out_dir)

    foreign = load(src / "ip-list.json")
    ru = load(src / "ip-list-ru-internal.json")

    known = set().union(*SECTION_GROUPS.values())
    present = {v.get("group") for v in foreign.values()}
    orphans = present - known
    if orphans:
        print(f"ВНИМАНИЕ: группы без секции, пропущены: {sorted(orphans)}")

    print(f"{'секция':<12}{'сервисов':>9}{'доменов':>9}{'сетей':>7}{'IP':>6}{'строк':>7}")
    for section, groups in SECTION_GROUPS.items():
        entries = [v for v in foreign.values() if v.get("group") in groups]
        domains, nets, extra = collect(entries, args.ipv6)
        lines = (
            sorted(domains)
            + [str(n) for n in sort_nets(nets)]
            + [f"{h}/32" if h.version == 4 else f"{h}/128" for h in sorted(extra)]
        )
        total = write_lines(out / f"zb-{section}.lst", lines)
        print(f"{section:<12}{len(entries):>9}{len(domains):>9}{len(nets):>7}{len(extra):>6}{total:>7}")

    domains, nets, extra = collect(ru.values(), args.ipv6)
    n_dom = write_lines(out / "exclude-domains.txt", sorted(domains))
    ip_lines = [str(n) for n in sort_nets(nets)] + [
        f"{h}/32" if h.version == 4 else f"{h}/128" for h in sorted(extra)
    ]
    n_ip = write_lines(out / "exclude-ips.txt", ip_lines)
    print(f"\nисключения: {len(ru)} сервисов, {n_dom} доменов, {n_ip} подсетей")
    print(f"готово → {out}/")


if __name__ == "__main__":
    main()
