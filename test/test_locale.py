#!/usr/bin/env python3
"""Tests: 7 languages, time zone detection, first-boot setup (noxis-dm), build-time language choice."""
import importlib.machinery
import importlib.util
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GREETER = os.path.join(ROOT, "noxis-shell/usr/lib/noxis/greeter")
DMDIR = os.path.join(ROOT, "noxis-shell/usr/lib/noxis/dm")
sys.path[:0] = [GREETER, DMDIR]
import i18n  # noqa: E402
import setup  # noqa: E402

loader = importlib.machinery.SourceFileLoader("noxis_dm", os.path.join(DMDIR, "noxis-dm"))
spec = importlib.util.spec_from_loader("noxis_dm", loader)
dm = importlib.util.module_from_spec(spec)
loader.exec_module(dm)

passed = failed = 0


def check(name, cond, info=""):
    global passed, failed
    passed += bool(cond)
    failed += not cond
    print(f"  {'✓' if cond else '✗'} {name}{'' if cond else ' ' + str(info)}")


print("== Languages")
check("exactly 7 languages: de tr en fr bg ru uk", i18n.ORDER == ["de", "tr", "en", "fr", "bg", "ru", "uk"])
bad = [k for k, v in i18n.T.items() if len(v) != 7 or not all(x.strip() for x in v)]
check("every text translated 7×", not bad, bad)
check("lockout text has {s} in every language", all("{s}" in x for x in i18n.T["wait"]))
check("7 weekdays / 12 months per language",
      all(len(i18n.WEEKDAYS[l]) == 7 and len(i18n.MONTHS[l]) == 12 for l in i18n.ORDER))
tm = time.struct_time((2026, 11, 11, 13, 42, 0, 2, 315, 0))
expect = {"de": "Mittwoch, 11. November", "tr": "11 Kasım Çarşamba", "en": "Wednesday, November 11",
          "fr": "Mercredi 11 novembre", "bg": "Сряда, 11 ноември", "ru": "Среда, 11 ноября", "uk": "Середа, 11 листопада"}
for l, e in expect.items():
    check(f"date {l}: {e}", i18n.date_text(l, tm) == e, i18n.date_text(l, tm))
check("LANG=tr_TR.UTF-8 → tr", i18n.lang_from_env({"LANG": "tr_TR.UTF-8"}) == "tr")
check("LC_ALL wins over LANG", i18n.lang_from_env({"LANG": "de_DE.UTF-8", "LC_ALL": "uk_UA.UTF-8"}) == "uk")
check("unknown language → en", i18n.lang_from_env({"LANG": "ja_JP.UTF-8"}) == "en")
check("all locales UTF-8, all default zones exist",
      all(v[1].endswith(".UTF-8") and (v[3] is None or setup.valid_tz(v[3])) for v in i18n.LANGS.values()))

print("== Time zone detection")
cases = [("262", "de", "Europe/Berlin", "network"), ("286", "en", "Europe/Istanbul", "network"),
         ("284", "en", "Europe/Sofia", "network"), ("255", "en", "Europe/Kyiv", "network"),
         ("208", "de", "Europe/Paris", "network"), ("250", "ru", "Europe/Moscow", "network"),
         ("310", "en", "America/New_York", "network"), (None, "fr", "Europe/Paris", "lang"),
         (None, "uk", "Europe/Kyiv", "lang"), (None, "en", "UTC", "none"), ("999", "tr", "Europe/Istanbul", "lang")]
for mcc, lang, tz, src in cases:
    got = setup.suggest(lang, mcc)
    check(f"MCC {mcc or '–'} + {lang} → {tz} ({src})", got[:2] == (tz, src), got[:2])
check("Russia: whole country list offered", len(setup.suggest("ru", "250")[2]) > 10)
check("Russian speaker in Ukraine → Europe/Kyiv", setup.suggest("ru", "255")[0] == "Europe/Kyiv")
check("SIM abroad wins over language (de phone in Turkey)", setup.suggest("de", "286")[0] == "Europe/Istanbul")
for tz in ("../../etc/passwd", "Europe/../../x", "foo", "", None, "Europe/Berlin\n", "/etc/shadow"):
    check(f"rejected: {tz!r}", not setup.valid_tz(tz))
for tz in ("UTC", "America/Argentina/Buenos_Aires", "Asia/Kolkata", "Europe/Kyiv"):
    check(f"accepted: {tz}", setup.valid_tz(tz))
check(f"{len(setup.all_zones())} zones in the list", len(setup.all_zones()) > 300)


def fake_run(lst, kv):
    def run(cmd, **_):
        class R:
            stdout = lst if cmd[1] == "-L" else kv
        return R()
    return run


check("MCC from ModemManager (26201 → 262)", setup.detect_mcc(fake_run(
    "    /org/freedesktop/ModemManager1/Modem/0 [QUALCOMM] SM7635", "modem.3gpp.operator-code : 26201\n")) == "262")
check("no modem → None", setup.detect_mcc(fake_run("No modems were found", "")) is None)
check("mmcli missing → None", setup.detect_mcc(lambda *a, **k: (_ for _ in ()).throw(FileNotFoundError())) is None)

print("== Apply (temporary root)")


def make_root():
    r = tempfile.mkdtemp()
    zi = os.path.join(r, "usr/share/zoneinfo")
    os.makedirs(os.path.join(zi, "Europe"))
    shutil.copy("/usr/share/zoneinfo/zone.tab", zi)
    for z in ("Europe/Istanbul", "Europe/Berlin"):
        shutil.copy(os.path.join("/usr/share/zoneinfo", z), os.path.join(zi, z))
    shutil.copy("/usr/share/zoneinfo/UTC", zi)
    return r


r = make_root()
setup.apply("tr", "Europe/Istanbul", r, compile_schemas=False)
rd = lambda p: open(os.path.join(r, p)).read()  # noqa: E731
check("LANG=tr_TR.UTF-8", rd("etc/default/locale") == "LANG=tr_TR.UTF-8\n")
check("/etc/localtime → Europe/Istanbul", os.readlink(os.path.join(r, "etc/localtime")) == "/usr/share/zoneinfo/Europe/Istanbul")
check("/etc/timezone", rd("etc/timezone") == "Europe/Istanbul\n")
check("Turkish keyboard (console + Phosh)", 'XKBLAYOUT="tr"' in rd("etc/default/keyboard")
      and "('xkb', 'tr')" in rd("usr/share/glib-2.0/schemas/95_noxis-lang.gschema.override"))
check("setup-done written", setup.is_done(r))
try:
    setup.apply("xx", "Europe/Berlin", r, compile_schemas=False)
    check("unknown language refused", False)
except ValueError:
    check("unknown language refused", True)
try:
    setup.apply("de", "Europe/Nowhere", r, compile_schemas=False)
    check("unknown zone refused", False)
except ValueError:
    check("unknown zone refused", True)
check("refused calls changed nothing", os.readlink(os.path.join(r, "etc/localtime")).endswith("Istanbul"))

print("== noxis-dm setup protocol")
r2 = make_root()
a = dm.Authenticator(dict(dm.load_conf("/nonexistent"), setup_root=r2, vt=0))
info = a.dispatch({"type": "noxis_setup_info", "lang": "de"})
check("first boot: setup needed, suggestion Europe/Berlin", info.get("needed") is True and info.get("suggested") == "Europe/Berlin", info.get("suggested"))
check("full zone list delivered", len(info.get("all_zones", [])) > 300)
check("invalid zone → error", a.dispatch({"type": "noxis_setup", "lang": "de", "timezone": "../../etc/shadow"})["type"] == "error")
check("invalid language → error", a.dispatch({"type": "noxis_setup", "lang": "jp", "timezone": "UTC"})["type"] == "error")
check("setup without login on first boot → success", a.dispatch({"type": "noxis_setup", "lang": "de", "timezone": "Europe/Berlin"})["type"] == "success")
check("afterwards: setup not needed", a.dispatch({"type": "noxis_setup_info", "lang": "de"})["needed"] is False)
check("second setup refused (no changes without login)", a.dispatch({"type": "noxis_setup", "lang": "ru", "timezone": "UTC"})["type"] == "error"
      and open(os.path.join(r2, "etc/default/locale")).read() == "LANG=de_DE.UTF-8\n")

print("== Build script: language choice")
src = open(os.path.join(ROOT, "build-noxis-linux.sh")).read()
funcs = "\n".join(re.findall(r"(?ms)^(?:host_tz|valid_tz|ask_locale)\(\) \{.*?^\}", src))
arrays = "\n".join(l for l in src.splitlines() if l.startswith(("LANG_CODES=", "LANG_NAMES=", "LANG_TZ=")))
pre = "set -eu\nc(){ echo \"$*\"; }\ndie(){ echo \"DIE $*\"; exit 1; }\n" + arrays + "\n" + funcs + "\n"


def sh(body, env=None):
    e = dict(os.environ, **(env or {}))
    p = subprocess.run(["bash", "-c", pre + body], capture_output=True, text=True, env=e, stdin=subprocess.DEVNULL)
    return p.returncode, p.stdout + p.stderr


rc, out = sh('NLANG=tr; NTZ=Europe/Istanbul; ask_locale; echo "$NOXIS_LANG $NOXIS_TZ"')
check("NOXIS_LANG=tr NOXIS_TZ=Europe/Istanbul accepted", rc == 0 and out.strip().endswith("tr Europe/Istanbul"), out)
rc, out = sh('NLANG=xx; NTZ=UTC; ask_locale')
check("NOXIS_LANG=xx refused", rc != 0 and "DIE" in out)
rc, out = sh('NLANG=de; NTZ="Europe/../../etc"; ask_locale')
check("invalid NOXIS_TZ refused", rc != 0 and "DIE" in out)
rc, out = sh('NLANG=""; NTZ=""; ask_locale; echo "lang=$NLANG"')
check("no terminal (container) → ask on the phone", rc == 0 and "lang=ask" in out, out)
rc, out = sh('NLANG=ask; NTZ=""; ask_locale; echo ok')
check("NOXIS_LANG=ask → wizard on the phone", rc == 0 and "ok" in out)
rc, out = sh('valid_tz America/Argentina/Buenos_Aires && echo y')
check("bash valid_tz accepts 3-part zones", "y" in out)
for loc in ("de_DE", "tr_TR", "en_US", "fr_FR", "bg_BG", "ru_RU", "uk_UA"):
    check(f"image generates {loc}.UTF-8", loc in src)
check("image applies the choice via setup.py", "setup.py apply" in src)

for d in (r, r2):
    shutil.rmtree(d, ignore_errors=True)
print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
