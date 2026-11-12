#!/usr/bin/env bash
# Noxis Linux – ein Durchlauf: bauen (optional), flashen, starten, Interface
# suchen, bei Fehlschlag das pstore-Log holen und auswerten.
#
#   ./noxis-try.sh            nur flashen + testen
#   ./noxis-try.sh --build    vorher initramfs + boot.img neu bauen
#
# Voraussetzungen: ~/NoxisLinux, ~/noxis-backup/init_boot.orig.img,
# Docker-Volume noxis-kernel.
set -u

REPO="$HOME/NoxisLinux"
BK="$HOME/noxis-backup"
OUT="$HOME/Desktop/noxis-linux"
CMDLINE="console=tty0 loglevel=7 selinux=0 panic=0 rdinit=/noxis-init noxis.root=userdata noxis.debug=1"

c()    { printf '\033[1;36m[noxis]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[  ok ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[ !!! ]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*"; exit 1; }
ask()  { printf '\033[1;35m[ DU  ]\033[0m %s\n' "$*"; }

[ -d "$REPO" ]                || die "$REPO nicht gefunden"
[ -f "$BK/init_boot.orig.img" ] || die "$BK/init_boot.orig.img fehlt – Original-init_boot sichern"
command -v fastboot >/dev/null || die "fastboot fehlt"
command -v adb      >/dev/null || die "adb fehlt"

# Interface-Namen ohne die virtuellen: Docker legt beim Bauen veth-Paare an,
# und die wurden sonst als "neues USB-Interface" gezaehlt. Das @peer-Suffix aus
# "ip -o link" faellt ebenfalls weg, sonst passt der Name nicht auf "ip addr".
ifsnap() {
  ip -o link | awk -F': ' '{print $2}' | sed 's/@.*//' \
    | grep -vE '^(lo|veth|docker|br-|virbr|vnet|tap|tun|wg|bond|dummy)' | sort
}

wait_fastboot() {  # $1 = Aufforderungstext
  if fastboot devices 2>/dev/null | grep -q fastboot; then return 0; fi
  ask "$1"
  local i=0
  until fastboot devices 2>/dev/null | grep -q fastboot; do
    sleep 1; i=$((i + 1))
    [ "$i" -ge 180 ] && die "kein Gerät im Bootloader nach 3 Minuten"
    [ $((i % 15)) -eq 0 ] && c "warte auf den Bootloader … (${i}s)"
  done
  ok "Bootloader da"
}

wait_adb() {
  local i=0
  until adb devices 2>/dev/null | grep -qE 'recovery|device$'; do
    sleep 1; i=$((i + 1))
    [ "$i" -ge 180 ] && die "kein adb-Gerät nach 3 Minuten"
    [ $((i % 15)) -eq 0 ] && c "warte auf adb … (${i}s)"
  done
  ok "adb da"
}

# ---------------------------------------------------------------- bauen
if [ "${1:-}" = "--build" ]; then
  c "Repo aktualisieren"
  git -C "$REPO" pull --ff-only || die "git pull fehlgeschlagen"
  c "initramfs + boot.img bauen (dauert ein bis zwei Minuten)"
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

# ------------------------------------------------------------- Images holen
c "Images zusammenstellen"
cd "$BK" || die "$BK nicht gefunden"
sudo docker run --rm -v noxis-kernel:/k -v "$BK":/out alpine \
  cp /k/initramfs.cpio.lz4 /out/ || die "initramfs.cpio.lz4 nicht im Volume"
sudo cp "$OUT/boot.img" boot.noxis.img || die "$OUT/boot.img fehlt"
sudo chown "$USER" initramfs.cpio.lz4 boot.noxis.img
python3 "$REPO/kernel/tools/mkinitboot.py" \
  init_boot.orig.img initramfs.cpio.lz4 init_boot.noxis.img || die "mkinitboot fehlgeschlagen"

sz=$(stat -c %s init_boot.noxis.img)
[ "$sz" -le 8388608 ] || die "init_boot.noxis.img ist $sz Bytes – Partition hat nur 8388608"
ok "init_boot.noxis.img $((sz / 1024)) KB, boot.noxis.img $(( $(stat -c %s boot.noxis.img) / 1024 )) KB"

# ------------------------------------------------------------------ starten
if adb devices 2>/dev/null | grep -qE 'recovery|device$'; then
  c "Gerät per adb in den Bootloader schicken"
  adb reboot bootloader >/dev/null 2>&1
  sleep 3
fi
wait_fastboot "Handy in den Bootloader bringen: Power lang drücken bis es ausgeht, dann Power + Leiser halten."

before=$(ifsnap)

# init_boot wird absichtlich NICHT geflasht: unser Init laeuft ueber
# rdinit=/noxis-init aus der Ramdisk im boot.img. Damit bleibt Androids
# init_boot unangetastet, ein normaler Boot kommt sauber hoch statt zu loopen,
# und der ramoops ueberlebt bis zur Recovery.
if [ "${NOXIS_FLASH_INITBOOT:-0}" = 1 ]; then
  c "init_boot flashen (NOXIS_FLASH_INITBOOT=1)"
  fastboot flash init_boot init_boot.noxis.img >/dev/null 2>&1 || die "flash init_boot fehlgeschlagen"
fi
c "boot.img in den RAM laden und starten"
fastboot boot boot.noxis.img >/dev/null 2>&1 || die "fastboot boot fehlgeschlagen"
ok "gestartet – suche bis zu 90 Sekunden nach einem USB-Interface"

iface=""
for i in $(seq 1 90); do
  sleep 1
  now=$(ifsnap)
  new=$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$now") | head -n1)
  if [ -n "$new" ]; then iface="$new"; break; fi
  [ $((i % 15)) -eq 0 ] && c "… noch nichts (${i}s)"
done

# ------------------------------------------------------------------ Erfolg
if [ -n "$iface" ]; then
  ok "Interface $iface aufgetaucht"
  sudo ip link set "$iface" up
  sudo ip addr add 172.16.42.2/24 dev "$iface" 2>/dev/null
  sleep 2
  if ping -c2 -W2 172.16.42.1 >/dev/null 2>&1; then
    ok "Handy antwortet auf 172.16.42.1"
  else
    warn "kein Ping – Telnet trotzdem versuchen"
  fi
  echo
  ok "NOXIS LINUX LÄUFT. Jetzt verbinden mit:"
  echo "    telnet 172.16.42.1"
  exit 0
fi

# ----------------------------------------------------------- Fehlschlag: Log
warn "kein Interface – ich hole das Log"
wait_fastboot "Power lang drücken bis es ausgeht, dann Power + Leiser halten."
[ "${NOXIS_FLASH_INITBOOT:-0}" = 1 ] && {
  c "Original-init_boot zurück"
  fastboot flash init_boot init_boot.orig.img >/dev/null 2>&1
}
c "Recovery starten"
fastboot reboot recovery >/dev/null 2>&1
ask "Falls die Recovery nach dem Entschlüsselungs-Passwort fragt: abbrechen, das brauchen wir nicht."
wait_adb

log="$BK/noxis-$(date +%H%M%S).log"
adb shell 'cat /sys/fs/pstore/console-ramoops-0' > "$log" 2>/dev/null
[ -s "$log" ] || die "pstore leer"

echo
kv=$(grep -am1 "Linux version" "$log" | sed 's/.*Linux version \([^ ]*\).*/\1/')
c "Kernel im Log: $kv"
case "$kv" in
  *android14*) warn "Das ist der Stock-Kernel – falscher Durchlauf erwischt, bitte nochmal." ;;
esac
echo
c "=== noxis-init ==="
grep -an "noxis-init:" "$log" | tail -15
echo
c "=== USB / dwc3 / Gadget ==="
grep -anE "dwc3|usb_f_|gadget|configfs|UDC|hsphy" "$log" | tail -25
echo
c "=== Panic / Fehler ==="
grep -anE "Kernel panic|Unable to handle|BUG:|Unknown symbol" "$log" | tail -15
echo
ok "Vollständiges Log: $log"
echo "Schick mir die Ausgabe ab '=== noxis-init ==='."
