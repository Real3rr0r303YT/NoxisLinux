#!/usr/bin/env bash
# Noxis Linux – Diagnose-Haken im installierten Rootfs.
#
#   ./noxis-diag.sh install   Haken ins Rootfs legen (Geraet in der Recovery)
#   ./noxis-diag.sh fetch     Diagnose nach einem Noxis-Boot abholen
#   ./noxis-diag.sh remove    Haken wieder entfernen
#   ./noxis-diag.sh shell     noxis-shell und noxis-opsec aus dem Repo ins
#                             installierte Rootfs kopieren (ohne Neubau)
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
  for f in when dmesg modules failed running drm journal; do
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
      noxis-shell/usr/lib/noxis/greeter/core.py \
      noxis-shell/usr/lib/noxis/greeter/greetd_ipc.py \
      noxis-shell/usr/lib/noxis/greeter/i18n.py \
      noxis-shell/usr/lib/noxis/greeter/noxis-greeter \
      noxis-shell/usr/lib/noxis/greeter/style.css \
      noxis-shell/usr/lib/noxis/noxis-dock \
      noxis-shell/etc/noxis/dm.conf \
      noxis-shell/etc/noxis/greeter.conf \
      noxis-shell/etc/noxis/dock.conf
  do
    src="$REPO/$rel"
    [ -f "$src" ] || continue
    dst="$M/${rel#noxis-shell/}"
    adb shell "[ -e $dst ] && echo yes" 2>/dev/null | grep -q yes || { c "nicht im System, uebersprungen: ${rel#noxis-shell/}"; continue; }
    adb push "$src" "$dst" >/dev/null 2>&1 && { n=$((n + 1)); } || die "push $rel fehlgeschlagen"
    case "$rel" in *.py|*.css|*.conf) ;; *) adb shell "chmod 755 $dst" >/dev/null 2>&1 ;; esac
  done
  adb shell "sync" >/dev/null 2>&1
  ok "$n Dateien aktualisiert"
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
