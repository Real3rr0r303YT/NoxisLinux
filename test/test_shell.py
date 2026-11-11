#!/usr/bin/env python3
"""Tests für noxis-shell: greetd-IPC, Greeter-Logik, Desktop-Modus, Branding-Dateien."""
import importlib.machinery
import importlib.util
import json
import os
import pwd
import random
import socket
import stat
import struct
import sys
import tempfile
import threading
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(ROOT, "noxis-shell")
GREETER = os.path.join(PKG, "usr/lib/noxis/greeter")
sys.path.insert(0, GREETER)
import core  # noqa: E402
from greetd_ipc import Greetd  # noqa: E402

loader = importlib.machinery.SourceFileLoader("noxis_dock", os.path.join(PKG, "usr/lib/noxis/noxis-dock"))
spec = importlib.util.spec_from_loader("noxis_dock", loader)
dock = importlib.util.module_from_spec(spec)
loader.exec_module(dock)

passed = failed = 0


def check(name, cond, info=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ✓ {name}")
    else:
        failed += 1
        print(f"  ✗ {name} {info}")


# ---------------------------------------------------------------- Fake-greetd
class FakeGreetd(threading.Thread):
    """Minimaler greetd: PIN 147147, optional zusätzliche Abfragen."""

    def __init__(self, path, extra=None):
        super().__init__(daemon=True)
        self.path, self.extra = path, extra or []
        self.log = []
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(1)

    def recv(self, c):
        n = struct.unpack("=I", c.recv(4))[0]
        buf = b""
        while len(buf) < n:
            buf += c.recv(n - len(buf))
        m = json.loads(buf)
        self.log.append(m)
        return m

    def send(self, c, m):
        d = json.dumps(m).encode()
        c.sendall(struct.pack("=I", len(d)) + d)

    def run(self):
        c, _ = self.srv.accept()
        try:
            while True:
                m = self.recv(c)
                t = m["type"]
                if t == "create_session":
                    self.queue = list(self.extra) + [("secret", "Passwort:")]
                    k, txt = self.queue.pop(0)
                    self.send(c, {"type": "auth_message", "auth_message_type": k, "auth_message": txt})
                elif t == "post_auth_message_response":
                    if self.queue:
                        k, txt = self.queue.pop(0)
                        self.send(c, {"type": "auth_message", "auth_message_type": k, "auth_message": txt})
                    elif m.get("response") == "147147":
                        self.send(c, {"type": "success"})
                    else:
                        self.send(c, {"type": "error", "error_type": "auth_error", "description": "pam"})
                elif t == "start_session":
                    self.send(c, {"type": "success"})
                elif t == "cancel_session":
                    self.send(c, {"type": "success"})
        except (OSError, struct.error):
            pass


def greetd_case(extra, pin):
    d = tempfile.mkdtemp()
    path = os.path.join(d, "greetd.sock")
    srv = FakeGreetd(path, extra)
    srv.start()
    g = Greetd(path)
    res = g.login("noxis", pin, ["phosh-session"], ["NOXIS_MODE=desktop"])
    g.close()
    srv.join(timeout=2)
    return res, srv.log


print("== greetd-IPC")
(ok, err), log = greetd_case([], "147147")
check("richtige PIN → Sitzung startet", ok and err is None, err)
start = [m for m in log if m["type"] == "start_session"]
check("start_session mit cmd + env", start and start[0]["cmd"] == ["phosh-session"] and start[0]["env"] == ["NOXIS_MODE=desktop"], start)
check("Benutzer korrekt übergeben", log[0] == {"type": "create_session", "username": "noxis"})
(ok, err), log = greetd_case([], "000000")
check("falsche PIN → 'Falsche PIN'", not ok and err == "Falsche PIN", err)
check("falsche PIN → cancel_session", log[-1]["type"] == "cancel_session")
check("keine Sitzung bei falscher PIN", not any(m["type"] == "start_session" for m in log))
(ok, err), log = greetd_case([("info", "Hinweis")], "147147")
check("Info-Meldung wird quittiert", ok, err)
(ok, err), log = greetd_case([("secret", "Neue PIN:")], "147147")
check("zweite Geheim-Abfrage → abbrechen statt PIN wiederholen", not ok and log[-1]["type"] == "cancel_session", err)
check("PIN nur einmal gesendet", sum(1 for m in log if m.get("response") == "147147") == 1)
(ok, err), log = greetd_case([("visible", "Benutzername:")], "147147")
check("sichtbare Abfrage → abbrechen", not ok and log[-1]["type"] == "cancel_session", err)

print("== Greeter-Logik")
k = core.keypad(shuffle=False)
check("Feld: 12 Tasten, ⌫ Platz 10, ✓ Platz 12", len(k) == 12 and k[9] == "⌫" and k[11] == "✓")
check("ohne Mischen: 1–9, 0 unten", k[:9] == list("123456789") and k[10] == "0")
layouts = {tuple(core.keypad(True, random.Random(i))) for i in range(20)}
check("Mischen ergibt verschiedene Felder", len(layouts) > 15)
check("jede Ziffer genau einmal", all(sorted(x for x in l if x.isdigit()) == list("0123456789") for l in layouts))
check("Wartezeit: 4 Versuche frei, dann 30/60/120 s, max 900",
      [core.backoff(i) for i in (1, 3, 4, 5, 6, 12)] == [0, 0, 30, 60, 120, 900])
P = pwd.struct_passwd
users = [P(("root", "x", 0, 0, "", "/root", "/bin/bash")),
         P(("svc", "x", 1001, 1001, "", "/", "/usr/sbin/nologin")),
         P(("noxis", "x", 1000, 1000, "", "/home/noxis", "/bin/bash")),
         P(("gast", "x", 1002, 1002, "", "/home/gast", "/bin/bash"))]
check("Benutzer aus Konfiguration", core.pick_user({"user": "gast"}, users) == "gast")
check("sonst erster normaler Benutzer", core.pick_user({"user": ""}, users) == "noxis")
check("unbekannter Konfig-Benutzer → Rückfall", core.pick_user({"user": "weg"}, users) == "noxis")
check("nologin-Konten werden übersprungen", core.pick_user({"user": ""}, users[:2]) is None)
ps = core.PinState(max_len=4)
for d in "12345x":
    ps.add(d)
check("PIN: nur Ziffern, Maximallänge", len(ps) == 4)
ps.back()
check("PIN: Rücktaste", len(ps) == 3)
check("PIN: take() gibt PIN und leert", ps.take() == "123" and len(ps) == 0)
d = tempfile.mkdtemp()
conf = os.path.join(d, "g.conf")
open(conf, "w").write("[greeter]\nuser = noxis\nshuffle = false\npin_length = 6\n")
c = core.load_conf(conf)
check("Konfiguration lesen", c == {"user": "noxis", "shuffle": False, "pin_length": 6, "show_user": False}, c)
check("Standardwerte ohne Datei", core.load_conf(os.path.join(d, "fehlt"))["shuffle"] is True)


def drm(states):
    root = tempfile.mkdtemp()
    for name, st in states.items():
        os.makedirs(os.path.join(root, name))
        open(os.path.join(root, name, "status"), "w").write(st + "\n")
    return root


r = drm({"card0-DSI-1": "connected", "card0-DP-1": "disconnected"})
check("nur Phone-Display → Mobil", core.default_mode(r) == "mobile")
r = drm({"card0-DSI-1": "connected", "card0-DP-1": "connected"})
check("DP angeschlossen → Desktop", core.default_mode(r) == "desktop")
r = drm({"card0-DSI-1": "connected", "card1-DVI-I-1": "connected"})
check("DisplayLink (evdi, DVI-I) → Desktop", core.default_mode(r) == "desktop")
check("Ausgänge mit intern/extern", core.connected_outputs(r) == [("DSI-1", True), ("DVI-I-1", False)])

print("== Desktop-Modus (noxis-dock)")
conf = dock.load_conf([os.path.join(PKG, "etc/noxis/dock.conf")])
check("dock.conf: Standardwerte", conf == {"internal": "on", "position": "right", "scale": 1.0, "osk": "off", "interval": 2.0}, conf)
dsi = {"name": "DSI-1", "enabled": True, "scale": 2.5, "transform": "normal",
       "modes": [{"width": 1080, "height": 2392, "current": True, "preferred": True}]}
hdmi = {"name": "HDMI-A-1", "enabled": False, "scale": 1.0, "transform": "normal",
        "modes": [{"width": 2560, "height": 1440, "preferred": True}, {"width": 1920, "height": 1080}]}
check("logische Größe Phone (Skala 2.5)", dock.logical_size(dsi) == (432, 956))
check("Drehung 90° tauscht Breite/Höhe", dock.logical_size(dict(dsi, transform="90")) == (956, 432))
docked, args = dock.plan([dsi], conf)
check("nur Phone: nicht angedockt, keine Änderung", docked is False and args == [])
docked, args = dock.plan([dict(dsi, enabled=False)], conf)
check("Phone-Display aus → wieder an", args == ["--output", "DSI-1", "--on"])
docked, args = dock.plan([dsi], conf, desktop_forced=True)
check("Desktop-Sitzung ohne Bildschirm → Desktop-Verhalten", docked is True)
docked, args = dock.plan([dsi, hdmi], conf)
check("extern rechts vom Phone", docked and args == ["--output", "HDMI-A-1", "--on", "--scale", "1", "--pos", "432,0",
                                                      "--output", "DSI-1", "--on", "--pos", "0,0"], args)
docked, args = dock.plan([dsi, hdmi], dict(conf, position="left"))
check("extern links", args[6] == "0,0" and args[-1] == "2560,0", args)
docked, args = dock.plan([dsi, hdmi], dict(conf, position="above", scale=2.0))
check("extern oben mit Skala 2", "--scale" in args and args[args.index("--scale") + 1] == "2" and args[-1] == "0,720", args)
docked, args = dock.plan([dsi, hdmi], dict(conf, internal="off"))
check("Phone-Display aus im Desktop-Modus", args == ["--output", "HDMI-A-1", "--on", "--scale", "1", "--pos", "0,0",
                                                     "--output", "DSI-1", "--off"], args)
docked, args = dock.plan([hdmi], conf)
check("nur extern (kein internes Display)", args == ["--output", "HDMI-A-1", "--on", "--scale", "1", "--pos", "0,0"], args)

# Ablauf mit Fake-wlr-randr und Fake-gsettings
bin_dir = tempfile.mkdtemp()
state = os.path.join(bin_dir, "outputs.json")
calls = os.path.join(bin_dir, "calls.log")
gs = os.path.join(bin_dir, "gsettings.val")
open(gs, "w").write("true")
with open(os.path.join(bin_dir, "wlr-randr"), "w") as f:
    f.write(f"#!/bin/sh\nif [ \"$1\" = --json ]; then cat '{state}'; else echo \"wlr-randr $*\" >> '{calls}'; fi\n")
with open(os.path.join(bin_dir, "gsettings"), "w") as f:
    f.write(f"#!/bin/sh\nif [ \"$1\" = get ]; then cat '{gs}'; else echo \"$4\" > '{gs}'; echo \"gsettings $*\" >> '{calls}'; fi\n")
for b in ("wlr-randr", "gsettings"):
    os.chmod(os.path.join(bin_dir, b), stat.S_IRWXU)
os.environ["PATH"] = bin_dir + os.pathsep + os.environ["PATH"]


def set_outputs(o):
    json.dump(o, open(state, "w"))


def take_calls():
    if not os.path.exists(calls):
        return []
    lines = open(calls).read().splitlines()
    os.remove(calls)
    return lines


dk = dock.Dock(conf, "mobile")
set_outputs([dsi])
dk.step()
take_calls()
dk.step()
check("ohne Änderung keine Befehle", take_calls() == [])
set_outputs([dsi, hdmi])
dk.step()
cl = take_calls()
check("Bildschirm an → wlr-randr + Tastatur aus", any(c.startswith("wlr-randr --output HDMI-A-1 --on") for c in cl)
      and "gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled false" in cl, cl)
check("Zustand angedockt", dk.docked is True)
set_outputs([dsi, dict(hdmi, enabled=True)])
dk.step()
check("angedockt, unverändert → keine Befehle", take_calls() == [])
set_outputs([dsi])
dk.step()
cl = take_calls()
check("Bildschirm ab → Tastatur-Einstellung wiederhergestellt",
      "gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true" in cl, cl)
check("Zustand Mobil", dk.docked is False)
open(gs, "w").write("false")
dk2 = dock.Dock(dict(conf, osk="on"), "mobile")
set_outputs([dsi, hdmi])
dk2.step()
check("osk=on → Tastatur bleibt unverändert", not any("gsettings set" in c for c in take_calls()))

print("== Branding & Paket")
for svg in ("noxis-mark.svg", "noxis-mark-mono.svg", "noxis-wordmark.svg", "noxis-icon.svg",
            "noxis-wallpaper-portrait.svg", "noxis-wallpaper-landscape.svg"):
    p = os.path.join(PKG, "usr/share/noxis/branding", svg)
    try:
        ET.parse(p)
        check(f"{svg} gültiges SVG", True)
    except ET.ParseError as e:
        check(f"{svg} gültiges SVG", False, e)
th = os.path.join(PKG, "usr/share/plymouth/themes/noxis")
check("Plymouth-Bilder vorhanden", all(os.path.getsize(os.path.join(th, f)) > 1000 for f in ("logo.png", "wordmark.png")))
scr = open(os.path.join(th, "noxis.script")).read()
check("Plymouth-Skript nutzt nur vorhandene Bilder",
      all(os.path.exists(os.path.join(th, n)) for n in __import__("re").findall(r'Image\("([^"]+)"\)', scr)))
check("Plymouth-Skript: Klammern ausgeglichen", scr.count("{") == scr.count("}") and scr.count("(") == scr.count(")"))
css = open(os.path.join(GREETER, "style.css")).read()
src = open(os.path.join(GREETER, "noxis-greeter")).read()
used = set(__import__("re").findall(r'"(noxis-[a-z-]+)"', src)) - {"noxis-wordmark.svg"}
used = {u for u in used if not u.endswith(".svg")}
missing = [u for u in used if "." + u not in css]
check("alle CSS-Klassen des Greeters definiert", not missing, missing)
check("CSS: Klammern ausgeglichen", css.count("{") == css.count("}"))
for bg in ("noxis-portrait.png", "noxis-landscape.png"):
    check(f"Hintergrund {bg}", os.path.getsize(os.path.join(PKG, "usr/share/backgrounds/noxis", bg)) > 10000)
ov = open(os.path.join(PKG, "usr/share/glib-2.0/schemas/90_noxis-shell.gschema.override")).read()
check("Schema-Override zeigt auf vorhandene Hintergründe",
      all(os.path.exists(PKG + u) for u in __import__("re").findall(r"file://(/[^']+)", ov)))
for f in ("noxis-mobile.desktop", "noxis-desktop.desktop"):
    t = open(os.path.join(PKG, "usr/share/wayland-sessions", f)).read()
    check(f"{f}: NOXIS_MODE + phosh-session", "NOXIS_MODE=" in t and "phosh-session" in t)
check("Greeter- und Dock-Skripte ausführbar",
      all(os.access(os.path.join(PKG, p), os.X_OK) for p in ("usr/lib/noxis/noxis-dock", "usr/lib/noxis/greeter/noxis-greeter")))
check("Greeter-Sitzungen = Wayland-Sitzungen",
      set(core.SESSIONS) == {"mobile", "desktop"} and all(s["cmd"] == ["phosh-session"] for s in core.SESSIONS.values()))
pi = open(os.path.join(PKG, "DEBIAN/postinst")).read()
check("postinst: noxis-dm als display-manager.service", "noxis-dm.service /etc/systemd/system/display-manager.service" in pi)
check("postinst: Greeter-Systemnutzer ohne Shell", "--system" in pi and "nologin" in pi)
unit = open(os.path.join(PKG, "usr/lib/systemd/system/noxis-dm.service")).read()
check("Unit: kein PrivateNetwork/ProtectHome (Sitzungen erben das)", "PrivateNetwork=yes" not in unit and "ProtectHome=" not in unit)
check("Unit: startet noxis-dm, Alias display-manager", "ExecStart=/usr/lib/noxis/dm/noxis-dm" in unit and "Alias=display-manager.service" in unit)
ctl = open(os.path.join(PKG, "DEBIAN/control")).read()
check("Paket hängt nicht mehr von greetd ab", "greetd" not in ctl.split("Depends:")[1].split("\n")[0])
for f in ("noxis", "noxis-greeter"):
    t = open(os.path.join(PKG, "etc/pam.d", f)).read()
    check(f"PAM {f}: pam_systemd (über common-session bzw. direkt)", "common-session" in t or "pam_systemd" in t)

print(f"\n{passed} bestanden, {failed} fehlgeschlagen")
sys.exit(1 if failed else 0)
