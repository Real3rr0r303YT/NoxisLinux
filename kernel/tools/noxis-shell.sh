#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
#
# Shell vom PC aufs LAUFENDE Noxis, ueber das USB-Kabel.
#
#   ./noxis-shell.sh                Shell oeffnen
#   ./noxis-shell.sh "<befehl>"     einen Befehl ausfuehren und Ausgabe zeigen
#   ./noxis-shell.sh --copy <datei> [ziel]   Datei aufs Handy legen
#
# Voraussetzung: auf dem Handy laeuft noxis-usbnet. Einschalten ohne Tippen:
#   kernel/tools/noxis-diag.sh usbnet      (Handy in der Recovery)
#
# Das ersetzt das Abtippen auf der Bildschirmtastatur. Fuer ein Handy, das gar
# nicht mehr hochkommt, ist weiterhin der Rescue zustaendig (noxis-rescue.sh).
set -uo pipefail

IP=172.16.42.1
ME=172.16.42.2/24
USER_NAME="${NOXIS_USER:-}"

c()   { printf '\033[1;36m[shell]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

command -v ssh >/dev/null || die "ssh fehlt (apt install openssh-client / emerge net-misc/openssh)"

# ---------------------------------------------------------------- USB-Netz
# Nicht nur Ping pruefen: die Noxis-Firewall kann ICMP verwerfen, waehrend
# SSH laeuft. Darum gilt auch ein offener Port 22 als erreichbar.
reach() {
  ping -c1 -W1 "$IP" >/dev/null 2>&1 && return 0
  timeout 2 bash -c "exec 3<>/dev/tcp/$IP/22" 2>/dev/null && return 0
  return 1
}

# Die Abfrage genau dann ankuendigen, wenn sie auch kommt. Steht die
# sudo-Berechtigung noch (etwa von noxis-try.sh kurz vorher), fragt sudo gar
# nicht - eine Ankuendigung ins Leere fuehrt dann dazu, dass man sein Passwort
# ins offene Terminal tippt, wo es im Klartext erscheint.
ensure_sudo() {
  sudo -n true 2>/dev/null && return 0
  echo
  c "Jetzt kommt die sudo-Abfrage: dein PC-Passwort, NICHT die Handy-PIN."
  c "Die Eingabe bleibt unsichtbar. Erscheinen beim Tippen Zeichen,"
  c "ist es KEINE Passwortabfrage – dann nichts eingeben und abbrechen."
  sudo -v || die "ohne sudo laesst sich die Schnittstelle nicht einrichten"
}

bring_up() {
  reach && return 0
  c "suche das USB-Netz des Handys …"
  ensure_sudo
  local i n drv
  for i in $(seq 1 30); do
    for n in $(ls /sys/class/net); do
      drv=$(basename "$(readlink -f "/sys/class/net/$n/device/driver" 2>/dev/null)" 2>/dev/null || true)
      case "$drv" in cdc_ncm|cdc_ether|rndis_host) ;; *) continue ;; esac
      ip -4 addr show "$n" 2>/dev/null | grep -q 172.16.42.2 && continue
      c "Schnittstelle $n ($drv)"
      sudo ip link set "$n" up
      sudo ip addr add "$ME" dev "$n" 2>/dev/null || true
      sleep 2
      reach && { ok "Handy antwortet auf $IP"; return 0; }
    done
    reach && { ok "Handy antwortet auf $IP"; return 0; }
    sleep 1
  done
  return 1
}

if ! bring_up; then
  cat >&2 <<EOF
[FAIL] Kein USB-Netz vom Handy.

  * Laeuft Noxis gerade (nicht Recovery, nicht Bootloader)?
  * Ist noxis-usbnet eingeschaltet? Ohne Tippen am Handy:
      Handy in die Recovery, dann:  kernel/tools/noxis-diag.sh usbnet
  * Kabel direkt am Rechner, nicht ueber einen Hub.

Zustand am Rechner:
$(ip -4 addr show 2>/dev/null | grep -A2 -E "cdc_ncm|usb" | head -6)
$(ip -4 addr show | grep -B2 172.16.42.2 | head -4)

Antwortet das Handy weder auf Ping noch auf Port 22, aber die Schnittstelle
ist da, dann laeuft der Dienst auf dem Handy nicht zu Ende. Nachsehen mit:
  kernel/tools/noxis-try.sh --log
EOF
  exit 1
fi

# ---------------------------------------------------------------- Benutzer
if [ -z "$USER_NAME" ]; then
  # Der Benutzername wird bei der Einrichtung gewaehlt; aus greeter.conf im
  # letzten Backup raten, sonst fragen.
  USER_NAME=$(grep -rhs '^user *=' "$HOME/noxis-backup"/*/etc/noxis/greeter.conf 2>/dev/null \
               | tail -1 | sed 's/.*= *//' | tr -d '\r')
fi
if [ -z "$USER_NAME" ]; then
  read -rp "Benutzername auf dem Handy: " USER_NAME
  [ -n "$USER_NAME" ] || die "kein Benutzername"
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

case "${1:-}" in
  --copy)
    [ $# -ge 2 ] || die "Nutzung: $0 --copy <datei> [ziel]"
    src="$2"; dst="${3:-/home/$USER_NAME/}"
    [ -f "$src" ] || die "$src gibt es nicht"
    command -v scp >/dev/null || die "scp fehlt"
    scp "${SSH_OPTS[@]}" "$src" "$USER_NAME@$IP:$dst" && ok "kopiert nach $dst"
    ;;
  "")
    echo
  c "Jetzt kommt die SSH-Abfrage: deine Noxis-PIN, NICHT das PC-Passwort."
  c "Auch hier bleibt die Eingabe unsichtbar."
    ssh "${SSH_OPTS[@]}" "$USER_NAME@$IP"
    ;;
  *)
    ssh "${SSH_OPTS[@]}" "$USER_NAME@$IP" "$@"
    ;;
esac
