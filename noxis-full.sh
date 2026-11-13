#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
#
# Alles in einem Rutsch: Kernel, Rootfs (Container), Mesa, Firmware, Flashen.
#
#   ./noxis-full.sh            alles bauen und aufs Handy (fragt vor dem Loeschen)
#   ./noxis-full.sh --no-flash nur bauen
#
# Ergebnis auf dem Handy beim ersten Start: Einrichtung mit Sprache,
# Zeitzone, eigener PIN und WLAN. Danach Phosh mit Bildschirmtastatur.
#
# ACHTUNG: Flashen ueberschreibt userdata, also das installierte Noxis samt PIN.
# Firmware-Dateien vom Handy bleiben lokal und kommen nie ins Repo.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
FLASH=1
[ "${1:-}" = "--no-flash" ] && FLASH=0

BK="$HOME/noxis-backup"; mkdir -p "$BK"
LOG="$BK/full-$(date +%m%d-%H%M).txt"
exec > >(tee -a "$LOG") 2>&1

c()   { printf '\033[1;36m[noxis]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
ask() { printf '\033[1;33m[ DU ]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; echo "Log: $LOG"; exit 1; }
hdr() { printf '\n\033[1;35m==== %s ====\033[0m\n' "$*"; }

desktop_dir() {
  local d=""
  command -v xdg-user-dir >/dev/null 2>&1 && d=$(xdg-user-dir DESKTOP 2>/dev/null || true)
  { [ -n "$d" ] && [ "$d" != "$HOME" ]; } || d="$HOME/Desktop"
  echo "$d"
}
OUT="$(desktop_dir)/noxis-linux"; mkdir -p "$OUT/device"
START=$(date +%s)

# ------------------------------------------------------------------ 0 checks
hdr "0/5 Pruefen"
for t in docker adb fastboot python3 git; do
  command -v "$t" >/dev/null || die "$t fehlt"
done
[ -d "$HERE/.git" ] && { git -C "$HERE" pull --ff-only -q && ok "Repo aktuell" || c "git pull nicht moeglich – baue den lokalen Stand"; }
c "sudo einmal vorab (fuer Docker/binfmt)"
sudo -v || die "sudo fehlgeschlagen"
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
KEEP=$!
trap 'kill $KEEP 2>/dev/null || true' EXIT

# Docker ohne sudo? Sonst laufen die Bauschritte mit sudo -E.
if docker info >/dev/null 2>&1; then RUN=(); else RUN=(sudo -E); c "Docker braucht sudo – Bauschritte laufen mit sudo"; fi
"${RUN[@]}" docker info >/dev/null 2>&1 || die "Docker laeuft nicht (rc-service docker start)"

free_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc 0-9; }
h=$(free_gb "$HOME"); d=$(sudo df -BG --output=avail /var/lib/docker 2>/dev/null | tail -1 | tr -dc 0-9 || true)
c "frei: Home ${h:-?} GB, Docker ${d:-?} GB"
if [ -n "${d:-}" ] && [ "$d" -lt 35 ]; then
  ask "Docker hat nur ${d} GB frei – der Rootfs-Bau braucht etwa 35 GB. Trotzdem weiter? [j/N]"
  read -r a; [ "$a" = j ] || die "abgebrochen (Platz)"
fi

# ------------------------------------------------------------------ 1 firmware
hdr "1/5 Firmware (bleibt lokal)"
FW="${NOXIS_FIRMWARE:-}"
if [ -z "$FW" ] && ls "$OUT"/device/noxis-firmware-asteroids_*.deb >/dev/null 2>&1; then
  # der Kernel-Bau leert device/ -- Paket vorher sichern, danach zurueck
  mkdir -p "$BK/fw-deb"; cp -f "$OUT"/device/noxis-firmware-asteroids_*.deb "$BK/fw-deb/"
  ok "Firmware-Paket vom letzten Bau wird weiterverwendet"
elif [ -z "$FW" ] && [ -d "$BK/vendor-firmware" ] && [ -n "$(ls -A "$BK/vendor-firmware" 2>/dev/null)" ]; then
  FW="$BK/vendor-firmware"; ok "Firmware aus $FW"
elif [ -z "$FW" ]; then
  c "hole /vendor/firmware vom Handy (Recovery mit adb noetig)"
  if ! adb devices | grep -qE 'recovery$|device$'; then
    # Handy laeuft in Noxis oder ist aus: Stock-Bootkette zurueck, das startet die Recovery.
    c "Handy nicht per adb da – bringe es ueber den Bootloader in die Recovery"
    "$HERE/kernel/tools/noxis-try.sh" --restore || die "Recovery nicht erreicht"
    i=0
    until adb devices | grep -qE 'recovery$|device$'; do
      sleep 2; i=$((i + 2)); [ "$i" -ge 180 ] && die "Recovery meldet sich nicht per adb"
    done
    ok "Recovery da"
  fi
  # /vendor/firmware ist ein Zusatz (WLAN-Kalibrierung u. ae.). Modem, ADSP und
  # WLAN-Firmware kommen ohnehin zur Laufzeit von der modem-Partition.
  if adb shell 'mkdir -p /tmp/vnd; mount -o ro /dev/block/mapper/vendor_a /tmp/vnd 2>/dev/null || mount -o ro /dev/block/mapper/vendor /tmp/vnd 2>/dev/null; ls /tmp/vnd/firmware >/dev/null' \
     && mkdir -p "$BK/vendor-firmware" && adb pull /tmp/vnd/firmware/. "$BK/vendor-firmware/" >/dev/null; then
    FW="$BK/vendor-firmware"; ok "Firmware nach $FW ($(du -sh "$FW" | cut -f1))"
  else
    rmdir "$BK/vendor-firmware" 2>/dev/null || true
    c "/vendor/firmware nicht lesbar – baue ohne (Firmware kommt von der modem-Partition)"
  fi
  adb shell 'umount /tmp/vnd' >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------ 2 mesa
hdr "2/5 Mesa (GPU, Vulkan/turnip – experimentell)"
MESA="$HOME/Desktop/noxis-linux/mesa-kgsl.tar.gz"
if [ ! -f "$MESA" ] && [ ! -f "$OUT/mesa-kgsl.tar.gz" ]; then
  "$HERE/kernel/tools/build-mesa-kgsl.sh" || c "Mesa-Bau fehlgeschlagen – weiter ohne"
fi
[ -f "$MESA" ] && [ ! -f "$OUT/mesa-kgsl.tar.gz" ] && cp "$MESA" "$OUT/"
[ -f "$OUT/mesa-kgsl.tar.gz" ] && ok "Mesa liegt bereit" || c "ohne Mesa"

# ------------------------------------------------------------------ 3 kernel
hdr "3/5 Kernel + Initramfs + boot.img"
if [ -n "$FW" ]; then export NOXIS_FIRMWARE="$FW"; fi
"${RUN[@]}" "$HERE/build-noxis-linux.sh" kernel || die "Kernel-Bau fehlgeschlagen"
# Der Kernelbau laeuft im Docker als root und legt device/ neu an. Ohne das
# hier scheitert gleich das Zurueckkopieren mit "Permission denied".
sudo chown -R "$(id -u):$(id -g)" "$OUT" 2>/dev/null || true
if [ -z "$FW" ] && ls "$BK"/fw-deb/*.deb >/dev/null 2>&1; then
  cp -f "$BK"/fw-deb/*.deb "$OUT/device/" || die "Firmware-Paket nicht zurueckkopiert"
fi
for f in boot.img initramfs.cpio.lz4; do [ -f "$OUT/$f" ] || die "$OUT/$f fehlt nach dem Kernel-Bau"; done
ok "Kernel fertig"

# WLAN braucht die Konfigurationsdatei des Treibers im Rootfs. Sie liegt nur
# auf der vendor-Partition; noxis-diag.sh wlan spiegelt sie ins Backup, und
# von dort nimmt der Rootfs-Bau sie mit (samt sae_enabled=0).
if ls "$BK"/vendor-firmware/updates/wlan/qca_cld/*/WCNSS_qcom_cfg.ini >/dev/null 2>&1; then
  ok "WLAN-Konfiguration liegt im Backup und kommt ins Rootfs"
else
  ask "WCNSS_qcom_cfg.ini fehlt im Backup – das neue System haette KEIN WLAN."
  ask "Nach dem Flashen einmal:  kernel/tools/noxis-diag.sh wlan && kernel/tools/noxis-diag.sh nosae"
fi

# ------------------------------------------------------------------ 4 rootfs
hdr "4/5 Rootfs (Debian + Phosh + Noxis) – dauert lange"
NOXIS_LANG=ask "${RUN[@]}" "$HERE/build-noxis-linux.sh" container || die "Rootfs-Bau fehlgeschlagen"
[ -f "$OUT/rootfs-sparse.img" ] || die "rootfs-sparse.img fehlt"
ok "Rootfs fertig ($(du -h "$OUT/rootfs-sparse.img" | cut -f1))"
[ -n "${RUN[*]}" ] && sudo chown -R "$(id -u):$(id -g)" "$OUT" 2>/dev/null || true

if [ "$FLASH" = 0 ]; then
  ok "Gebaut in $(( ($(date +%s) - START) / 60 )) Minuten. Flashen spaeter: ./build-noxis-linux.sh flash"
  exit 0
fi

# ------------------------------------------------------------------ 5 flash
hdr "5/5 Aufs Handy"
ask "Das LOESCHT das installierte Noxis auf dem Handy (userdata) und spielt das neue auf."
ask "Handy in die Recovery bringen (oder Bootloader). Weiter? [j/N]"
read -r a; [ "$a" = j ] || { c "nicht geflasht. Spaeter: ./build-noxis-linux.sh flash"; exit 0; }
"$HERE/build-noxis-linux.sh" flash || die "Flashen fehlgeschlagen – Stock zurueck: kernel/tools/noxis-try.sh --restore"

echo
ok "Fertig nach $(( ($(date +%s) - START) / 60 )) Minuten."
c "Erster Start dauert 1–3 Minuten. Dann die Einrichtung:"
c "  Sprache → Zeitzone → eigene PIN (zweimal) → WLAN (optional) → Anmelden (Mobil)"
c "Internet gibt es erst mit verbundenem Mullvad (Killswitch). Zum Testen ohne VPN:"
c "  kernel/tools/noxis-diag.sh fw-aus     (zurueck: fw-an)"
c "Mobilfunk geht noch nicht. WLAN laeuft ueber WPA2."
c "Zurueck zu Nothing OS jederzeit: kernel/tools/noxis-try.sh --restore"
c "Log: $LOG"
