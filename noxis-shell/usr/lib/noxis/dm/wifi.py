# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
"""WLAN fuer die Ersteinrichtung. Laeuft als root im noxis-dm.

Das Passwort landet nie auf einer Kommandozeile (dort koennte es jeder per
ps lesen): es wird als NetworkManager-Keyfile mit Modus 0600 geschrieben,
danach laedt nmcli die Verbindung und schaltet sie ein.
"""
import os
import re
import subprocess
import uuid as uuidlib

NM_DIR = "etc/NetworkManager/system-connections"
_SPLIT = re.compile(r"(?<!\\):")


def _fields(line):
    return [f.replace("\\:", ":").replace("\\\\", "\\") for f in _SPLIT.split(line)]


def parse_scan(text):
    """nmcli -t -f IN-USE,SSID,SIGNAL,SECURITY → [{ssid, signal, secure, active}], staerkstes zuerst."""
    best = {}
    for line in text.splitlines():
        f = _fields(line)
        if len(f) < 4 or not f[1]:
            continue          # versteckte Netze ohne Namen
        try:
            sig = int(f[2])
        except ValueError:
            sig = 0
        sec = f[3].strip()
        net = {"ssid": f[1], "signal": sig, "secure": sec not in ("", "--"),
               "active": f[0].strip() == "*"}
        old = best.get(f[1])
        if not old or sig > old["signal"] or net["active"]:
            if old and old["active"]:
                net["active"] = True
            best[f[1]] = net
    return sorted(best.values(), key=lambda n: (not n["active"], -n["signal"], n["ssid"].lower()))


def scan(run=subprocess.run):
    try:
        r = run(["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list",
                 "--rescan", "yes"], capture_output=True, text=True, timeout=25)
    except (OSError, subprocess.SubprocessError) as e:
        raise RuntimeError(f"nmcli: {e}") from e
    if r.returncode != 0:
        raise RuntimeError((r.stderr or "no WLAN").strip().splitlines()[-1])
    return parse_scan(r.stdout)


def check(ssid, psk):
    """→ Fehlertext oder None."""
    if not isinstance(ssid, str) or not ssid or len(ssid.encode()) > 32 or any(c in ssid for c in "\n\r\0"):
        return "invalid ssid"
    if psk is None or psk == "":
        return None
    if not isinstance(psk, str):
        return "invalid password"
    if re.fullmatch(r"[0-9a-fA-F]{64}", psk):
        return None
    if not 8 <= len(psk) <= 63 or any(ord(c) < 32 or ord(c) > 126 for c in psk):
        return "password must be 8-63 characters"
    return None


def _esc(v):
    """GKeyFile-Wert: Backslash verdoppeln, fuehrendes Leerzeichen schuetzen."""
    v = v.replace("\\", "\\\\")
    return "\\s" + v[1:] if v.startswith(" ") else v


def keyfile(ssid, psk, uid):
    raw = ";".join(str(b) for b in ssid.encode()) + ";"
    name = "".join(c for c in ssid if c.isprintable())
    out = ["[connection]", f"id={_esc(name)}", f"uuid={uid}", "type=wifi", "autoconnect=true", "",
           "[wifi]", "mode=infrastructure", f"ssid={raw}", ""]
    if psk:
        out += ["[wifi-security]", "key-mgmt=wpa-psk", f"psk={_esc(psk)}", ""]
    out += ["[ipv4]", "method=auto", "", "[ipv6]", "addr-gen-mode=stable-privacy", "method=auto", ""]
    return "\n".join(out)


def connect(ssid, psk, root="/", run=subprocess.run):
    bad = check(ssid, psk)
    if bad:
        raise ValueError(bad)
    uid = str(uuidlib.uuid4())
    d = os.path.join(root, NM_DIR)
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(d, f"noxis-{uid}.nmconnection")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(keyfile(ssid, psk, uid))
    if root != "/":
        return uid
    try:
        run(["nmcli", "connection", "load", path], capture_output=True, timeout=15)
        r = run(["nmcli", "-w", "40", "connection", "up", "uuid", uid],
                capture_output=True, text=True, timeout=50)
    except (OSError, subprocess.SubprocessError) as e:
        r = None
        err = str(e)
    if r is None or r.returncode != 0:
        err = err if r is None else ((r.stderr or "connect failed").strip().splitlines() or ["connect failed"])[-1]
        # Falsches Passwort o. ae.: keine Leiche zuruecklassen
        try:
            run(["nmcli", "connection", "delete", "uuid", uid], capture_output=True, timeout=15)
        except (OSError, subprocess.SubprocessError):
            pass
        if os.path.exists(path):
            os.unlink(path)
        raise RuntimeError(err)
    return uid
