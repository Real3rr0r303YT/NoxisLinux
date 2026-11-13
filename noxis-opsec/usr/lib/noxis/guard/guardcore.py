# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
"""Noxis Guard fuer Noxis Linux: Einstellungen, Statuspruefung, Regeln.

Portiert von Noxis Guard (Noxis OS, Android). Wird von der App (Benutzer),
dem Helfer (root, pkexec) und dem Dienst (root) gemeinsam benutzt.
"""
import configparser
import os
import re
import subprocess

CONF = os.environ.get("NOXIS_GUARD_CONF", "/etc/noxis/guard.conf")
RESOLVED_DROPIN = "/etc/systemd/resolved.conf.d/95-noxis-guard.conf"
NM_CONF = "/etc/NetworkManager/conf.d/90-noxis.conf"

REBOOT_HOURS = [0, 4, 8, 12, 18, 24, 36, 72]
OFF_MIN = [0, 5, 10, 15, 30, 60]
DNS = {  # Name → resolved-DNS-Zeile (DNS-over-TLS)
    "quad9": ("Quad9", "9.9.9.9#dns.quad9.net 149.112.112.112#dns.quad9.net 2620:fe::fe#dns.quad9.net"),
    "mullvad": ("Mullvad DNS", "194.242.2.2#dns.mullvad.net 2a07:e340::2#dns.mullvad.net"),
}
DEFAULTS = {"reboot_hours": "18", "wifi_off_min": "0", "bt_off_min": "0",
            "allow_2g": "no", "dns": "quad9"}


def load(path=None):
    cp = configparser.ConfigParser()
    cp.read(path or CONF)
    s = cp["guard"] if cp.has_section("guard") else {}
    return {k: s.get(k, v) for k, v in DEFAULTS.items()}


def validate(key, value):
    """→ Fehlertext oder None. Nur bekannte Schluessel und Werte."""
    if key == "reboot_hours":
        return None if value.isdigit() and int(value) in REBOOT_HOURS else "ungueltige Stundenzahl"
    if key in ("wifi_off_min", "bt_off_min"):
        return None if value.isdigit() and int(value) in OFF_MIN else "ungueltige Minutenzahl"
    if key == "allow_2g":
        return None if value in ("yes", "no") else "yes oder no"
    if key == "dns":
        return None if value in DNS else "unbekannter DNS-Anbieter"
    return "unbekannter Schluessel"


def save(conf, path=None):
    path = path or CONF
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write("# Noxis Guard – Made by 3rr0r303YT on TikTok\n[guard]\n")
        for k in DEFAULTS:
            f.write(f"{k} = {conf.get(k, DEFAULTS[k])}\n")
    os.replace(tmp, path)


def run(cmd, timeout=8):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (OSError, subprocess.SubprocessError):
        return 127, ""


def active(unit):
    return run(["systemctl", "is-active", "--quiet", unit])[0] == 0


# ---------------------------------------------------------------- 2G
def modem_id(run=run):
    rc, out = run(["mmcli", "-L"])
    m = re.search(r"/Modem/(\d+)", out) if rc == 0 else None
    return m.group(1) if m else None


def parse_modes(text):
    """mmcli -K → (aktuell erlaubt {set}, [(erlaubt {set}, bevorzugt)] unterstuetzt)."""
    cur = set()
    sup = []
    for line in text.splitlines():
        k, _, v = line.partition(":")
        k, v = k.strip(), v.strip()
        if k == "modem.generic.current-modes":
            cur = _allowed(v)
        elif k.startswith("modem.generic.supported-modes.value"):
            sup.append((_allowed(v), _preferred(v)))
    return cur, sup


def _allowed(v):
    m = re.search(r"allowed:\s*([^;]+)", v)
    return {x.strip() for x in m.group(1).split(",")} if m else set()


def _preferred(v):
    m = re.search(r"preferred:\s*(\S+)", v)
    return m.group(1) if m and m.group(1) != "none" else None


def pick_no2g(sup):
    """Die groesste unterstuetzte Kombination ohne 2G (bevorzugt mit Vorrang)."""
    cands = [(a, p) for a, p in sup if a and "2g" not in a]
    if not cands:
        return None
    cands.sort(key=lambda ap: (len(ap[0]), ap[1] is not None), reverse=True)
    return cands[0]


def two_g_allowed(run=run):
    mid = modem_id(run)
    if not mid:
        return None                      # kein Modem: unbekannt
    rc, out = run(["mmcli", "-m", mid, "-K"])
    cur, _ = parse_modes(out) if rc == 0 else (set(), [])
    return "2g" in cur if cur else None


def apply_2g(allow, run=run):
    mid = modem_id(run)
    if not mid:
        return False
    rc, out = run(["mmcli", "-m", mid, "-K"])
    if rc != 0:
        return False
    cur, sup = parse_modes(out)
    if allow:
        best = max(sup, key=lambda ap: len(ap[0]), default=None)
    else:
        if "2g" not in cur:
            return True
        best = pick_no2g(sup)
    if not best:
        return False
    args = ["mmcli", "-m", mid, "--set-allowed-modes=" + "|".join(sorted(best[0]))]
    if best[1]:
        args.append("--set-preferred-mode=" + best[1])
    return run(args, timeout=20)[0] == 0


# ---------------------------------------------------------------- Status
def status(conf=None):
    """Liste (Titel, ok, Hinweis); ok=None heisst "nicht pruefbar"."""
    conf = conf or load()
    items = []
    rc, out = run(["mullvad", "lockdown-mode", "get"])
    lock = rc == 0 and re.search(r":\s*on\b", out.lower()) is not None
    items.append(("Mullvad-Killswitch", lock and active("noxis-firewall.service"),
                  "Mullvad anmelden, dann unten einschalten"))
    rc, out = run(["resolvectl", "status"])
    items.append(("DNS verschluesselt (DNS-over-TLS)", rc == 0 and "+DNSOverTLS" in out,
                  "systemd-resolved laeuft nicht oder DoT ist aus"))
    g2 = two_g_allowed()
    items.append(("2G gesperrt", None if g2 is None else not g2,
                  "kein Modem gefunden" if g2 is None else "Unter Funk „2G erlauben“ ausschalten"))
    items.append(("USB-Daten gesperrt, wenn gesperrt", active("noxis-usblock.service"),
                  "Unter Gerätesperre einschalten"))
    items.append(("Automatischer Neustart", int(conf["reboot_hours"]) > 0,
                  "Unter Gerätesperre eine Zeit wählen"))
    nm = _read(NM_CONF)
    items.append(("Keine Verbindungspruefung", "[connectivity]" in nm and "enabled=false" in nm,
                  "NetworkManager-Einstellung fehlt"))
    items.append(("Zufaellige MAC-Adresse", "cloned-mac-address=random" in nm,
                  "NetworkManager-Einstellung fehlt"))
    rc, out = run(["gsettings", "get", "org.gnome.desktop.notifications", "show-in-lock-screen"])
    items.append(("Benachrichtigungen auf dem Sperrbildschirm verborgen", rc == 0 and out.strip() == "false",
                  "Unten unter Gerätesperre ausschalten"))
    items.append(("Firewall aktiv", active("noxis-firewall.service"), "noxis-firewall.service laeuft nicht"))
    return items


def _read(p):
    try:
        with open(p) as f:
            return f.read()
    except OSError:
        return ""


def dns_dropin(key):
    name, servers = DNS[key]
    return ("# Noxis Guard – " + name + " (DNS-over-TLS)\n[Resolve]\n"
            f"DNS={servers}\nFallbackDNS=\nDNSOverTLS=yes\n")


def due(since, now, minutes):
    """True, wenn ein Zustand seit `since` mindestens `minutes` anhaelt (0 = aus)."""
    return bool(minutes) and since is not None and now - since >= minutes * 60
