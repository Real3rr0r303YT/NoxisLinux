#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
# Noxis Linux – ein Boot-Versuch: bauen (optional), flashen, starten. Das Log
# des letzten Starts holt "--log" getrennt davon.
#
#   ./noxis-try.sh            flashen + starten (wartet nicht mehr)
#   ./noxis-try.sh --build    vorher initramfs + boot.img neu bauen
#   ./noxis-try.sh --restore  nur Stock wiederherstellen (Recovery erreichbar)
#   ./noxis-try.sh --log      Stock zurueck, Recovery, pstore-Log des letzten
#                             Starts holen und auswerten
#
# Frueher wartete der normale Aufruf 150 Sekunden auf ein USB-Interface und
# holte danach von sich aus das Log. Das normale Noxis bringt aber gar kein
# USB-Netz hoch – nur der Rescue tut das. Also landete jeder erfolgreiche
# Start im Fehlschlag-Zweig, und man musste zweieinhalb Minuten warten, nur um
# abzubrechen. Darum jetzt getrennt.
#
# Zwei Dinge, die dieses Gerät verlangt und die hart erarbeitet sind:
#
#  1. Die Ramdisk MUSS in init_boot. Der Bootloader ignoriert die Ramdisk im
#     boot.img, sobald eine init_boot-Partition existiert (getestet mit
#     rdinit=/noxis-init, Ergebnis: "VFS: Unable to mount root fs on
#     unknown-block(0,0)").
#
#  2. Nur das HAUPT-vbmeta darf mit --disable-verity --disable-verification
#     geflasht werden. Werden vbmeta_system und vbmeta_vendor mitentschaerft,
#     startet das Geraet ueberhaupt nicht mehr und faellt sofort in fastboot
#     zurueck -- auch mit Stock-Kernel und Stock-Recovery.
#
# Voraussetzungen: ~/NoxisLinux, Docker-Volume noxis-kernel,
# ~/noxis-backup/init_boot.orig.img und ein TWRP-Backup mit boot.emmc.win
# und vbmeta.emmc.win unterhalb von ~/noxis-backup.
set -u

REPO="$HOME/NoxisLinux"
BK="$HOME/noxis-backup"
OUT="$HOME/Desktop/noxis-linux"
CMDLINE="console=tty0 loglevel=7 selinux=0 panic=0 noxis.root=userdata noxis.debug=0"

c()    { printf '\033[1;36m[noxis]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ !!! ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*"; exit 1; }
ask()  { printf '\033[1;35m[ DU  ]\033[0m %s\n' "$*"; }

[ -d "$REPO" ] || die "$REPO nicht gefunden"
command -v fastboot >/dev/null || die "fastboot fehlt"
command -v adb      >/dev/null || die "adb fehlt"

# Stock-Images aus dem TWRP-Backup finden
STOCK=$(find "$BK" -name boot.emmc.win -printf '%h\n' 2>/dev/null | head -n1)
[ -n "$STOCK" ] || die "kein TWRP-Backup mit boot.emmc.win unter $BK"
[ -f "$STOCK/vbmeta.emmc.win" ] || die "vbmeta.emmc.win fehlt in $STOCK"
[ -f "$BK/init_boot.orig.img" ] || die "$BK/init_boot.orig.img fehlt"

# Virtuelle Interfaces ausblenden: Docker legt beim Bauen veth-Paare an.
ifsnap() {
  ip -o link | awk -F': ' '{print $2}' | sed 's/@.*//' \
    | grep -vE '^(lo|veth|docker|br-|virbr|vnet|tap|tun|wg|bond|dummy)' | sort
}

wait_fastboot() {
  fastboot devices 2>/dev/null | grep -q fastboot && return 0
  # Ist das Handy per adb erreichbar (Recovery), geht es ohne Tasten: im
  # Bootloader-Menue wechselt "Leiser" die Auswahl und "Power" bestaetigt --
  # wer die Tasten zu lange haelt, landet sonst in der Recovery.
  if adb devices 2>/dev/null | grep -qE 'recovery$|device$'; then
    c "Handy ist per adb da – schicke es selbst in den Bootloader"
    adb reboot bootloader >/dev/null 2>&1
  else
    ask "${1:-Handy in den Bootloader: Power lang druecken bis es ausgeht, dann Power + Leiser halten.}"
    ask "Tasten LOSLASSEN, sobald der Bootloader-Bildschirm kommt (sonst waehlt er Recovery)."
  fi
  local i=0
  until fastboot devices 2>/dev/null | grep -q fastboot; do
    sleep 1; i=$((i + 1))
    [ "$i" -ge 240 ] && die "kein Geraet im Bootloader nach 4 Minuten"
    [ $((i % 15)) -eq 0 ] && c "warte auf den Bootloader … (${i}s)"
  done
  ok "Bootloader da"
}

wait_adb() {
  local i=0
  until adb devices 2>/dev/null | grep -qE 'recovery|device$'; do
    sleep 1; i=$((i + 1))
    [ "$i" -ge 240 ] && die "kein adb-Geraet nach 4 Minuten"
    [ $((i % 15)) -eq 0 ] && c "warte auf adb … (${i}s)"
  done
  ok "adb da"
}

# Stock-Zustand: Recovery erreichbar, Android-Boot-Kette unveraendert.
restore_stock() {
  wait_fastboot
  c "Stock vbmeta, boot und init_boot zurueck"
  c "Stock-Quelle: $STOCK"
  # Ausgabe sichtbar lassen: welcher Slot geschrieben wird, steht nur dort.
  fastboot flash vbmeta    "$STOCK/vbmeta.emmc.win" 2>&1 | grep -E "Sending|Writing|FAILED|error" || true
  fastboot flash boot      "$STOCK/boot.emmc.win"   2>&1 | grep -E "Sending|Writing|FAILED|error" || true
  fastboot flash init_boot "$BK/init_boot.orig.img" 2>&1 | grep -E "Sending|Writing|FAILED|error" || true
  fastboot set_active a 2>&1 | grep -E "Setting|FAILED" || true
  ok "Stock wiederhergestellt"
}

# ----------------------------------------------------------- Log holen
# Erreichbar als "--log" (siehe oben) – holt den Konsolenpuffer des letzten
# Starts aus dem pstore. Der ueberlebt genau EINEN Neustart: zwischen dem
# schwarzen Bildschirm und diesem Aufruf darf nichts anderes dazwischen booten.
cmd_log() {
restore_stock
c "Recovery starten"
fastboot reboot recovery >/dev/null 2>&1
ask "Falls die Recovery nach dem Entschluesselungs-Passwort fragt: abbrechen."
wait_adb

log="$BK/noxis-$(date +%H%M%S).log"
adb shell 'cat /sys/fs/pstore/console-ramoops-0' > "$log" 2>/dev/null
[ -s "$log" ] || die "pstore leer"

kv=$(grep -am1 "Linux version" "$log" | sed 's/.*Linux version \([^ ]*\).*/\1/')
echo; c "Kernel im Log: $kv"
case "$kv" in
  *android14*) warn "Stock-Kernel – falscher Durchlauf erwischt. Zwischen Fehlschlag und Recovery darf nur EIN Boot liegen." ;;
esac
echo; c "=== noxis-init ==="
grep -an "noxis-init:" "$log" | tail -20
echo; c "=== Display / DRM ==="
grep -anE "msm_drm|sde_|dsi|panel|drm" "$log" | tail -15
echo; c "=== USB / dwc3 ==="
grep -anE "dwc3|UDC|hsphy" "$log" | tail -10
echo; c "=== Panic / Fehler ==="
grep -anE "Kernel panic|not syncing|Unable to mount|Unknown symbol" "$log" | tail -10
echo; ok "Vollstaendiges Log: $log"
}

if [ "${1:-}" = "--log" ]; then
  cmd_log
  exit 0
fi

if [ "${1:-}" = "--restore" ]; then
  restore_stock
  c "Recovery starten"
  fastboot reboot recovery 2>&1 | grep -E "Rebooting|FAILED" || true
  exit 0
fi

# ---------------------------------------------------------------- bauen
if [ "${1:-}" = "--build" ]; then
  c "Repo aktualisieren"
  git -C "$REPO" pull --ff-only || die "git pull fehlgeschlagen"
  c "initramfs + boot.img bauen"
  sudo docker run --rm \
    -v "$REPO:/noxis:ro" -v "$OUT:/out" -v "noxis-kernel:/kwork" \
    -e NOXIS_KWORK=/kwork -e NOXIS_KOUT=/out -e NOXIS_CMDLINE="$CMDLINE" \
    debian:trixie bash -c '
      set -e
      apt-get update -q
      apt-get install -y -q --no-install-recommends make cpio kmod mkbootimg \
        dpkg-dev ca-certificates lz4 python3 >/dev/null
      /noxis/kernel/build-noxis-kernel.sh initramfs
      /noxis/kernel/build-noxis-kernel.sh bootimg' || die "Build fehlgeschlagen"
fi

# ------------------------------------------------------------- Images bauen
c "Images zusammenstellen"
cd "$BK" || die "$BK nicht gefunden"
sudo docker run --rm -v noxis-kernel:/k -v "$BK":/out alpine \
  cp /k/initramfs.cpio.lz4 /out/ || die "initramfs.cpio.lz4 nicht im Volume"
sudo cp "$OUT/boot.img" boot.noxis.img || die "$OUT/boot.img fehlt"
sudo chown "$USER" initramfs.cpio.lz4 boot.noxis.img
python3 "$REPO/kernel/tools/mkinitboot.py" \
  "$BK/init_boot.orig.img" initramfs.cpio.lz4 init_boot.noxis.img || die "mkinitboot fehlgeschlagen"

sz=$(stat -c %s init_boot.noxis.img)
[ "$sz" -le 8388608 ] || die "init_boot.noxis.img ist $sz Bytes, Partition hat 8388608 – Module aus dem Initramfs nehmen"
ok "init_boot $((sz / 1024)) KB (noch $(( (8388608 - sz) / 1024 )) KB frei), boot $(( $(stat -c %s boot.noxis.img) / 1024 )) KB"

# ------------------------------------------------------------------ starten
if adb devices 2>/dev/null | grep -qE 'recovery|device$'; then
  adb reboot bootloader >/dev/null 2>&1; sleep 3
fi
wait_fastboot

before=$(ifsnap)

c "vbmeta entschaerfen (nur das Haupt-vbmeta)"
fastboot --disable-verity --disable-verification flash vbmeta "$STOCK/vbmeta.emmc.win" >/dev/null 2>&1 \
  || die "flash vbmeta fehlgeschlagen"
c "Noxis boot + init_boot flashen"
fastboot flash boot      boot.noxis.img      >/dev/null 2>&1 || die "flash boot fehlgeschlagen"
fastboot flash init_boot init_boot.noxis.img >/dev/null 2>&1 || die "flash init_boot fehlgeschlagen"
fastboot set_active a >/dev/null 2>&1
c "starten"
# Auf diesem Geraet kommt Noxis nach einem einfachen "fastboot reboot" nicht
# hoch, nach "fastboot reboot recovery" schon. Der Grund steht im Bootlog:
# /proc/bootconfig liefert nichts, androidboot.force_normal_boot ist leer.
# "recovery" ist hier also der normale Startweg und bedeutet keinen Rescue.
fastboot reboot recovery >/dev/null 2>&1
ok "gestartet – schau aufs Display. Ich warte 150 Sekunden auf ein Netzwerk-Interface."

# Frueher wurde hier 150 Sekunden auf ein USB-Interface gewartet und bei
# Ausbleiben automatisch das Log geholt. Das passte nur zum Rescue: das
# normale Noxis bringt von sich aus kein USB-Netz hoch, also landete jeder
# erfolgreiche Start im Fehlschlag-Zweig – und man musste 150 Sekunden
# warten, um das abzubrechen. Jetzt nur noch ein kurzer Blick, ob der Rescue
# antwortet; danach ist Schluss. Das Log holt "--log" gezielt.
iface=""
for i in $(seq 1 12); do
  sleep 1
  new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$(ifsnap)") | head -n1)
  [ -n "$new" ] && { iface="$new"; break; }
done

if [ -n "$iface" ]; then
  ok "Interface $iface aufgetaucht (Rescue oder noxis-usbnet)"
  sudo ip link set "$iface" up
  sudo ip addr add 172.16.42.2/24 dev "$iface" 2>/dev/null
  sleep 2
  ping -c2 -W2 172.16.42.1 >/dev/null 2>&1 && ok "Handy antwortet auf 172.16.42.1" || warn "kein Ping"
  echo; c "Shell ins laufende Noxis:  kernel/tools/noxis-shell.sh"
  c "Shell im Rescue:           kernel/tools/noxis-rescue.sh"
  exit 0
fi

echo
ok "Geflasht und gestartet – schau aufs Display."
c "Der erste Start dauert ein bis drei Minuten (resize2fs + systemd)."
echo
c "Bleibt der Bildschirm schwarz, das Log des Starts holen:"
c "    kernel/tools/noxis-try.sh --log"
c "Laeuft Noxis und noxis-usbnet ist eingerichtet:"
c "    kernel/tools/noxis-shell.sh"
exit 0
