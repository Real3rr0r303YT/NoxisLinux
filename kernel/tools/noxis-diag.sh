#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
# Noxis Linux – Diagnose-Haken im installierten Rootfs.
#
#   ./noxis-diag.sh install   Haken ins Rootfs legen (Geraet in der Recovery)
#   ./noxis-diag.sh fetch     Diagnose nach einem Noxis-Boot abholen
#   ./noxis-diag.sh remove    Haken wieder entfernen
#   ./noxis-diag.sh shell     noxis-shell und noxis-opsec aus dem Repo ins
#                             installierte Rootfs kopieren (ohne Neubau)
#   ./noxis-diag.sh gpu       Mesa mit Turnip-KGSL nach /opt/mesa-kgsl (experimentell)
#   ./noxis-diag.sh seatd     seatd.service aktivieren und die Benutzer in die
#                             Gruppe _seatd aufnehmen
#   ./noxis-diag.sh debs      fehlende Debian-Pakete (pd-mapper, dbus-x11) per
#                             Docker holen; das Handy installiert sie beim
#                             naechsten Boot selbst (dpkg laeuft dort nativ)
#
# Warum nicht das Journal: noxis-opsec setzt Storage=volatile, das Journal
# liegt also nur im RAM und ist nach dem Ausschalten weg. Und der
# ramoops-Konsolenpuffer laeuft bei 150 Sekunden Laufzeit ueber, der Anfang
# des Bootvorgangs mit dem Modul-Laden wird dabei ueberschrieben.
#
# Deshalb schreibt ein oneshot-Dienst im laufenden System dmesg, lsmod, die
# fehlgeschlagenen Units und den DRM-Zustand nach /var/log/noxis. Das liegt
# auf der Partition und ueberlebt das Ausschalten; aus der Recovery wird es
# dann abgeholt.
set -u

c()   { printf '\033[1;36m[diag]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*"; exit 1; }

REPO="${NOXIS_REPO:-$HOME/NoxisLinux}"
M=/mnt/noxisroot
OUTDIR="$HOME/noxis-backup/diag-$(date +%H%M%S)"

need_recovery() {
  # Nach "noxis-try.sh --restore" ist die Recovery noch im Hochfahren, also
  # warten statt sofort abzubrechen.
  adb devices 2>/dev/null | grep -q recovery && return 0
  c "warte auf die Recovery …"
  local i=0
  until adb devices 2>/dev/null | grep -q recovery; do
    sleep 1; i=$((i + 1))
    [ "$i" -ge 150 ] && die "Geraet ist nicht in der Recovery. Erst: kernel/tools/noxis-try.sh --restore"
    [ $((i % 15)) -eq 0 ] && c "… noch nicht da (${i}s)"
  done
  ok "Recovery da"
}

mount_root() {
  adb shell "mkdir -p $M" >/dev/null 2>&1
  adb shell "mount -t ext4 -o rw /dev/block/by-name/userdata $M 2>/dev/null || mount -t ext4 -o rw \$(readlink -f /dev/block/by-name/userdata) $M" >/dev/null 2>&1
  adb shell "[ -d $M/etc/systemd ] && echo yes" 2>/dev/null | grep -q yes \
    || die "Rootfs nicht gemountet oder kein Noxis-System auf userdata"
  ok "Rootfs gemountet"
}

umount_root() {
  adb shell "sync; umount $M" >/dev/null 2>&1
  ok "abgemeldet"
}

case "${1:-}" in
install)
  need_recovery; mount_root
  c "Dienst einrichten"
  adb shell "mkdir -p $M/usr/local/sbin $M/etc/systemd/system/multi-user.target.wants" >/dev/null 2>&1

  tmp=$(mktemp -d)
  cat > "$tmp/noxis-bootlog" <<'EOS'
#!/bin/sh
# Noxis: Bootdiagnose auf die Partition schreiben (ueberlebt das Ausschalten).
# Wiederholt, weil ein Anmeldeversuch Minuten nach dem Start passiert und ein
# einmaliger Schnappschuss ihn nicht enthaelt. Jede Runde ueberschreibt die
# vorherige, der letzte Stand vor dem Ausschalten bleibt also stehen.
snapshot() {
d=/var/log/noxis
mkdir -p "$d"
dmesg                                   > "$d/dmesg.log"    2>&1
lsmod | sort                            > "$d/modules.log"  2>&1
systemctl --failed --no-pager --no-legend > "$d/failed.log"  2>&1
systemctl list-units --type=service --state=running --no-pager --no-legend > "$d/running.log" 2>&1
{ echo "--- /dev/dri ---"; ls -la /dev/dri 2>&1
  echo "--- /sys/class/drm ---"; ls -la /sys/class/drm 2>&1
  echo "--- /sys/class/backlight ---"; ls -la /sys/class/backlight 2>&1
  echo "--- modprobe msm_drm ---"; modprobe -v msm_drm 2>&1; echo "rc=$?"
  echo "--- danach /sys/class/drm ---"; ls -la /sys/class/drm 2>&1
  echo "--- dmesg-Nachtrag ---"; dmesg | tail -40 2>&1
} > "$d/drm.log" 2>&1
{ echo "--- /sys/class/power_supply ---"; ls -la /sys/class/power_supply 2>&1
  for ps in /sys/class/power_supply/*; do
    [ -d "$ps" ] || continue
    echo "== ${ps##*/} =="
    for f in type status present capacity voltage_now current_now technology; do
      [ -r "$ps/$f" ] && echo "  $f=$(cat "$ps/$f" 2>/dev/null)"
    done
  done
  echo "--- upower ---"; command -v upower >/dev/null && upower -d 2>&1 || echo "upower nicht installiert"
  echo "--- logind-Sitzungen ---"; loginctl list-sessions --no-pager 2>&1; loginctl show-session --no-pager 2>&1
  echo "--- systemd --user ---"; systemctl --user --no-pager status 2>&1 | head -5
  echo "--- Netz ---"; nmcli -t device 2>&1; rfkill list 2>&1
  echo "--- Firmware-Mounts ---"; grep -E "vendor|firmware" /proc/mounts
  echo "--- firmware_mnt/image (Auszug) ---"; ls /vendor/firmware_mnt/image 2>&1 | head -25
  echo "--- /lib/firmware Links ---"; ls /lib/firmware | wc -l; ls -la /lib/firmware | head -8
  echo "--- firmware_class.path ---"; cat /sys/module/firmware_class/parameters/path 2>&1
  echo "--- remoteproc ---"
  for r in /sys/class/remoteproc/remoteproc*; do echo "  $(cat $r/name 2>/dev/null): firmware=$(cat $r/firmware 2>/dev/null) modalias=$(cat $r/device/modalias 2>/dev/null)"; done
  echo "--- uio (rmtfs) ---"
  for u in /sys/class/uio/uio*; do echo "  $(basename $u): $(cat $u/name 2>/dev/null)"; done; ls -la /dev/qcom_rmtfs* 2>&1
  echo "--- Touch ---"; echo "  Ereignisse: $(dmesg | grep -ac fts_input_report)"; dmesg | grep -aE "fts_panel_notifier|FTS_TS/E|fts_ts_suspend|fts_ts_resume" | tail -8
  echo "--- pd-mapper .jsn ---"
  ls -la /lib/firmware/ 2>/dev/null | grep -i jsn
  ls /vendor/firmware_mnt/image /vendor/firmware /vendor/dsp 2>/dev/null | grep -i jsn
  find /vendor /lib/firmware -maxdepth 4 -iname "*.jsn*" 2>/dev/null | head -20
  for r in /sys/class/remoteproc/remoteproc*; do echo "  $(cat $r/name 2>/dev/null): $(cat $r/state 2>/dev/null)"; done
  echo "--- Hardware-Dienste ---"
  systemctl --no-pager -n 15 status noxis-install-debs noxis-firmware-links noxis-radios rmtfs pd-mapper tqftpserv 2>&1 | head -90; journalctl -b --no-pager -u rmtfs -u pd-mapper -u noxis-install-debs -u noxis-radios 2>&1 | tail -40
} > "$d/system.log" 2>&1
{ echo "--- KGSL ---"; ls -la /dev/kgsl* /dev/dma_heap 2>&1
  if [ -d /opt/mesa-kgsl ]; then
    icd=$(ls /opt/mesa-kgsl/share/vulkan/icd.d/freedreno_icd*.json 2>/dev/null | head -n1)
    echo "--- vulkaninfo (turnip-kgsl, icd=$icd) ---"
    VK_ICD_FILENAMES="$icd" LD_LIBRARY_PATH=/opt/mesa-kgsl/lib:/opt/mesa-kgsl/lib/aarch64-linux-gnu \
      timeout 20 /opt/mesa-kgsl/bin/vulkaninfo --summary 2>&1 | head -60
  else
    echo "kein /opt/mesa-kgsl – erst build-mesa-kgsl.sh und noxis-diag.sh gpu"
  fi
} > "$d/gpu.log" 2>&1
journalctl -b --no-pager                > "$d/journal.log"  2>&1
date                                    > "$d/when.log"     2>&1
sync
}
i=0
while [ "$i" -lt 45 ]; do
  snapshot
  sleep 20
  i=$((i + 1))
done
EOS
  cat > "$tmp/noxis-bootlog.service" <<'EOS'
[Unit]
Description=Noxis: Bootdiagnose nach /var/log/noxis schreiben
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStartPre=/bin/sleep 20
ExecStart=/usr/local/sbin/noxis-bootlog
Restart=no

[Install]
WantedBy=multi-user.target
EOS
  adb push "$tmp/noxis-bootlog" "$M/usr/local/sbin/noxis-bootlog" >/dev/null 2>&1 || die "push fehlgeschlagen"
  adb push "$tmp/noxis-bootlog.service" "$M/etc/systemd/system/noxis-bootlog.service" >/dev/null 2>&1 || die "push fehlgeschlagen"
  adb shell "chmod 755 $M/usr/local/sbin/noxis-bootlog" >/dev/null 2>&1
  adb shell "ln -sf ../noxis-bootlog.service $M/etc/systemd/system/multi-user.target.wants/noxis-bootlog.service" >/dev/null 2>&1
  adb shell "[ -L $M/etc/systemd/system/multi-user.target.wants/noxis-bootlog.service ] && echo yes" 2>/dev/null | grep -q yes \
    || die "Dienst nicht verknuepft"
  rm -rf "$tmp"
  ok "Dienst eingerichtet – er schreibt ab Sekunde 20 alle 20 Sekunden neu, 15 Minuten lang"
  umount_root
  echo
  c "Jetzt: kernel/tools/noxis-try.sh starten, anmelden, dann mindestens 60 Sekunden warten,"
  c "dann --restore, und danach: noxis-diag.sh fetch"
  ;;

fetch)
  need_recovery; mount_root
  adb shell "[ -d $M/var/log/noxis ] && echo yes" 2>/dev/null | grep -q yes \
    || { umount_root; die "keine Diagnose gefunden – lief der Dienst? Mindestens 90 Sekunden booten lassen."; }
  mkdir -p "$OUTDIR"
  for f in when dmesg modules failed running drm system gpu journal; do
    adb pull "$M/var/log/noxis/$f.log" "$OUTDIR/$f.log" >/dev/null 2>&1
  done
  umount_root
  ok "Diagnose in $OUTDIR"
  echo
  c "=== wann ==="; cat "$OUTDIR/when.log" 2>/dev/null
  echo; c "=== fehlgeschlagene Units ==="; cat "$OUTDIR/failed.log" 2>/dev/null
  echo; c "=== Display-Module geladen? ==="
  grep -iE "msm_drm|sde|dsi|panel|drm" "$OUTDIR/modules.log" 2>/dev/null || echo "  (keins)"
  echo; c "=== DRM-Zustand ==="; cat "$OUTDIR/drm.log" 2>/dev/null | head -60
  echo; c "=== Display im dmesg ==="
  grep -inE "msm_drm|sde_|dsi|panel|drm" "$OUTDIR/dmesg.log" 2>/dev/null | tail -25 || echo "  (nichts)"
  ;;

shell)
  # Dateien aus dem Repo ins installierte System spielen. Ein Rootfs-Neubau
  # dauert eine halbe Stunde; fuer eine geaenderte Python-Datei oder eine
  # Konfigurationsdatei ist das unverhaeltnismaessig.
  need_recovery; mount_root
  n=0
  for rel in \
      noxis-shell/usr/lib/noxis/dm/noxis-dm \
      noxis-shell/usr/lib/noxis/dm/pam.py \
      noxis-shell/usr/lib/noxis/dm/setup.py \
      noxis-shell/usr/lib/noxis/dm/wifi.py \
      noxis-shell/usr/lib/noxis/greeter/core.py \
      noxis-shell/usr/lib/noxis/greeter/greetd_ipc.py \
      noxis-shell/usr/lib/noxis/greeter/i18n.py \
      noxis-shell/usr/lib/noxis/greeter/noxis-greeter \
      noxis-shell/usr/lib/noxis/greeter/style.css \
      noxis-shell/usr/lib/noxis/noxis-dock \
      noxis-shell/etc/noxis/dm.conf \
      noxis-shell/etc/noxis/greeter.conf \
      noxis-shell/etc/noxis/dock.conf \
      noxis-shell/etc/pam.d/noxis \
      noxis-shell/etc/pam.d/noxis-greeter \
      noxis-shell/etc/polkit-1/rules.d/50-noxis-power.rules \
      noxis-hw/etc/systemd/logind.conf.d/90-noxis.conf \
      noxis-hw/etc/systemd/system/upower.service.d/90-noxis.conf \
      noxis-hw/etc/systemd/system/rmtfs.service.d/90-noxis.conf \
      noxis-hw/etc/systemd/system/pd-mapper.service.d/90-noxis.conf \
      noxis-hw/usr/lib/udev/rules.d/70-noxis-gpu.rules \
      noxis-hw/usr/lib/udev/rules.d/65-noxis-rmtfs.rules \
      noxis-hw/usr/lib/noxis/hw/noxis-firmware-links \
      noxis-hw/usr/lib/noxis/hw/noxis-radios \
      noxis-hw/usr/lib/noxis/hw/noxis-to-rescue \
      noxis-hw/usr/share/applications/noxis-rescue.desktop \
      noxis-hw/etc/polkit-1/rules.d/50-noxis-rescue.rules
  do
    src="$REPO/$rel"
    [ -f "$src" ] || continue
    dst="$M/${rel#*/}"
    adb shell "mkdir -p \$(dirname $dst)" >/dev/null 2>&1
    adb push "$src" "$dst" >/dev/null 2>&1 && { n=$((n + 1)); } || die "push $rel fehlgeschlagen"
    case "$rel" in *.py|*.css|*.conf|*.rules|*.desktop|*/pam.d/*) adb shell "chmod 644 $dst" >/dev/null 2>&1 ;; *) adb shell "chmod 755 $dst" >/dev/null 2>&1 ;; esac
  done
  adb shell "sync" >/dev/null 2>&1
  ok "$n Dateien aktualisiert"
  umount_root
  ;;

seatd)
  # phoc fragt /run/seatd.sock als erstes ab. Debian liefert seatd mit,
  # aktiviert den Dienst aber nicht; ohne ihn bleibt nur logind, und das gibt
  # die Sitzung nicht heraus, solange sie einem anderen Benutzer gehoert.
  need_recovery; mount_root
  adb shell "[ -x $M/usr/bin/seatd ] || [ -x $M/usr/sbin/seatd ] && echo yes" 2>/dev/null | grep -q yes \
    || { umount_root; die "seatd ist nicht installiert – Rootfs mit dem neuen Paketstand bauen"; }
  adb shell "mkdir -p $M/etc/systemd/system/multi-user.target.wants" >/dev/null 2>&1
  u=""
  for cand in usr/lib/systemd/system/seatd.service lib/systemd/system/seatd.service; do
    adb shell "[ -f $M/$cand ] && echo yes" 2>/dev/null | grep -q yes && { u="/$cand"; break; }
  done
  [ -n "$u" ] || { umount_root; die "seatd.service nicht gefunden"; }
  adb shell "ln -sf $u $M/etc/systemd/system/multi-user.target.wants/seatd.service" >/dev/null 2>&1
  adb shell "[ -L $M/etc/systemd/system/multi-user.target.wants/seatd.service ] && echo yes" 2>/dev/null | grep -q yes \
    || { umount_root; die "seatd.service nicht verknuepft"; }
  ok "seatd.service aktiviert ($u)"
  # Gruppe _seatd: die Benutzer muessen den Socket benutzen duerfen.
  for user in noxis noxis-greeter; do
    adb shell "grep -q '^_seatd:' $M/etc/group && echo yes" 2>/dev/null | grep -q yes || continue
    adb shell "grep -q '^_seatd:.*\b$user\b' $M/etc/group && echo have" 2>/dev/null | grep -q have && continue
    adb shell "sed -i 's/^\(_seatd:[^:]*:[^:]*:\)\(.*\)\$/\1\2,$user/; s/,,/,/; s/:,/:/' $M/etc/group" >/dev/null 2>&1
  done
  adb shell "grep '^_seatd:' $M/etc/group" 2>/dev/null
  adb shell "sync" >/dev/null 2>&1
  umount_root
  ;;

gpu)
  # Mesa mit Turnip-KGSL ins Rootfs unter /opt/mesa-kgsl (EXPERIMENTELL).
  tgz="$HOME/Desktop/noxis-linux/mesa-kgsl.tar.gz"
  [ -f "$tgz" ] || die "$tgz fehlt – erst kernel/tools/build-mesa-kgsl.sh"
  need_recovery; mount_root
  adb push "$tgz" /tmp/mesa-kgsl.tar.gz >/dev/null 2>&1 || die "push fehlgeschlagen"
  adb shell "rm -rf $M/opt/mesa-kgsl; mkdir -p $M/opt && tar -xzf /tmp/mesa-kgsl.tar.gz -C $M/opt && rm /tmp/mesa-kgsl.tar.gz" \
    || die "entpacken fehlgeschlagen"
  ok "Mesa (turnip-kgsl) nach /opt/mesa-kgsl – der Diagnose-Haken testet es mit vulkaninfo"
  umount_root
  ;;

debs)
  # Pakete, die im installierten Rootfs fehlen. Ohne Neubau: Docker (arm64)
  # laedt die .deb-Dateien, der Boot-Dienst noxis-install-debs installiert
  # sie auf dem Handy mit dpkg und loescht sie danach.
  PKGS="${NOXIS_DEBS:-protection-domain-mapper dbus-x11}"
  cache="$HOME/noxis-backup/debs"
  mkdir -p "$cache"
  if ! ls "$cache"/*.deb >/dev/null 2>&1; then
    command -v docker >/dev/null || die "docker fehlt"
    c "lade $PKGS (arm64) …"
    docker run --rm --platform linux/arm64 -v "$cache:/out" debian:trixie sh -c \
      "apt-get update -qq && cd /out && apt-get download -q $PKGS && chmod 644 /out/*.deb" \
      || die "Download fehlgeschlagen"
  fi
  ls "$cache"/*.deb | sed 's|.*/|  |'
  need_recovery; mount_root
  adb shell "mkdir -p $M/var/cache/noxis-debs" >/dev/null 2>&1
  for f in "$cache"/*.deb; do
    adb push "$f" "$M/var/cache/noxis-debs/" >/dev/null 2>&1 || die "push $f fehlgeschlagen"
  done
  for rel in noxis-hw/usr/lib/noxis/hw/noxis-install-debs noxis-hw/usr/lib/systemd/system/noxis-install-debs.service; do
    dst="$M/${rel#*/}"
    adb push "$REPO/$rel" "$dst" >/dev/null 2>&1 || die "push $rel fehlgeschlagen"
  done
  adb shell "chmod 755 $M/usr/lib/noxis/hw/noxis-install-debs; chmod 644 $M/usr/lib/systemd/system/noxis-install-debs.service; \
    mkdir -p $M/etc/systemd/system/multi-user.target.wants; \
    ln -sf /usr/lib/systemd/system/noxis-install-debs.service $M/etc/systemd/system/multi-user.target.wants/noxis-install-debs.service" \
    >/dev/null 2>&1
  ok "Pakete liegen bereit – Noxis installiert sie beim naechsten Boot"
  umount_root
  ;;

remove)
  need_recovery; mount_root
  adb shell "rm -f $M/etc/systemd/system/multi-user.target.wants/noxis-bootlog.service $M/etc/systemd/system/noxis-bootlog.service $M/usr/local/sbin/noxis-bootlog" >/dev/null 2>&1
  adb shell "rm -rf $M/var/log/noxis" >/dev/null 2>&1
  ok "Haken entfernt"
  umount_root
  ;;

*)
  sed -n '2,20p' "$0"
  ;;
esac
