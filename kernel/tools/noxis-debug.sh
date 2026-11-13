#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
# Noxis Linux – ein Befehl fuer den kompletten Debug-Durchlauf.
#
#   ./noxis-debug.sh            Durchlauf mit dem vorhandenen Kernel-Image
#   ./noxis-debug.sh --build    vorher Initramfs + boot.img neu bauen
#
# Ablauf (du drueckst nur die Tasten, wenn es dich auffordert):
#   1. Recovery holen (Stock-Bootkette), Rootfs pruefen:
#      pam_systemd, PAM-Stapel, seatd, Firmware-Partition, Pakete
#   2. aktuelle Shell-Dateien + seatd + Diagnose-Haken ins Rootfs
#   3. Noxis starten – du meldest dich an und wartest 90 Sekunden
#   4. zurueck in die Recovery, Diagnose holen
#   5. Zusammenfassung: Sitzung, Benutzer-systemd, Akku, Netz, Firmware
#
# Alles landet zusaetzlich in ~/noxis-backup/debug-<Zeit>.txt – die Datei
# schickst du mir.
set -u
T="$(dirname "$(readlink -f "$0")")"
REPO="$(cd "$T/../.." && pwd)"
OUT="$HOME/noxis-backup/debug-$(date +%m%d-%H%M).txt"
M=/mnt/noxisroot
mkdir -p "$HOME/noxis-backup"
exec > >(tee "$OUT") 2>&1

c()   { printf '\033[1;36m[debug]\033[0m %s\n' "$*"; }
ask() { printf '\033[1;35m[ DU  ]\033[0m %s\n' "$*"; }
hdr() { printf '\n\033[1;33m==== %s ====\033[0m\n' "$*"; }

wait_recovery() {
  local i=0
  until adb devices 2>/dev/null | grep -q recovery; do
    sleep 1; i=$((i + 1))
    [ "$i" -ge 240 ] && { c "keine Recovery nach 4 Minuten"; exit 1; }
    [ $((i % 20)) -eq 0 ] && c "warte auf die Recovery … (${i}s) – Entschluesselung ggf. abbrechen"
  done
}
rsh() { adb shell "$@" 2>/dev/null; }

git -C "$REPO" pull --ff-only >/dev/null 2>&1 && c "Repo aktuell" || c "git pull uebersprungen"

if [ "${1:-}" = "--build" ]; then
  hdr "0/5 Initramfs + boot.img bauen"
  sudo -v
  sudo docker run --rm \
    -v "$REPO:/noxis:ro" -v "$HOME/Desktop/noxis-linux:/out" -v "noxis-kernel:/kwork" \
    -e NOXIS_KWORK=/kwork -e NOXIS_KOUT=/out \
    -e NOXIS_CMDLINE="console=tty0 loglevel=7 selinux=0 panic=0 noxis.root=userdata noxis.debug=0" \
    debian:trixie bash -c '
      set -e
      apt-get update -q >/dev/null
      apt-get install -y -q --no-install-recommends make cpio kmod mkbootimg dpkg-dev ca-certificates lz4 python3 >/dev/null 2>&1
      /noxis/kernel/build-noxis-kernel.sh initramfs
      /noxis/kernel/build-noxis-kernel.sh bootimg' 2>&1 | grep -E "noxis-kernel|warn|ERROR" || { c "Build fehlgeschlagen"; exit 1; }
fi
sudo -v   # Passwort jetzt abfragen, nicht spaeter im Hintergrund

hdr "1/5 Recovery"
if ! adb devices 2>/dev/null | grep -q recovery; then
  "$T/noxis-try.sh" --restore || exit 1
fi
wait_recovery
c "Recovery da"

rsh "mkdir -p $M; mount -t ext4 -o rw /dev/block/by-name/userdata $M 2>/dev/null; true"
rsh "[ -d $M/etc/systemd ] && echo ok" | grep -q ok || { c "Rootfs nicht mountbar – ist Noxis auf userdata?"; exit 1; }

hdr "Rootfs-Pruefung"
echo "--- pam_systemd.so ---"
rsh "ls -la $M/usr/lib/aarch64-linux-gnu/security/pam_systemd.so $M/lib/aarch64-linux-gnu/security/pam_systemd.so 2>&1"
echo "--- Pakete ---"
for p in libpam-systemd dbus-user-session dbus-x11 seatd upower squeekboard phosh gnome-session-bin network-manager modemmanager rmtfs; do
  rsh "grep -q '^Package: $p\$' $M/var/lib/dpkg/status && echo '  [x] $p' || echo '  [ ] $p FEHLT'"
done
echo "--- /etc/pam.d/noxis ---";          rsh "grep -v '^#' $M/etc/pam.d/noxis | grep -v '^\$'"
echo "--- /etc/pam.d/common-session ---"; rsh "grep -v '^#' $M/etc/pam.d/common-session | grep -v '^\$'"
echo "--- seatd ---"; rsh "ls -la $M/etc/systemd/system/multi-user.target.wants/seatd.service 2>&1; grep '^_seatd\|^video' $M/etc/group"
echo "--- Firmware im Rootfs ---"; rsh "ls $M/lib/firmware 2>&1 | head -20; ls -d $M/vendor/firmware_mnt $M/vendor/dsp 2>&1"
echo "--- Firmware-Partitionen auf dem Geraet ---"; rsh "ls /dev/block/by-name/ | grep -E '^(modem|dsp|bluetooth|vendor|persist)' | tr '\n' ' '"; echo
rsh "sync; umount $M"

hdr "2/5 Dateien einspielen"
"$T/noxis-diag.sh" shell
"$T/noxis-diag.sh" seatd
[ -f "$HOME/Desktop/noxis-linux/mesa-kgsl.tar.gz" ] && "$T/noxis-diag.sh" gpu
"$T/noxis-diag.sh" install

hdr "3/5 Noxis starten"
ask "Wenn der Anmeldebildschirm kommt: Modus MOBIL, PIN eingeben (oder neue PIN festlegen)."
ask "Danach 90 Sekunden NICHTS tun – dann holt das Skript das Log."
"$T/noxis-try.sh" >/dev/null 2>&1 &
TRY=$!
sleep 240
kill "$TRY" 2>/dev/null

hdr "4/5 Diagnose holen"
"$T/noxis-try.sh" --restore
wait_recovery
"$T/noxis-diag.sh" fetch >/dev/null
D=$(ls -dt "$HOME"/noxis-backup/diag-* | head -1)

hdr "5/5 Zusammenfassung ($D)"
J="$D/journal.log"
echo "--- logind-Sitzungen ---"
grep -aE "New session|Removed session|pam_systemd" "$J" | tail -12
echo "--- Benutzer-systemd (user@1000) ---"
grep -aE "user@1000|Started User Manager|systemd\[.*\]: (Startup finished|Reached target default)" "$J" | tail -8
echo "--- seatd / phoc / gnome-session ---"
grep -aE "seatd\[|phoc\[|gnome-session|Session terminated|SessionManager" "$J" | grep -aiE "error|fail|terminat|lost|critical|open|added" | tail -20
echo "--- squeekboard ---"; grep -ai "squeekboard" "$J" | tail -5
echo "--- Akku / Netz / Firmware ---"; cat "$D/system.log" 2>/dev/null | head -60
echo "--- Firmware-Fehler (Anzahl je Datei) ---"
grep -aoE 'Direct firmware load for [^ ]+ failed' "$D/dmesg.log" | sort | uniq -c | sort -rn | head -15
echo "--- GPU (KGSL / turnip) ---"; cat "$D/gpu.log" 2>/dev/null
echo "--- fehlgeschlagene Units ---"; cat "$D/failed.log"

echo
c "Fertig. Schick mir die Datei: $OUT"
