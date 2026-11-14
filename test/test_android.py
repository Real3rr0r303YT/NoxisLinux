#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
"""Tests fuer Noxis Android (androidcore): Zustand lesen, Knopf, Hinweise."""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "noxis-hw/usr/lib/noxis/android"))
import androidcore as a  # noqa: E402

passed = failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1; print(f"  ✓ {name}")
    else:
        failed += 1; print(f"  ✗ {name} {detail}")


print("\nNoxis Android")

kv = a.parse_kv("kernel=ok\npaket=ok\nabbild=fehlt\nnetz=blockiert\ncontainer=aus\nsitzung=aus\n")
check("Ausgabe eingelesen", kv["kernel"] == "ok" and kv["abbild"] == "fehlt" and len(kv) == 6)
check("Muell stoert nicht", a.parse_kv("bla\n\nkernel=ok\n=x\ny=\n") == {"kernel": "ok"})
check("leere Eingabe", a.parse_kv("") == {} and a.parse_kv(None) == {})

bereit = {"kernel": "ok", "paket": "ok", "abbild": "ok", "netz": "ok", "sitzung": "aus"}
check("alles da -> starten", a.action(bereit) == "start")
check("laeuft -> beenden", a.action({**bereit, "sitzung": "an"}) == "stop")
check("kein Abbild -> einrichten", a.action({**bereit, "abbild": "fehlt"}) == "einrichten")
check("Kernel kann nicht -> kein Knopf", a.action({**bereit, "kernel": "fehlt"}) is None)
check("Paket fehlt -> kein Knopf", a.action({**bereit, "paket": "fehlt"}) is None)
check("Knopfbeschriftung passt", a.label({**bereit, "abbild": "fehlt"})[0] == "Android einrichten"
      and a.label({**bereit, "kernel": "fehlt"})[0] == "Nicht moeglich")

check("Killswitch blockiert -> Hinweis, solange das Abbild fehlt",
      any("Mullvad" in h for h in a.blockers({**bereit, "abbild": "fehlt", "netz": "blockiert"})))
check("Killswitch stoert nicht mehr, wenn das Abbild da ist",
      a.blockers({**bereit, "netz": "blockiert"}) == [])
check("fehlendes Abbild ist kein Hindernis", a.blockers({**bereit, "abbild": "fehlt"}) == [])
check("ungeprueft gibt keinen Hinweis", a.blockers({}) == [])

r = a.rows({**bereit, "netz": "blockiert"})
check("vier Zeilen mit Zustand", len(r) == 4 and r[0][2] is True and r[3][2] is False)
check("ungeprueft wird als solches gezeigt", a.rows({})[0][2] is None and a.rows({})[0][1] == "ungeprueft")
check("start braucht keine Rechte, einrichten schon",
      not a.needs_root("start") and a.needs_root("einrichten") and a.needs_root("weg"))

print(f"\n{passed} passed, {failed} failed\n")
sys.exit(1 if failed else 0)
