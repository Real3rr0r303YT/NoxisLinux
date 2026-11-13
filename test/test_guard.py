#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
"""Tests fuer Noxis Guard (guardcore): Einstellungen, 2G-Logik, Zeitregeln."""
import ast
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GD = os.path.join(ROOT, "noxis-opsec/usr/lib/noxis/guard")
sys.path.insert(0, GD)
import guardcore as g  # noqa: E402

passed = failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1; print(f"  ✓ {name}")
    else:
        failed += 1; print(f"  ✗ {name} {detail}")


d = tempfile.mkdtemp()
conf = os.path.join(d, "guard.conf")
check("Standardwerte ohne Datei", g.load(conf) == g.DEFAULTS)
c = g.load(conf); c["reboot_hours"] = "24"; g.save(c, conf)
check("speichern + laden", g.load(conf)["reboot_hours"] == "24")
check("mitgelieferte guard.conf = Standard",
      g.load(os.path.join(ROOT, "noxis-opsec/etc/noxis/guard.conf")) == g.DEFAULTS)
check("gueltige Werte", all(g.validate(k, v) is None for k, v in
      [("reboot_hours", "18"), ("wifi_off_min", "30"), ("allow_2g", "no"), ("dns", "mullvad")]))
check("ungueltige Werte abgelehnt", all(g.validate(k, v) for k, v in
      [("reboot_hours", "5"), ("wifi_off_min", "-1"), ("allow_2g", "1"), ("dns", "evil"), ("x", "1"),
       ("reboot_hours", "18; rm -rf /")]))

K = """modem.generic.current-modes                     : allowed: 2g, 3g, 4g; preferred: 4g
modem.generic.supported-modes.length            : 4
modem.generic.supported-modes.value[1]          : allowed: 2g, 3g, 4g; preferred: 4g
modem.generic.supported-modes.value[2]          : allowed: 3g, 4g; preferred: 4g
modem.generic.supported-modes.value[3]          : allowed: 4g; preferred: none
modem.generic.supported-modes.value[4]          : allowed: 2g; preferred: none
"""
cur, sup = g.parse_modes(K)
check("aktuelle Modi gelesen", cur == {"2g", "3g", "4g"}, cur)
check("ohne 2G: groesste Kombination 3g+4g", g.pick_no2g(sup) == ({"3g", "4g"}, "4g"), g.pick_no2g(sup))


class FakeRun:
    def __init__(self, k): self.k, self.calls = k, []

    def __call__(self, cmd, timeout=8):
        self.calls.append(cmd)
        if cmd[:2] == ["mmcli", "-L"]:
            return 0, "/org/freedesktop/ModemManager1/Modem/0 [QUALCOMM] SM7635\n"
        if "-K" in cmd:
            return 0, self.k
        return 0, ""


fr = FakeRun(K)
check("2G erkannt", g.two_g_allowed(fr) is True)
check("2G sperren setzt 3g|4g", g.apply_2g(False, fr) and
      ["mmcli", "-m", "0", "--set-allowed-modes=3g|4g", "--set-preferred-mode=4g"] in fr.calls, fr.calls)
check("kein Modem → unbekannt", g.two_g_allowed(lambda c, timeout=8: (0, "No modems were found")) is None)

check("due: 0 = aus", not g.due(0, 10**6, 0))
check("due: zu frueh", not g.due(100, 100 + 59 * 60, 60))
check("due: faellig", g.due(100, 100 + 60 * 60, 60))
check("DNS-Drop-in mit DoT", "DNSOverTLS=yes" in g.dns_dropin("quad9") and "dns.quad9.net" in g.dns_dropin("quad9"))

for f in ("usr/bin/noxis-guard", "usr/lib/noxis/guard/noxis-guard-helper", "usr/lib/noxis/guard/noxis-guard-daemon"):
    p = os.path.join(ROOT, "noxis-opsec", f)
    src = open(p).read()
    ok = True
    try:
        ast.parse(src)
    except SyntaxError:
        ok = False
    check(f"{f}: Syntax, ausfuehrbar, Lizenz + Credit",
          ok and os.access(p, os.X_OK) and "GPL-3.0" in src and "3rr0r303YT" in src)

# ---- Tor-Browser-Starter: Kopie pro Benutzer, Daten bleiben bei Updates
import subprocess  # noqa: E402
t = tempfile.mkdtemp()
src = os.path.join(t, "src/Browser"); os.makedirs(src)
with open(os.path.join(src, "start-tor-browser"), "w") as f:
    f.write("#!/bin/sh\necho started\n")
os.chmod(os.path.join(src, "start-tor-browser"), 0o755)
open(os.path.join(src, "tbb_version.json"), "w").write("v1")
env = dict(os.environ, HOME=os.path.join(t, "h"), NOXIS_TOR_SRC=os.path.join(t, "src"))
env.pop("XDG_DATA_HOME", None)
launcher = os.path.join(ROOT, "noxis-opsec/usr/bin/noxis-tor-browser")
r = subprocess.run(["sh", launcher], env=env, capture_output=True, text=True)
dst = os.path.join(t, "h/.local/share/noxis/tor-browser")
check("Tor Browser startet aus beschreibbarer Kopie", r.stdout.strip() == "started" and os.path.isdir(dst), r.stderr)
os.makedirs(os.path.join(dst, "Browser/TorBrowser/Data"))
open(os.path.join(dst, "Browser/TorBrowser/Data/x"), "w").write("lesezeichen")
open(os.path.join(src, "tbb_version.json"), "w").write("v2")
subprocess.run(["sh", launcher], env=env, capture_output=True)
check("Update behaelt Profil/Lesezeichen",
      open(os.path.join(dst, "Browser/TorBrowser/Data/x")).read() == "lesezeichen"
      and open(os.path.join(dst, ".noxis-src")).read().strip() == "v2")
b = open(os.path.join(ROOT, "build-noxis-linux.sh")).read()
check("Firefox-Mobilpaket hat den Debian-Namen", "firefox-esr-mobile-config" in b and "mobile-config-firefox" not in b)
check("Tor-Starter im Desktop-Eintrag, xwayland im Rootfs", "Exec=noxis-tor-browser" in b and "xwayland" in b)

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
