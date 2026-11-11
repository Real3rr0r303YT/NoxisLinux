#!/usr/bin/env python3
"""Tests for noxis-shell: greetd IPC, greeter logic, desktop mode, branding files, package."""
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
    """Minimal greetd: PIN 147147, optional extra prompts."""

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
check("correct PIN → session starts", ok and err is None, err)
start = [m for m in log if m["type"] == "start_session"]
check("start_session with cmd + env", start and start[0]["cmd"] == ["phosh-session"] and start[0]["env"] == ["NOXIS_MODE=desktop"], start)
check("user passed correctly", log[0] == {"type": "create_session", "username": "noxis"})
(ok, err), log = greetd_case([], "000000")
check("wrong PIN → 'wrong_pin'", not ok and err == "wrong_pin", err)
check("wrong PIN → cancel_session", log[-1]["type"] == "cancel_session")
check("no session after a wrong PIN", not any(m["type"] == "start_session" for m in log))
(ok, err), log = greetd_case([("info", "Hinweis")], "147147")
check("info message acknowledged", ok, err)
(ok, err), log = greetd_case([("secret", "Neue PIN:")], "147147")
check("second secret prompt → cancel instead of resending the PIN", not ok and log[-1]["type"] == "cancel_session", err)
check("PIN sent only once", sum(1 for m in log if m.get("response") == "147147") == 1)
(ok, err), log = greetd_case([("visible", "Benutzername:")], "147147")
check("visible prompt → cancel", not ok and log[-1]["type"] == "cancel_session", err)

print("== Greeter logic")
k = core.keypad(shuffle=False)
check("pad: 12 keys, ⌫ slot 10, ✓ slot 12", len(k) == 12 and k[9] == "⌫" and k[11] == "✓")
check("unshuffled: 1–9, 0 at the bottom", k[:9] == list("123456789") and k[10] == "0")
layouts = {tuple(core.keypad(True, random.Random(i))) for i in range(20)}
check("shuffling gives different pads", len(layouts) > 15)
check("every digit exactly once", all(sorted(x for x in l if x.isdigit()) == list("0123456789") for l in layouts))
check("lockout: 3 free attempts, then 30/60/120 s, max 900",
      [core.backoff(i) for i in (1, 3, 4, 5, 6, 12)] == [0, 0, 30, 60, 120, 900])
P = pwd.struct_passwd
users = [P(("root", "x", 0, 0, "", "/root", "/bin/bash")),
         P(("svc", "x", 1001, 1001, "", "/", "/usr/sbin/nologin")),
         P(("noxis", "x", 1000, 1000, "", "/home/noxis", "/bin/bash")),
         P(("gast", "x", 1002, 1002, "", "/home/gast", "/bin/bash"))]
check("user from config", core.pick_user({"user": "gast"}, users) == "gast")
check("else first regular user", core.pick_user({"user": ""}, users) == "noxis")
check("unknown config user → fallback", core.pick_user({"user": "weg"}, users) == "noxis")
check("nologin accounts skipped", core.pick_user({"user": ""}, users[:2]) is None)
ps = core.PinState(max_len=4)
for d in "12345x":
    ps.add(d)
check("PIN: digits only, max length", len(ps) == 4)
ps.back()
check("PIN: backspace", len(ps) == 3)
check("PIN: take() returns and clears", ps.take() == "123" and len(ps) == 0)
d = tempfile.mkdtemp()
conf = os.path.join(d, "g.conf")
open(conf, "w").write("[greeter]\nuser = noxis\nshuffle = false\npin_length = 6\n")
c = core.load_conf(conf)
check("read config", c == {"user": "noxis", "shuffle": False, "pin_length": 6, "show_user": False}, c)
check("defaults without file", core.load_conf(os.path.join(d, "fehlt"))["shuffle"] is True)


def drm(states):
    root = tempfile.mkdtemp()
    for name, st in states.items():
        os.makedirs(os.path.join(root, name))
        open(os.path.join(root, name, "status"), "w").write(st + "\n")
    return root


r = drm({"card0-DSI-1": "connected", "card0-DP-1": "disconnected"})
check("phone display only → mobile", core.default_mode(r) == "mobile")
r = drm({"card0-DSI-1": "connected", "card0-DP-1": "connected"})
check("DP connected → desktop", core.default_mode(r) == "desktop")
r = drm({"card0-DSI-1": "connected", "card1-DVI-I-1": "connected"})
check("DisplayLink (evdi, DVI-I) → Desktop", core.default_mode(r) == "desktop")
check("outputs with internal/external flag", core.connected_outputs(r) == [("DSI-1", True), ("DVI-I-1", False)])

print("== Desktop mode (noxis-dock)")
conf = dock.load_conf([os.path.join(PKG, "etc/noxis/dock.conf")])
check("dock.conf: defaults", conf == {"internal": "on", "position": "right", "scale": 1.0, "osk": "off", "interval": 2.0}, conf)
dsi = {"name": "DSI-1", "enabled": True, "scale": 2.5, "transform": "normal",
       "modes": [{"width": 1080, "height": 2392, "current": True, "preferred": True}]}
hdmi = {"name": "HDMI-A-1", "enabled": False, "scale": 1.0, "transform": "normal",
        "modes": [{"width": 2560, "height": 1440, "preferred": True}, {"width": 1920, "height": 1080}]}
check("logical size of the phone (scale 2.5)", dock.logical_size(dsi) == (432, 956))
check("90° rotation swaps width/height", dock.logical_size(dict(dsi, transform="90")) == (956, 432))
docked, args = dock.plan([dsi], conf)
check("phone only: not docked, no change", docked is False and args == [])
docked, args = dock.plan([dict(dsi, enabled=False)], conf)
check("phone display off → back on", args == ["--output", "DSI-1", "--on"])
docked, args = dock.plan([dsi], conf, desktop_forced=True)
check("desktop session without display → desktop behaviour", docked is True)
docked, args = dock.plan([dsi, hdmi], conf)
check("external right of the phone", docked and args == ["--output", "HDMI-A-1", "--on", "--scale", "1", "--pos", "432,0",
                                                      "--output", "DSI-1", "--on", "--pos", "0,0"], args)
docked, args = dock.plan([dsi, hdmi], dict(conf, position="left"))
check("external left", args[6] == "0,0" and args[-1] == "2560,0", args)
docked, args = dock.plan([dsi, hdmi], dict(conf, position="above", scale=2.0))
check("external above with scale 2", "--scale" in args and args[args.index("--scale") + 1] == "2" and args[-1] == "0,720", args)
docked, args = dock.plan([dsi, hdmi], dict(conf, internal="off"))
check("phone display off in desktop mode", args == ["--output", "HDMI-A-1", "--on", "--scale", "1", "--pos", "0,0",
                                                     "--output", "DSI-1", "--off"], args)
docked, args = dock.plan([hdmi], conf)
check("external only (no internal display)", args == ["--output", "HDMI-A-1", "--on", "--scale", "1", "--pos", "0,0"], args)

# flow with fake wlr-randr and fake gsettings
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
check("no change → no commands", take_calls() == [])
set_outputs([dsi, hdmi])
dk.step()
cl = take_calls()
check("display plugged → wlr-randr + keyboard off", any(c.startswith("wlr-randr --output HDMI-A-1 --on") for c in cl)
      and "gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled false" in cl, cl)
check("state docked", dk.docked is True)
set_outputs([dsi, dict(hdmi, enabled=True)])
dk.step()
check("docked, unchanged → no commands", take_calls() == [])
set_outputs([dsi])
dk.step()
cl = take_calls()
check("display unplugged → keyboard setting restored",
      "gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true" in cl, cl)
check("state mobile", dk.docked is False)
open(gs, "w").write("false")
dk2 = dock.Dock(dict(conf, osk="on"), "mobile")
set_outputs([dsi, hdmi])
dk2.step()
check("osk=on → keyboard untouched", not any("gsettings set" in c for c in take_calls()))

print("== Branding & package")
for svg in ("noxis-mark.svg", "noxis-mark-mono.svg", "noxis-wordmark.svg", "noxis-icon.svg",
            "noxis-wallpaper-portrait.svg", "noxis-wallpaper-landscape.svg"):
    p = os.path.join(PKG, "usr/share/noxis/branding", svg)
    try:
        ET.parse(p)
        check(f"{svg} valid SVG", True)
    except ET.ParseError as e:
        check(f"{svg} valid SVG", False, e)
th = os.path.join(PKG, "usr/share/plymouth/themes/noxis")
check("Plymouth images present", all(os.path.getsize(os.path.join(th, f)) > 1000 for f in ("logo.png", "wordmark.png")))
scr = open(os.path.join(th, "noxis.script")).read()
check("Plymouth script uses existing images only",
      all(os.path.exists(os.path.join(th, n)) for n in __import__("re").findall(r'Image\("([^"]+)"\)', scr)))
check("Plymouth script: balanced brackets", scr.count("{") == scr.count("}") and scr.count("(") == scr.count(")"))
css = open(os.path.join(GREETER, "style.css")).read()
src = open(os.path.join(GREETER, "noxis-greeter")).read()
used = set(__import__("re").findall(r'"(noxis-[a-z-]+)"', src)) - {"noxis-wordmark.svg"}
used = {u for u in used if not u.endswith(".svg")}
missing = [u for u in used if "." + u not in css]
check("all greeter CSS classes defined", not missing, missing)
check("CSS: balanced braces", css.count("{") == css.count("}"))
for bg in ("noxis-portrait.png", "noxis-landscape.png"):
    check(f"wallpaper {bg}", os.path.getsize(os.path.join(PKG, "usr/share/backgrounds/noxis", bg)) > 10000)
ov = open(os.path.join(PKG, "usr/share/glib-2.0/schemas/90_noxis-shell.gschema.override")).read()
check("schema override points to existing wallpapers",
      all(os.path.exists(PKG + u) for u in __import__("re").findall(r"file://(/[^']+)", ov)))
for f in ("noxis-mobile.desktop", "noxis-desktop.desktop"):
    t = open(os.path.join(PKG, "usr/share/wayland-sessions", f)).read()
    check(f"{f}: NOXIS_MODE + phosh-session", "NOXIS_MODE=" in t and "phosh-session" in t)
check("greeter and dock scripts executable",
      all(os.access(os.path.join(PKG, p), os.X_OK) for p in ("usr/lib/noxis/noxis-dock", "usr/lib/noxis/greeter/noxis-greeter")))
check("greeter sessions = Wayland sessions",
      set(core.SESSIONS) == {"mobile", "desktop"} and all(s["cmd"] == ["phosh-session"] for s in core.SESSIONS.values()))
pi = open(os.path.join(PKG, "DEBIAN/postinst")).read()
check("postinst: noxis-dm as display-manager.service", "noxis-dm.service /etc/systemd/system/display-manager.service" in pi)
check("postinst: greeter system user without shell", "--system" in pi and "nologin" in pi)
unit = open(os.path.join(PKG, "usr/lib/systemd/system/noxis-dm.service")).read()
check("unit: no PrivateNetwork/ProtectHome (sessions inherit it)", "PrivateNetwork=yes" not in unit and "ProtectHome=" not in unit)
check("unit: starts noxis-dm, alias display-manager", "ExecStart=/usr/lib/noxis/dm/noxis-dm" in unit and "Alias=display-manager.service" in unit)
ctl = open(os.path.join(PKG, "DEBIAN/control")).read()
check("package no longer depends on greetd", "greetd" not in ctl.split("Depends:")[1].split("\n")[0])
for f in ("noxis", "noxis-greeter"):
    t = open(os.path.join(PKG, "etc/pam.d", f)).read()
    check(f"PAM {f}: pam_systemd (via common-session or directly)", "common-session" in t or "pam_systemd" in t)

print("== Status row & languages in the greeter")
sysr = tempfile.mkdtemp()
for iface, st in (("lo", "unknown"), ("wlan0", "up"), ("wg0-mullvad", "unknown"), ("rmnet_data0", "down")):
    os.makedirs(os.path.join(sysr, "class/net", iface))
    open(os.path.join(sysr, "class/net", iface, "operstate"), "w").write(st)
bat = os.path.join(sysr, "class/power_supply/battery")
os.makedirs(bat)
for k, v in (("type", "Battery"), ("capacity", "67"), ("status", "Charging")):
    open(os.path.join(bat, k), "w").write(v)
st = core.status(sysr)
check("VPN detected (wg0-mullvad)", st["vpn"] is True)
check("Wi-Fi icon", st["net_icon"] == "network-wireless-signal-good-symbolic", st)
check("battery 67 %, charging icon level 70", st["battery"] == 67 and st["bat_icon"] == "battery-level-70-charging-symbolic", st)
os.remove(os.path.join(sysr, "class/net/wlan0/operstate"))
shutil_rm = __import__("shutil").rmtree
shutil_rm(os.path.join(sysr, "class/net/wg0-mullvad"))
st = core.status(sysr)
check("no VPN, no link → offline icon", st["vpn"] is False and st["net_icon"] == "network-offline-symbolic", st)
st = core.status(tempfile.mkdtemp())
check("no battery → hidden", st["battery"] is None)
import i18n  # noqa: E402
keys = set(__import__("re").findall(r'i18n\.tr\(self\.lang, "([a-z_]+)"', src))
keys |= set(__import__("re").findall(r'i18n\.tr\(lang, "([a-z_]+)"', src))
keys |= {"mobile", "desktop", "reboot", "poweroff", "wrong_pin", "extra", "pin_expired", "error", "det_network", "det_lang"}
check(f"all {len(keys)} greeter texts exist in 7 languages", keys <= set(i18n.T) and all(len(i18n.T[k]) == 7 for k in keys), keys - set(i18n.T))
icons = set(__import__("re").findall(r'"([a-z-]+-symbolic)"', src + open(os.path.join(GREETER, "core.py")).read()))
check(f"{len(icons)} symbolic icons (Adwaita names)", all(i.endswith("-symbolic") for i in icons) and len(icons) >= 10, icons)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
