#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
#
# Noxis Rescue vom PC aus (Handy per USB, im Rescue-Modus).
#
#   noxis-rescue.sh info               Slot, Akku, Partitionen, Platz
#   noxis-rescue.sh logs               Noxis-Logs holen (~/noxis-backup/rescue-logs-*)
#   noxis-rescue.sh backup [datei]     komplettes Noxis als tar.gz sichern
#   noxis-rescue.sh restore <datei>    Backup zurueckspielen (loescht das jetzige Noxis)
#   noxis-rescue.sh stock              Nothing-Bootkette zurueck + Stock-Recovery starten
#   noxis-rescue.sh reboot             normal neu starten (Noxis)
#   noxis-rescue.sh recovery|bootloader|poweroff
#   noxis-rescue.sh shell              Telnet-Shell
#
# Rescue starten: in Noxis die App "Noxis Rescue", oder es startet von selbst,
# wenn das Rootfs nicht hochkommt. Braucht nur bash (/dev/tcp), kein nc.
set -euo pipefail

IP=172.16.42.1
PORT=4242
BK="$HOME/noxis-backup"; mkdir -p "$BK"

c()   { printf '\033[1;36m[rescue]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; exit 1; }

reach() { timeout 2 bash -c "exec 3<>/dev/tcp/$IP/$PORT" 2>/dev/null; }

connect_usb() {
  reach && return 0
  c "suche das USB-Netz des Handys …"
  local i n drv
  for i in $(seq 1 60); do
    for n in $(ls /sys/class/net); do
      drv=$(basename "$(readlink -f "/sys/class/net/$n/device/driver" 2>/dev/null)" 2>/dev/null || true)
      case "$drv" in cdc_ncm|rndis_host|cdc_ether) ;; *) continue ;; esac
      ip -4 addr show "$n" | grep -q 172.16.42.2 && continue
      sudo ip link set "$n" up
      sudo ip addr add 172.16.42.2/24 dev "$n" 2>/dev/null || true
    done
    reach && { ok "Rescue erreichbar ($IP)"; return 0; }
    sleep 1
  done
  die "kein Rescue auf $IP – Handy per USB anstecken und in Noxis die App \"Noxis Rescue\" starten"
}

# Der Dienst nimmt eine Verbindung nach der anderen an. Laeuft noch ein
# Befehl (z. B. dd beim Flashen), wartet das hier, bis er wieder frei ist.
open3() {
  local i
  for i in $(seq 1 300); do
    exec 3<>"/dev/tcp/$IP/$PORT" 2>/dev/null && return 0
    sleep 1
  done
  die "Rescue antwortet nicht mehr"
}

# ein Befehl, Antwort auf stdout
cmd() {
  open3
  printf '%s\n' "$*" >&3
  cat <&3
  exec 3<&-
}

# ein Befehl, Daten aus Datei hinterher (Upload). Die Antwort kommt nach dem Ende.
upload() {  # $1 = Befehl, $2 = Datei
  open3
  { printf '%s\n' "$1"; cat "$2"; } >&3
  exec 3>&-
  sleep 2
  open3; exec 3>&-   # erst weiter, wenn der Dienst wieder frei ist (Schreiben fertig)
}

connect_usb
case "${1:-info}" in
  info) cmd info ;;
  logs)
    d="$BK/rescue-logs-$(date +%m%d-%H%M)"; mkdir -p "$d"
    cmd logs | tar -xzf - -C "$d" && ok "Logs in $d"
    ;;
  backup)
    f="${2:-$BK/noxis-backup-$(date +%Y%m%d-%H%M).tar.gz}"
    c "sichere Noxis nach $f (dauert je nach Groesse einige Minuten) …"
    cmd backup > "$f"
    gzip -t "$f" 2>/dev/null || die "Backup beschaedigt: $f"
    ok "Backup fertig: $f ($(du -h "$f" | cut -f1))"
    ;;
  restore)
    f="${2:-}"; [ -f "$f" ] || die "Datei fehlt: noxis-rescue.sh restore <backup.tar.gz>"
    gzip -t "$f" 2>/dev/null || die "$f ist kein gueltiges Backup"
    c "Das LOESCHT das jetzige Noxis auf dem Handy und spielt $f zurueck. Weiter? [j/N]"
    read -r a; [ "$a" = j ] || die "abgebrochen"
    upload "restore JA" "$f"
    cmd info | head -3
    ok "zurueckgespielt – Neustart mit: noxis-rescue.sh reboot"
    ;;
  stock)
    S=$(find "$BK" -name boot.emmc.win -printf '%h\n' 2>/dev/null | head -n1)
    [ -n "$S" ] && [ -f "$S/vbmeta.emmc.win" ] && [ -f "$BK/init_boot.orig.img" ] \
      || die "Stock-Backup fehlt (boot.emmc.win, vbmeta.emmc.win, init_boot.orig.img in $BK)"
    c "spiele die Nothing-Bootkette zurueck (Quelle: $S)"
    upload "flash vbmeta"    "$S/vbmeta.emmc.win"
    upload "flash boot_a"    "$S/boot.emmc.win"
    upload "flash init_boot" "$BK/init_boot.orig.img"
    ok "Stock zurueck – starte die Stock-Recovery"
    cmd reboot-recovery || true
    ;;
  reboot)     cmd reboot || true ;;
  recovery)   cmd reboot-recovery || true ;;
  bootloader) cmd reboot-bootloader || true ;;
  poweroff)   cmd poweroff || true ;;
  shell)
    command -v telnet >/dev/null || die "telnet fehlt (Gentoo: emerge net-misc/inetutils)"
    telnet "$IP"
    ;;
  *) sed -n '6,17p' "$0" ;;
esac
