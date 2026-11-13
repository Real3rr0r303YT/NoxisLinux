#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# noxis-wlan-fix.sh – holt fehlende WLAN-Konfigs vom Handy (tote Symlinks)
# Made by 3rr0r303YT on TikTok
# Nutzung: ./noxis-wlan-fix.sh [rootfs.img]
set -euo pipefail

ROOTFS="${1:-$HOME/Desktop/noxis-linux/rootfs.img}"
DST="$HOME/noxis-backup/vendor-firmware"
ok()  { echo "[ ok ] $*"; }
err() { echo "[FAIL] $*" >&2; exit 1; }
c()   { echo "[noxis] $*"; }

# --- 1. Handy per adb prüfen (Recovery nötig) ---
c "Prüfe adb (Recovery muss aktiv sein)..."
adb wait-for-recovery 2>/dev/null &
sleep 5
kill %1 2>/dev/null || true
adb devices | grep -q "recovery" || err "Kein Gerät in Recovery – starte Recovery und versuch nochmal"

# --- 2. Symlink-Ziele auf dem Handy auflösen und Dateien holen ---
WLAN_PATHS=(
  "wlan/qca_cld/qca6750/WCNSS_qcom_cfg.ini"
  "wlan/qca_cld/qca6750/wlan_mac.bin"
  "wlan/qca_cld/wcn6450/WCNSS_qcom_cfg.ini"
  "wlan/qca_cld/wcn6450/wlan_mac.bin"
  "wlan/qca_cld/peach_v2/WCNSS_qcom_cfg.ini"
  "wlan/qca_cld/peach_v2/wlan_mac.bin"
  "wlanmdsp.otaupdate"
)

c "Montiere vendor-Partition..."
adb shell "mkdir -p /tmp/vnd2 && mount -o ro /dev/block/by-name/vendor_a /tmp/vnd2 2>/dev/null || mount -o ro /dev/block/by-name/vendor /tmp/vnd2 2>/dev/null || true"

FOUND=0
for REL in "${WLAN_PATHS[@]}"; do
  # Symlink-Ziel auflösen
  REAL=$(adb shell "readlink -f /tmp/vnd2/firmware/$REL 2>/dev/null || readlink -f /vendor/firmware/$REL 2>/dev/null || echo ''" | tr -d '\r')
  if [ -z "$REAL" ] || [ "$REAL" = "" ]; then
    echo "  skip (nicht gefunden): $REL"
    continue
  fi
  LDIR=$(dirname "$DST/$REL")
  mkdir -p "$LDIR"
  if adb pull "$REAL" "$DST/$REL" 2>/dev/null; then
    ok "geholt: $REL"
    FOUND=$((FOUND+1))
  else
    echo "  skip (pull fehlgeschlagen): $REL  (Quelle: $REAL)"
  fi
done

adb shell "umount /tmp/vnd2 2>/dev/null || true"

[ "$FOUND" -eq 0 ] && err "Keine WLAN-Dateien gefunden – prüfe ob Handy in Recovery ist"
ok "$FOUND WLAN-Datei(en) nach $DST"

# --- 3. Ins laufende Rootfs einspielen (falls angegeben und vorhanden) ---
if [ ! -f "$ROOTFS" ]; then
  c "Kein Rootfs angegeben/gefunden – Dateien liegen in $DST"
  c "Nach nächstem Build werden sie automatisch eingebunden."
  exit 0
fi

c "Spiele WLAN-Dateien ins Rootfs ein: $ROOTFS"
command -v guestfish >/dev/null 2>&1 || { c "guestfish fehlt – nur lokal gespeichert"; exit 0; }

INJECT=""
for REL in "${WLAN_PATHS[@]}"; do
  [ -f "$DST/$REL" ] || continue
  INJECT="$INJECT copy-in $DST/$REL /lib/firmware/$(dirname $REL)/\n"
done

if [ -n "$INJECT" ]; then
  guestfish -a "$ROOTFS" -m /dev/sda << GFISH
mkdir-p /lib/firmware/wlan/qca_cld/qca6750
mkdir-p /lib/firmware/wlan/qca_cld/wcn6450
mkdir-p /lib/firmware/wlan/qca_cld/peach_v2
$(printf "$INJECT")
GFISH
  ok "WLAN-Dateien ins Rootfs eingespielt"
else
  c "Keine Dateien zum Einspielen"
fi
