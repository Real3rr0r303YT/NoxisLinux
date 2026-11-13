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
#   ./noxis-diag.sh gpu-off   GPU-Umgebung (Turnip/Zink) aus dem installierten
#                             System nehmen – gegen Neustart-Schleifen
#   ./noxis-diag.sh wlan      WCNSS_qcom_cfg.ini und wlan_mac.bin aus vendor
#                             bzw. persist ins Rootfs legen (WLAN-Treiber)
#   ./noxis-diag.sh vendorfw  ~/noxis-backup/vendor-firmware ins /lib/firmware
#                             des Systems schieben (Board-Daten fuer WLAN/BT)
#   ./noxis-diag.sh usbnet    USB-Netz + SSH einrichten: danach gibt es mit
#                             kernel/tools/noxis-shell.sh eine Shell vom PC
#   ./noxis-diag.sh usbnet-off  denselben Dienst wieder abschalten
#   ./noxis-diag.sh bdf       Funkkalibrierung: Board-Dateien suchen, das von
#                             vendorfw angelegte Verzeichnis entfernen
#   ./noxis-diag.sh macperm   echte statt zufaelliger MAC (Test bei
#                             auth_no_resp_received); zurueck mit macrand
#   ./noxis-diag.sh regdb     regulatory.db vom PC nachlegen (Funkregeln)
#   ./noxis-diag.sh wpa2      WPA2 erzwingen (SAE/WPA3 laeuft mit diesem
#                             Treiber in eine Zeitueberschreitung); zurueck: wpa3
#   ./noxis-diag.sh osk       DBus-Aktivierung fuer die Bildschirmtastatur
#                             (sm.puri.OSK0) nachlegen
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

# In Debian ist /lib ein ABSOLUTER Verweis auf /usr/lib. Im Recovery zeigt
# $M/lib damit nicht ins Handy-System, sondern auf /usr/lib der Recovery
# selbst: Schreibzugriffe landen in deren Arbeitsspeicher und sind nach dem
# Neustart weg – ohne jede Fehlermeldung, solange die Verzeichnisse zufaellig
# existieren. Genau so sind die Board-Daten einmal spurlos verschwunden.
# Darum den echten Pfad im gemounteten Rootfs ermitteln.
# mkdir -p legt im Recovery keine Zwischenebenen an, also Ebene fuer Ebene.
mkdirs() {
  local path="" part
  for part in $(echo "$1" | tr '/' ' '); do
    path="$path/$part"
    adb shell "[ -d $path ] || mkdir $path 2>&1" | sed '/^$/d;s/^/    /'
  done
}

fwdir() {
  if adb shell "[ -L $M/lib ] && echo yes" 2>/dev/null | grep -q yes; then
    echo "$M/usr/lib/firmware"
  else
    echo "$M/lib/firmware"
  fi
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
{ echo "--- Pakete ---"
  for p in squeekboard phosh-osk-stub phosh phosh-core kgx waydroid mullvad-vpn \
           xwayland gnome-text-editor phosh-mobile-settings policykit-1 polkitd \
           pkexec network-manager modemmanager rmtfs protection-domain-mapper; do
    printf '  %-26s %s\n' "$p" "$(dpkg-query -W -f='${Status} ${Version}' "$p" 2>/dev/null || echo 'NICHT installiert')"
  done
  echo "--- Bildschirmtastatur ---"
  echo "  Prozesse:"; ps -eo comm= | grep -iE "squeek|osk" | sort -u | sed 's/^/    /' || echo "    (keiner)"
  echo "  DBus sm.puri.OSK0:"
  ls -la /usr/share/dbus-1/services/*OSK* /usr/share/dbus-1/services/*squeek* 2>&1
  ls -la /usr/lib/systemd/user/*OSK* /usr/lib/systemd/user/*squeek* 2>&1
  for u in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $3}' | sort -u); do
    echo "  gsettings fuer $u:"
    uid=$(id -u "$u" 2>/dev/null) || continue
    su - "$u" -c "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
      gsettings get org.gnome.desktop.a11y.applications screen-keyboard-enabled" 2>&1 | sed 's/^/    /'
    su - "$u" -c "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus \
      systemctl --user list-units --no-pager --no-legend 'sm.puri*' 'squeek*'" 2>&1 | sed 's/^/    /'
  done
  echo "--- noxis-dock ---"; journalctl -b --no-pager | grep -a "noxis-dock" | tail -15
  echo "--- Ausgaenge (wlr-randr) ---"; command -v wlr-randr >/dev/null && echo "  da" || echo "  fehlt"
  echo "--- Tor Browser und Mullvad ---"
  echo "  /opt/tor-browser: $(ls -ld /opt/tor-browser 2>&1 | head -1)"
  echo "  start-tor-browser: $([ -x /opt/tor-browser/Browser/start-tor-browser ] && echo ausfuehrbar || echo FEHLT)"
  echo "  Groesse: $(du -sh /opt/tor-browser 2>/dev/null | cut -f1)"
  echo "  Platz auf /: $(df -h / 2>/dev/null | awk 'NR==2{print $4" frei von "$2}')"
  for h in /home/*; do
    [ -d "$h" ] || continue
    echo "  Kopie in ${h##*/}: $(ls -ld "$h/.local/share/noxis/tor-browser" 2>&1 | head -1)"
  done
  echo "  mullvad-daemon: $(systemctl is-active mullvad-daemon 2>&1)"
  echo "  mullvad-Programm: $(ls -l '/opt/Mullvad VPN/mullvad-vpn' 2>&1 | head -1)"
  echo "  Journal (Tor/Mullvad):"
  journalctl -b --no-pager | grep -aiE "tor-browser|mullvad|electron|ozone" | tail -25
  echo "--- Starter, die nicht aufgehen ---"
  for f in /usr/share/applications/noxis-rescue.desktop \
           /usr/share/applications/noxis-tor-browser.desktop \
           /usr/share/applications/mullvad-vpn.desktop; do
    echo "  $f: $([ -f "$f" ] && echo da || echo fehlt)"
  done
  for b in /usr/lib/noxis/hw/noxis-to-rescue /usr/bin/noxis-tor-browser /opt/Mullvad*/mullvad-vpn; do
    echo "  $b: $([ -x "$b" ] && echo ausfuehrbar || echo "fehlt/nicht ausfuehrbar")"
  done
  echo "--- polkit-Regeln ---"; ls -la /etc/polkit-1/rules.d/ 2>&1
  echo "--- polkit-Agent laeuft? ---"; ps -eo comm= | grep -iE "polkit|agent" | sort -u | sed 's/^/    /'
  echo "--- pkexec-Versuch (als Noxis-Benutzer, nicht interaktiv) ---"
  journalctl -b --no-pager | grep -aiE "polkit|pkexec" | tail -20
} > "$d/apps.log" 2>&1
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
  for f in when dmesg modules failed running drm system gpu apps journal; do
    adb pull "$M/var/log/noxis/$f.log" "$OUTDIR/$f.log" >/dev/null 2>&1
  done
  umount_root
  ok "Diagnose in $OUTDIR"
  echo
  c "=== wann ==="; cat "$OUTDIR/when.log" 2>/dev/null
  echo; c "=== fehlgeschlagene Units ==="; cat "$OUTDIR/failed.log" 2>/dev/null
  echo; c "=== Pakete, Tastatur, Starter ==="; cat "$OUTDIR/apps.log" 2>/dev/null \
    || echo "  (kein apps.log – der Haken im Rootfs ist aelter, neu: noxis-diag.sh install)"
  echo; c "=== Modem und WLAN ==="
  sed -n '/--- Netz ---/,$p' "$OUTDIR/system.log" 2>/dev/null | head -80
  echo; c "=== WLAN/Modem im dmesg ==="
  grep -inE "icnss|wlan|cnss|qmi|rmtfs|mhi|modem|slpi|adsp" "$OUTDIR/dmesg.log" 2>/dev/null | tail -30 \
    || echo "  (nichts)"
  echo
  c "Alles liegt in $OUTDIR – dmesg.log, journal.log, system.log, apps.log"
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
  # Pro Paketliste ein eigener Ordner, sonst liefert ein alter Download die
  # falschen .deb-Dateien zurueck, sobald NOXIS_DEBS geaendert wird.
  cache="$HOME/noxis-backup/debs/$(printf '%s' "$PKGS" | tr -c 'a-zA-Z0-9.+-' '_')"
  mkdir -p "$cache"
  if ! ls "$cache"/*.deb >/dev/null 2>&1; then
    command -v docker >/dev/null || die "docker fehlt"
    # Ein arm64-Container auf x86 braucht qemu im binfmt_misc des Rechners.
    # Fehlt es, bricht docker mit "exec format error" ab. Die Registrierung
    # haelt nur bis zum Neustart, also hier jedes Mal sicherstellen.
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
      c "qemu-aarch64 fuer Docker registrieren (einmal pro Rechnerstart)"
      sudo docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 \
        || c "binfmt-Registrierung fehlgeschlagen – versuche es trotzdem"
    fi
    c "lade $PKGS (arm64) …"
    sudo docker run --rm --platform linux/arm64 -v "$cache:/out" debian:trixie sh -c \
      "apt-get update -qq && cd /out && apt-get download -q $PKGS && chmod 644 /out/*.deb" \
      || die "Download fehlgeschlagen"
    sudo chown "$(id -u):$(id -g)" "$cache"/*.deb 2>/dev/null || true
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

wlan)
  # "qca_cld3_qca6750 ... Driver probe failed: -1", 4 ms nach der DMS-MAC, und
  # kein einziges Wort vom Treiber dazu. Ursache: der Treiber liest beim Start
  # WCNSS_qcom_cfg.ini. Fehlt sie, schweigt der Firmware-Lader, und die eigene
  # Fehlerzeile des Treibers ist zu diesem Zeitpunkt abgeschaltet.
  #
  # Die Datei liegt NICHT unter firmware/wlan/... - dort steht nur ein Verweis.
  # Das Ziel ist /vendor/etc/wifi/<chip>/WCNSS_qcom_cfg.ini (rund 2 KB) auf der
  # vendor-Partition. Genau dort habe ich beim ersten Versuch nicht gesucht.
  #
  # wlan_mac.bin braucht es nicht: sein Ziel liegt in persist, und der Treiber
  # liest es erst nach dem DMS-MAC-Weg - und der klappt ja.
  #
  # Welchen Pfad DIESER Treiber anfragt, steht in seinem Objektcode:
  #   grep -ao '[a-zA-Z0-9_/.-]*WCNSS_qcom_cfg[a-zA-Z0-9_/.-]*' wlan_hdd_main.o
  # Hier: wlan/qca_cld/qca_cld3_qca6750/ - die Stock-Ablage nutzt qca6750/.
  # Darum legen wir die Datei in beide Ordner.
  need_recovery
  c "vendor einhaengen"
  adb shell "mkdir -p /tmp/vnd
    for n in vendor_a vendor; do
      for t in erofs ext4 auto; do
        mount -t \$t -o ro /dev/block/by-name/\$n /tmp/vnd 2>/dev/null && break 2
      done
    done
    echo \"  Eintraege: \$(ls /tmp/vnd 2>/dev/null | wc -l)\""
  c "suche die Ini auf der vendor-Partition"
  found=$(adb shell "ls /tmp/vnd/etc/wifi/*/WCNSS_qcom_cfg.ini 2>/dev/null" | tr -d '\r')
  if [ -z "$found" ]; then
    # Breiter suchen, falls die Ablage abweicht.
    found=$(adb shell "find /tmp/vnd -name 'WCNSS_qcom_cfg.ini' -type f 2>/dev/null" | tr -d '\r')
  fi
  if [ -z "$found" ]; then
    adb shell "umount /tmp/vnd 2>/dev/null" >/dev/null 2>&1
    die "keine WCNSS_qcom_cfg.ini auf vendor gefunden.
       Pruefen, ob vendor ueberhaupt eingehaengt wurde:
         adb shell ls /tmp/vnd"
  fi
  for f in $found; do c "gefunden: $f  ($(adb shell "wc -c < $f" 2>/dev/null | tr -d '\r') Bytes)"; done
  # Der Chip dieses Geraets ist qca6750 – das sagt die Remoteproc-Firmware
  # (qca6750/wpss.mdt). peach_v2 und wcn6450 sind andere Chips derselben
  # Plattform; deren Ini waere die falsche. Also gezielt waehlen, nicht die
  # erste der Liste nehmen.
  src=$(echo "$found" | grep -m1 'qca6750' || true)
  [ -n "$src" ] || src=$(echo "$found" | head -1)
  c "verwende: $src"

  # Auch ins Backup legen, das der Rootfs-Bau nach /lib/firmware spiegelt -
  # sonst ist die Datei beim naechsten Bau wieder weg.
  # Auch hier updates/: beim Start legt noxis-firmware-links einen Verweis
  # "wlan" nach /vendor/firmware_mnt/image/wlan an, der eine echte Ablage
  # gleichen Namens verdecken kann. updates/ bleibt davon unberuehrt und wird
  # vom Firmware-Lader vorher durchsucht.
  for d in qca_cld3_qca6750 qca6750; do
    bdir="$HOME/noxis-backup/vendor-firmware/updates/wlan/qca_cld/$d"
    mkdir -p "$bdir"
    adb pull "$src" "$bdir/WCNSS_qcom_cfg.ini" >/dev/null 2>&1 \
      && c "ins Backup: ${bdir#$HOME/}" || c "Backup-Kopie fehlgeschlagen ($d)"
  done
  rm -rf "$HOME/noxis-backup/vendor-firmware/wlan/qca_cld" 2>/dev/null || true

  mount_root
  FW=$(fwdir)
  c "Firmware-Ablage im Rootfs: ${FW#$M}"
  # $FW/wlan ist ein Verweis auf /vendor/firmware_mnt/image/wlan (einer der
  # 335, die noxis-firmware-links anlegt). Im Recovery haengt firmware_mnt
  # nicht, der Verweis ist also tot und darin laesst sich nichts anlegen.
  #
  # Darum nach updates/: der Firmware-Lader des Kernels sucht
  #   1. firmware_class.path  2. /lib/firmware/updates/<release>
  #   3. /lib/firmware/updates  4. /lib/firmware/<release>  5. /lib/firmware
  # updates/ ist ein echtes Verzeichnis und liegt vor dem Verweis. So muessen
  # wir den bestehenden Verweis nicht anfassen – der zeigt im laufenden System
  # auf echte Firmware und soll bleiben.
  #
  n=0
  for d in qca_cld3_qca6750 qca6750; do
    tgt="$FW/updates/wlan/qca_cld/$d"
    mkdirs "$tgt"
    adb shell "cp $src $tgt/WCNSS_qcom_cfg.ini 2>&1; \
      [ -f $tgt/WCNSS_qcom_cfg.ini ] \
        && echo \"  ok updates/wlan/qca_cld/$d: \$(wc -c < $tgt/WCNSS_qcom_cfg.ini) Bytes\" \
        || echo \"  FEHLT $d\""
  done
  n=$(adb shell "ls $FW/updates/wlan/qca_cld/*/WCNSS_qcom_cfg.ini 2>/dev/null | wc -l" | tr -d '\r')
  if [ "${n:-0}" -eq 0 ]; then
    c "cp im Recovery ohne Wirkung – schiebe die Datei ueber den PC"
    tmpf=$(mktemp)
    adb pull "$src" "$tmpf" >/dev/null 2>&1 || die "konnte $src nicht holen"
    for d in qca_cld3_qca6750 qca6750; do
      adb push "$tmpf" "$FW/updates/wlan/qca_cld/$d/WCNSS_qcom_cfg.ini" 2>&1 | tail -1
    done
    rm -f "$tmpf"
    n=$(adb shell "ls $FW/updates/wlan/qca_cld/*/WCNSS_qcom_cfg.ini 2>/dev/null | wc -l" | tr -d '\r')
  fi
  c "jetzt im Rootfs:"
  adb shell "ls -l $FW/updates/wlan/qca_cld/*/WCNSS_qcom_cfg.ini 2>/dev/null || echo '  (nichts)'"
  adb shell "umount /tmp/vnd 2>/dev/null" >/dev/null 2>&1
  umount_root
  [ "${n:-0}" -ge 1 ] || die "Datei nicht ins Rootfs gekommen"
  ok "Ini eingelegt ($n Ablagen) - wirkt beim naechsten Start"
  c "Danach pruefen:  kernel/tools/noxis-shell.sh \"nmcli d\""
  ;;

osk)
  # Journal: 'phosh: Unable to toggle OSK: ... The name sm.puri.OSK0 was not
  # provided by any .service files'. squeekboard ist installiert und
  # screen-keyboard-enabled steht auf true, aber nichts startet die Tastatur:
  # die DBus-Aktivierungsdatei fehlt. Die legen wir hier nach.
  f=noxis-shell/usr/share/dbus-1/services/sm.puri.OSK0.service
  [ -f "$REPO/$f" ] || die "$REPO/$f fehlt – erst: git pull"
  need_recovery; mount_root
  adb shell "[ -x $M/usr/bin/squeekboard ] && echo da" 2>/dev/null | grep -q da \
    || { umount_root; die "squeekboard ist nicht installiert"; }
  adb shell "mkdir -p $M/usr/share/dbus-1/services" >/dev/null 2>&1
  adb push "$REPO/$f" "$M/usr/share/dbus-1/services/sm.puri.OSK0.service" >/dev/null 2>&1 \
    || { umount_root; die "push fehlgeschlagen"; }
  adb shell "chmod 644 $M/usr/share/dbus-1/services/sm.puri.OSK0.service" >/dev/null 2>&1
  adb shell "ls -la $M/usr/share/dbus-1/services/"
  ok "Tastatur per DBus startbar – wirkt beim naechsten Start"
  umount_root
  ;;

regdb)
  # "Direct firmware load for regulatory.db failed with error -2" und
  # "cfg80211: failed to load regulatory.db": die Funkregulierungs-Datenbank
  # fehlt. Ohne sie kennt der Kernel keine Laenderregeln - weder Kanaele noch
  # Sendeleistungen. Das Paket wireless-regdb war nie in der Paketliste.
  #
  # Die Datei ist nicht geraetespezifisch, sie liegt auf jedem Linux mit
  # wireless-regdb. Also vom PC nehmen, statt sie herunterzuladen.
  src=""
  for d in /lib/firmware /usr/lib/firmware; do
    [ -f "$d/regulatory.db" ] && { src="$d"; break; }
  done
  [ -n "$src" ] || die "regulatory.db auf diesem Rechner nicht gefunden.
       Gentoo:  emerge -av net-wireless/wireless-regdb
       Debian:  apt install wireless-regdb"
  c "nehme $src/regulatory.db ($(wc -c < "$src/regulatory.db") B)"
  need_recovery; mount_root
  FW=$(fwdir)
  mkdirs "$FW"
  for f in regulatory.db regulatory.db.p7s; do
    [ -f "$src/$f" ] || { c "  $f gibt es hier nicht (nur mit Signaturpruefung noetig)"; continue; }
    adb push "$src/$f" "$FW/$f" >/dev/null 2>&1 \
      && echo "  ok $f: $(adb shell "wc -c < $FW/$f" 2>/dev/null | tr -d '\r') B" \
      || c "  $f nicht uebertragen"
  done
  n=$(adb shell "ls $FW/regulatory.db 2>/dev/null | wc -l" | tr -d '\r')
  umount_root
  [ "${n:-0}" -ge 1 ] || die "regulatory.db nicht ins Rootfs gekommen"
  ok "regulatory.db eingelegt – wirkt beim naechsten Start"
  ;;

wpa2)
  # "lim_process_sae_auth_timeout: SAE auth timeout" + "Auth Failure occurred":
  # der Treiber meldet SAE (WPA3) als koennen, bekommt den Handschlag aber
  # nicht zustande. Router im gemischten WPA2/WPA3-Betrieb bieten SAE an, und
  # NetworkManager nimmt es dann auch.
  #
  # Pro Profil mit "nmcli c mod" zu schrauben nuetzt nichts: die
  # Einstellungen-App legt bei jeder Passworteingabe ein NEUES Profil an, mit
  # der vollen Standardliste WPA-PSK WPA-PSK-SHA256 FT-PSK SAE FT-SAE. Es muss
  # also ein Vorgabewert fuer alle Verbindungen sein.
  #
  # pmf=1 heisst "Protected Management Frames aus". SAE setzt PMF zwingend
  # voraus, also faellt SAE damit weg und es bleibt bei WPA2-PSK.
  #
  # ABWAEGUNG: damit ist WPA3 auf diesem Geraet aus, und der Schutz der
  # Verwaltungsrahmen entfaellt - letzteres erschwert sonst
  # Deauth-Angriffe. Das ist eine Notloesung fuer einen Treiber, dessen SAE
  # nicht funktioniert, keine gute Einstellung an sich. Zurueck mit "wpa3".
  need_recovery; mount_root
  d="$M/etc/NetworkManager/conf.d"
  adb shell "mkdir -p $d" >/dev/null 2>&1
  adb shell "printf '# Noxis – WPA2 erzwingen, weil SAE (WPA3) mit diesem Treiber\n# in eine Zeitueberschreitung laeuft: lim_process_sae_auth_timeout.\n# pmf=1 schaltet Protected Management Frames ab; SAE setzt PMF voraus und\n# faellt damit weg. Zurueck: noxis-diag.sh wpa3\n[connection]\nwifi-sec.pmf=1\n' > $d/95-noxis-wpa2.conf"
  adb shell "cat $d/95-noxis-wpa2.conf 2>/dev/null | sed 's/^/  /'"
  adb shell "[ -f $d/95-noxis-wpa2.conf ] && echo da" 2>/dev/null | grep -q da \
    || { umount_root; die "Datei nicht angelegt"; }
  # Vorhandene WLAN-Profile loeschen. Der Vorgabewert aus conf.d greift nur
  # dort, wo im Profil nichts Ausdrueckliches steht - hat die App beim Anlegen
  # key-mgmt=sae hineingeschrieben, bleibt es dabei. Darauf zu hoffen, dass
  # jemand das Netz von Hand "vergisst", ist unzuverlaessig.
  sc="$M/etc/NetworkManager/system-connections"
  adb shell "ls $sc/ 2>/dev/null | sed 's/^/  war da: /'"
  adb shell "grep -l 'wifi' $sc/*.nmconnection 2>/dev/null | xargs -r rm -f" >/dev/null 2>&1
  adb shell "ls $sc/*.nmconnection 2>/dev/null | wc -l | sed 's/^/  Profile jetzt: /'"
  ok "WPA2 erzwungen, WLAN-Profile geloescht – wirkt beim naechsten Start"
  c "Gespeicherte WLAN-Passwoerter sind damit weg; einmal neu eingeben."
  c "Rueckgaengig:  noxis-diag.sh wpa3"
  umount_root
  ;;

wpa3)
  # Die Notloesung von "wpa2" wieder entfernen.
  need_recovery; mount_root
  adb shell "rm -f $M/etc/NetworkManager/conf.d/95-noxis-wpa2.conf" >/dev/null 2>&1
  adb shell "[ -e $M/etc/NetworkManager/conf.d/95-noxis-wpa2.conf ] && echo da" 2>/dev/null \
    | grep -q da && { umount_root; die "Datei liess sich nicht entfernen"; }
  ok "WPA3/PMF wieder zugelassen – wirkt beim naechsten Start"
  umount_root
  ;;

macperm)
  # Noxis setzt per noxis-opsec eine zufaellige MAC (wifi.cloned-mac-address=
  # random). Nimmt die Firmware des WLAN-Moduls diese Adresse nicht an, sendet
  # es zwar, aber die Antwort des Routers geht an eine Adresse, die die
  # Firmware nicht kennt - fuer wpa_supplicant sieht das aus wie
  # "auth_no_resp_received", also genau der Fehler bei der Anmeldung.
  #
  # Dieser Modus legt eine eigene Datei mit hoeherer Nummer daneben, statt
  # 90-noxis.conf anzufassen: rueckgaengig machen heisst dann, eine Datei zu
  # loeschen, und die Opsec-Einstellung bleibt im Paket erhalten.
  #
  # ABWAEGUNG, die du kennen musst: mit der echten MAC ist dein Geraet in
  # fremden Netzen ueber die Hardware-Adresse wiedererkennbar. Das ist genau
  # das, was die zufaellige MAC verhindern soll. Nur zum Pruefen gedacht -
  # bestaetigt sich der Verdacht, suchen wir eine Loesung, die beides kann
  # (etwa "stable" je Netz statt "random" je Verbindung).
  need_recovery; mount_root
  d="$M/etc/NetworkManager/conf.d"
  adb shell "mkdir -p $d" >/dev/null 2>&1
  adb shell "printf '# Noxis – nur zum Pruefen: echte MAC statt zufaelliger.\n# Entfernen stellt die Opsec-Einstellung aus 90-noxis.conf wieder her.\n[device]\nwifi.scan-rand-mac-address=no\n\n[connection]\nwifi.cloned-mac-address=permanent\nethernet.cloned-mac-address=permanent\n' > $d/99-noxis-macperm.conf"
  adb shell "cat $d/99-noxis-macperm.conf 2>/dev/null | sed 's/^/  /'"
  adb shell "[ -f $d/99-noxis-macperm.conf ] && echo da" 2>/dev/null | grep -q da \
    || { umount_root; die "Datei nicht angelegt"; }
  ok "echte MAC gesetzt – wirkt beim naechsten Start"
  c "Rueckgaengig:  noxis-diag.sh macrand"
  umount_root
  ;;

macrand)
  # Die Pruefdatei von "macperm" wieder entfernen: zurueck zur zufaelligen MAC.
  need_recovery; mount_root
  adb shell "rm -f $M/etc/NetworkManager/conf.d/99-noxis-macperm.conf" >/dev/null 2>&1
  adb shell "[ -e $M/etc/NetworkManager/conf.d/99-noxis-macperm.conf ] && echo da" 2>/dev/null \
    | grep -q da && { umount_root; die "Datei liess sich nicht entfernen"; }
  ok "zurueck auf zufaellige MAC – wirkt beim naechsten Start"
  umount_root
  ;;

bdf)
  # "Board id: 0" und "BDF VER is 0, FW and BDF ver check skipped": die
  # Firmware laeuft ohne gueltige Funkkalibrierung. Dann empfaengt das Modul,
  # aber seine Sendungen kommen nicht an - das Bild von auth_no_resp_received.
  #
  # Der CNSS-Treiber kennt fuer die Board-Datei die Namen bdwlan.elf,
  # bdwlan.bin, die Praefixe bdwlan.e / bdwlan.b und bdwlan.dmy. Bei Nothing
  # liegt sie als qca6750/bdwlan.elf samt regdb.bin in der MODEM-Partition,
  # nicht in /vendor/firmware - dort sind nur die bdwlan.bXX.
  #
  # Dazu mein eigener Fehler: "vendorfw" hat ein echtes Verzeichnis
  # /lib/firmware/qca6750 angelegt. noxis-firmware-links legt seinen Verweis
  # auf die Modem-Partition aber nur an, wenn dort NICHTS Echtes steht - und
  # ueberspringt ihn seitdem. Dieser Modus raeumt das auf.
  need_recovery
  c "modem und vendor einhaengen"
  adb shell "mkdir -p /tmp/mdm /tmp/vnd
    for n in modem_a modem; do mount -t vfat -o ro /dev/block/by-name/\$n /tmp/mdm 2>/dev/null && break; done
    for n in vendor_a vendor; do
      for t in erofs ext4 auto; do mount -t \$t -o ro /dev/block/by-name/\$n /tmp/vnd 2>/dev/null && break 2; done
    done
    echo \"  modem: \$(ls /tmp/mdm 2>/dev/null | wc -l) Eintraege, vendor: \$(ls /tmp/vnd 2>/dev/null | wc -l)\""
  c "suche Board-Dateien (bdwlan*, regdb*)"
  adb shell "find /tmp/mdm /tmp/vnd -maxdepth 3 \( -name 'bdwlan*' -o -name 'regdb*' \) 2>/dev/null \
    | while read -r f; do echo \"  \$(wc -c < \"\$f\") B  \$f\"; done" | sort -k3

  mount_root
  FW=$(fwdir)
  c "Zustand im Rootfs: ${FW#$M}/qca6750"
  adb shell "if [ -L $FW/qca6750 ]; then echo '  Verweis auf '\$(readlink $FW/qca6750);
             elif [ -d $FW/qca6750 ]; then echo '  echtes Verzeichnis (verdeckt den Verweis!)'; ls $FW/qca6750 | head -8;
             else echo '  nicht vorhanden'; fi"
  # Das von vendorfw angelegte echte Verzeichnis entfernen, damit
  # noxis-firmware-links beim naechsten Start wieder seinen Verweis auf die
  # Modem-Partition legen kann. Die bdwlan.bXX bleiben erhalten - sie liegen
  # ohnehin in /vendor/firmware, das in firmware_class.path steht.
  if adb shell "[ -d $FW/qca6750 ] && [ ! -L $FW/qca6750 ] && echo ja" 2>/dev/null | grep -q ja; then
    c "entferne das verdeckende Verzeichnis"
    adb shell "rm -rf $FW/qca6750" >/dev/null 2>&1
    adb shell "[ -e $FW/qca6750 ] && echo '  FEHLER: noch da' || echo '  weg – der Verweis entsteht beim naechsten Start'"
  fi
  # Falls die Modem-Partition eine .elf-Board-Datei hat, zusaetzlich nach
  # updates/ legen: der Firmware-Lader durchsucht das vor /lib/firmware, und
  # dort kann kein Verweis dazwischenkommen.
  for f in bdwlan.elf bdwlan.bin regdb.bin; do
    src=$(adb shell "ls /tmp/mdm/image/qca6750/$f /tmp/mdm/qca6750/$f 2>/dev/null | head -1" | tr -d '\r')
    [ -n "$src" ] || continue
    mkdirs "$FW/updates/qca6750" 2>/dev/null || true
    adb shell "mkdir -p $FW/updates/qca6750; cp $src $FW/updates/qca6750/$f 2>&1; \
      [ -f $FW/updates/qca6750/$f ] && echo \"  ok updates/qca6750/$f: \$(wc -c < $FW/updates/qca6750/$f) B\" || echo \"  FEHLT $f\""
    bdir="$HOME/noxis-backup/vendor-firmware/updates/qca6750"
    mkdir -p "$bdir" && adb pull "$src" "$bdir/$f" >/dev/null 2>&1 && c "ins Backup: ${bdir#$HOME/}/$f"
  done
  adb shell "umount /tmp/mdm /tmp/vnd 2>/dev/null" >/dev/null 2>&1
  umount_root
  c "Danach pruefen:  sudo dmesg|grep -iE 'bdf|board id'|tail"
  ;;

usbnet-off)
  # Notausstieg: den Dienst abschalten, ohne das Rootfs neu zu bauen. Noetig,
  # wenn noxis-usbnet beim Start Aerger macht - eine fruehere Fassung riss mit
  # dem Neuanbinden des dwc3-Treibers den ganzen Kernel mit.
  need_recovery; mount_root
  adb shell "rm -f $M/etc/systemd/system/multi-user.target.wants/noxis-usbnet.service" >/dev/null 2>&1
  adb shell "[ -e $M/etc/systemd/system/multi-user.target.wants/noxis-usbnet.service ] && echo da" 2>/dev/null \
    | grep -q da && { umount_root; die "Dienst liess sich nicht abschalten"; }
  ok "noxis-usbnet abgeschaltet – wirkt beim naechsten Start"
  umount_root
  ;;

usbnet)
  # Schluss mit dem Abtippen auf der Bildschirmtastatur: Noxis meldet sich am
  # USB-Kabel als Netzwerkkarte, und der PC bekommt per SSH eine Shell darauf.
  # Holt openssh-server mit Abhaengigkeiten, legt Dienst und Skript ins System
  # und schaltet beides ein. Ohne Neubau.
  cache="$HOME/noxis-backup/debs/openssh"
  mkdir -p "$cache"
  if ! ls "$cache"/*.deb >/dev/null 2>&1; then
    command -v docker >/dev/null || die "docker fehlt"
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
      c "qemu-aarch64 fuer Docker registrieren"
      sudo docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 || true
    fi
    c "lade openssh-server (arm64) mit Abhaengigkeiten …"
    sudo docker run --rm --platform linux/arm64 -v "$cache:/out" debian:trixie sh -c \
      "apt-get update -qq && apt-get install -y -q --download-only -o Dir::Cache::archives=/out openssh-server && chmod 644 /out/*.deb" \
      || die "Download fehlgeschlagen"
    sudo chown "$(id -u):$(id -g)" "$cache"/*.deb 2>/dev/null || true
  fi
  ls "$cache"/*.deb | sed 's|.*/|  |'

  need_recovery; mount_root
  adb shell "mkdir -p $M/var/cache/noxis-debs" >/dev/null 2>&1
  for f in "$cache"/*.deb; do
    adb push "$f" "$M/var/cache/noxis-debs/" >/dev/null 2>&1 || die "push $(basename "$f") fehlgeschlagen"
  done
  # Der Dienst, der die .deb beim naechsten Start installiert
  for rel in noxis-hw/usr/lib/noxis/hw/noxis-install-debs \
             noxis-hw/usr/lib/systemd/system/noxis-install-debs.service \
             noxis-hw/usr/lib/noxis/hw/noxis-usbnet \
             noxis-hw/usr/lib/systemd/system/noxis-usbnet.service; do
    [ -f "$REPO/$rel" ] || die "$rel fehlt – erst: git pull"
    adb push "$REPO/$rel" "$M/${rel#*/}" >/dev/null 2>&1 || die "push $rel fehlgeschlagen"
  done
  adb shell "chmod 755 $M/usr/lib/noxis/hw/noxis-install-debs $M/usr/lib/noxis/hw/noxis-usbnet; \
    chmod 644 $M/usr/lib/systemd/system/noxis-install-debs.service $M/usr/lib/systemd/system/noxis-usbnet.service; \
    mkdir -p $M/etc/systemd/system/multi-user.target.wants; \
    ln -sf /usr/lib/systemd/system/noxis-install-debs.service $M/etc/systemd/system/multi-user.target.wants/noxis-install-debs.service; \
    ln -sf /usr/lib/systemd/system/noxis-usbnet.service $M/etc/systemd/system/multi-user.target.wants/noxis-usbnet.service" \
    >/dev/null 2>&1
  adb shell "[ -L $M/etc/systemd/system/multi-user.target.wants/noxis-usbnet.service ] && echo yes" 2>/dev/null \
    | grep -q yes || { umount_root; die "Dienst nicht verknuepft"; }
  ok "USB-Netz eingerichtet – greift beim naechsten Start"
  umount_root
  echo
  c "Danach vom PC aus:  kernel/tools/noxis-shell.sh"
  c "Der erste Start dauert etwas laenger, weil openssh installiert wird."
  ;;

vendorfw)
  # /vendor/firmware steht in firmware_class.path, aber die vendor-Partition
  # wird in Noxis nicht eingehaengt – dort liegt also nichts. Darin stecken die
  # Board-Daten, die der WLAN-Treiber beim Start laedt (bdwlan & Co.). Hier
  # schieben wir den schon geholten Ordner ins /lib/firmware des Systems.
  src="$HOME/noxis-backup/vendor-firmware"
  [ -d "$src" ] && [ -n "$(ls -A "$src" 2>/dev/null)" ] \
    || die "$src ist leer – erst: kernel/tools/pull-firmware.sh (Handy in der Recovery)"
  c "$(du -sh "$src" | cut -f1) aus $src"
  need_recovery; mount_root
  FW=$(fwdir)/updates
  c "Firmware-Ablage im Rootfs: ${FW#$M}"
  # Nach updates/, nicht direkt nach /lib/firmware. Dort legt
  # noxis-firmware-links beim Start Verweise auf die Modem-Partition an - und
  # zwar nur, wenn kein echtes Verzeichnis gleichen Namens im Weg steht. Ein
  # hierher geschobenes qca6750 hat genau diesen Verweis verdeckt und damit
  # die Board-Datei bdwlan.elf unerreichbar gemacht. updates/ wird vom
  # Firmware-Lader ohnehin zuerst durchsucht und kollidiert mit nichts.
  mkdirs "$FW"
  # Einzeln schieben: adb push eines Ordners legt ihn sonst verschachtelt ab.
  n=0
  for f in "$src"/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    if [ -d "$f" ]; then
      adb push "$f" "$FW/" >/dev/null 2>&1 && n=$((n + 1)) || c "  $b nicht uebertragen"
    else
      adb push "$f" "$FW/$b" >/dev/null 2>&1 && n=$((n + 1)) || c "  $b nicht uebertragen"
    fi
  done
  ok "$n Einträge nach ${FW#$M}"
  c "WLAN-relevante Dateien jetzt im System:"
  adb shell "ls $FW/ | grep -iE 'bd|wlan|qca|wcn|cnss' | head -20; echo; ls -d $FW/qca6750 2>/dev/null && ls $FW/qca6750 | head -20"
  umount_root
  ;;

gpu-off)
  # Die GPU-Umgebung (Turnip/Zink) global zu setzen kann die Sitzung oder die
  # GPU aufhaengen; dann greift der Watchdog und das Geraet startet neu.
  # Hier nehmen wir sie aus dem installierten System heraus, ohne Neubau.
  need_recovery; mount_root
  adb shell "rm -f $M/etc/environment.d/90-noxis-gpu.conf \
                   $M/etc/systemd/system/phosh.service.d/90-noxis-gpu.conf" >/dev/null 2>&1
  adb shell "[ -e $M/etc/environment.d/90-noxis-gpu.conf ] && echo da" 2>/dev/null | grep -q da \
    && { umount_root; die "konnte die GPU-Umgebung nicht entfernen"; }
  ok "GPU-Umgebung entfernt – Noxis startet wieder mit Software-Rendering"
  umount_root
  ;;

*)
  sed -n '2,20p' "$0"
  ;;
esac
