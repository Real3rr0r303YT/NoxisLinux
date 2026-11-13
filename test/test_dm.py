#!/usr/bin/env python3
"""Tests for noxis-dm with real Linux-PAM (own confdir, pam_exec checks the PIN).
Must run as root (privilege drop, session start). Uses the accounts 'nobody' (greeter) and a
regular user with a shell (default: first uid ≥ 1000) – without touching /etc."""
import importlib.machinery
import importlib.util
import os
import pwd
import shutil
import socket
import stat
import sys
import tempfile
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DMDIR = os.path.join(ROOT, "noxis-shell/usr/lib/noxis/dm")
GREETER = os.path.join(ROOT, "noxis-shell/usr/lib/noxis/greeter")
sys.path.insert(0, DMDIR)
sys.path.insert(0, GREETER)
loader = importlib.machinery.SourceFileLoader("noxis_dm", os.path.join(DMDIR, "noxis-dm"))
spec = importlib.util.spec_from_loader("noxis_dm", loader)
dm = importlib.util.module_from_spec(spec)
loader.exec_module(dm)
from greetd_ipc import Greetd  # noqa: E402

passed = failed = 0


def check(name, cond, info=""):
    global passed, failed
    passed += bool(cond)
    failed += not cond
    print(f"  {'✓' if cond else '✗'} {name}{'' if cond else ' ' + str(info)}")


if os.geteuid() != 0:
    print("run as root")
    sys.exit(2)

USER = os.environ.get("NOXIS_TEST_USER") or next(
    p.pw_name for p in sorted(pwd.getpwall(), key=lambda p: p.pw_uid)
    if 1000 <= p.pw_uid < 60000 and p.pw_shell.endswith(("bash", "/sh", "zsh")))
UPW = pwd.getpwnam(USER)

# test environment: readable for nobody/USER
T = tempfile.mkdtemp(prefix="noxis-dm-")
os.chmod(T, 0o755)
pamdir = os.path.join(T, "pam.d")
os.makedirs(pamdir)
check_pin = os.path.join(T, "check-pin")
with open(check_pin, "w") as f:
    f.write("#!/bin/sh\npin=$(tr -d '\\000')\n[ \"$pin\" = 147147 ]\n")
os.chmod(check_pin, 0o755)
with open(os.path.join(pamdir, "noxis"), "w") as f:
    f.write(f"auth required pam_exec.so expose_authtok quiet {check_pin}\nauth optional pam_permit.so\n"
            "account required pam_permit.so\nsession required pam_permit.so\npassword required pam_deny.so\n")
with open(os.path.join(pamdir, "noxis-greeter"), "w") as f:
    f.write("auth required pam_permit.so\naccount required pam_permit.so\nsession required pam_permit.so\n")
out = os.path.join(T, "out")
os.makedirs(out)
os.chmod(out, 0o777)
fake_session = os.path.join(T, "phosh-session")
with open(fake_session, "w") as f:
    f.write(f"#!/bin/sh\n{{ echo uid=$(id -u); echo mode=$NOXIS_MODE; echo pre=${{LD_PRELOAD:-empty}};"
            f" echo class=$XDG_SESSION_CLASS; echo home=$HOME; echo umask=$(umask); }} > {out}/session\n")
os.chmod(fake_session, 0o755)
for fn in ("greetd_ipc.py",):
    shutil.copy(os.path.join(GREETER, fn), T)
fake_greeter = os.path.join(T, "fake_greeter.py")
with open(fake_greeter, "w") as f:
    f.write(f"""import os, sys
sys.path.insert(0, {T!r})
from greetd_ipc import Greetd
open({out!r} + "/greeter", "w").write(f"uid={{os.getuid()}} sock={{os.environ.get('GREETD_SOCK')}} class={{os.environ.get('XDG_SESSION_CLASS')}}")
g = Greetd(); ok, e = g.login({USER!r}, "000000", ["phosh-session"], []); g.close()
open({out!r} + "/greeter-fail", "w").write(f"{{ok}} {{e}}")
g = Greetd(); ok, e = g.login({USER!r}, "147147", [{fake_session!r}], ["NOXIS_MODE=desktop", "LD_PRELOAD=/tmp/evil.so"]); g.close()
open({out!r} + "/greeter-ok", "w").write(f"{{ok}} {{e}}")
""")
os.chmod(fake_greeter, 0o644)

conf = dm.load_conf(os.path.join(T, "fehlt.conf"))
conf.update(vt=0, greeter_user="nobody", greeter_cmd=f"{sys.executable} -I {fake_greeter}",
            pam_confdir=pamdir, run_dir=os.path.join(T, "run"), sessions=["phosh-session"])


def client_server(fn):
    """Authenticator on one end of a socketpair, fn(client) on the other."""
    a = dm.Authenticator(conf)
    s1, s2 = socket.socketpair()
    th = threading.Thread(target=lambda: (a.handle(s1), s1.close()), daemon=True)
    th.start()
    path = os.path.join(T, f"cs{time.time_ns()}.sock")
    g = Greetd.__new__(Greetd)
    g.path, g.sock = path, s2
    res = fn(g)
    g.close()
    th.join(timeout=5)
    return a, res


print("== PAM + greetd protocol")
a, (ok, e) = client_server(lambda g: g.login(USER, "147147", ["phosh-session"], ["NOXIS_MODE=mobile", "LD_PRELOAD=x"]))
check("correct PIN via real PAM → authenticated", ok and a.authed, e)
check("session queued", a.session == (["phosh-session"], {"NOXIS_MODE": "mobile"}), a.session)
check("LD_PRELOAD from the greeter env dropped", "LD_PRELOAD" not in a.session[1])
a.reset()
a, (ok, e) = client_server(lambda g: g.login(USER, "123456", ["phosh-session"], []))
check("wrong PIN → refused", not ok and e == "wrong_pin" and not a.authed and a.pam is None, e)
a, (ok, e) = client_server(lambda g: g.login(USER, "147147", ["bash"], []))
check("disallowed session (bash) → refused", not ok and a.session is None, e)
a.reset()


def raw(g):
    r1 = g.request({"type": "start_session", "cmd": ["phosh-session"], "env": []})
    r2 = g.request({"type": "create_session", "username": USER})
    r3 = g.request({"type": "cancel_session"})
    r4 = g.request({"type": "post_auth_message_response", "response": "1"})
    r5 = g.request({"type": "create_session", "username": "../root"})
    r6 = g.request({"type": "bogus"})
    return r1, r2, r3, r4, r5, r6


a, (r1, r2, r3, r4, r5, r6) = client_server(raw)
check("start_session without auth → error", r1["type"] == "error")
check("create_session → PIN prompt (secret)", r2.get("auth_message_type") == "secret", r2)
check("cancel during prompt → success, state cleared", r3["type"] == "success" and a.pam is None, r3)
check("answer without prompt → error", r4["type"] == "error")
check("user name with '/' → error", r5["type"] == "error")
check("unknown request → error", r6["type"] == "error")
check("unknown user = same message as wrong PIN", dm.pam.PAM_USER_UNKNOWN in dm.AUTH_FAIL)

print("== Flow greeter → session (fork, privilege drop)")
d = dm.DM(conf)
t0 = time.time()
ready = d.run_greeter()
check("greeter exited, session ready", ready, open(os.path.join(out, "greeter-ok")).read() if os.path.exists(os.path.join(out, "greeter-ok")) else "")
g = open(os.path.join(out, "greeter")).read()
check("greeter ran as nobody", "uid=65534" in g, g)
check("greeter got GREETD_SOCK and class greeter", "sock=" + os.path.join(conf["run_dir"], "greeter.sock") in g and "class=greeter" in g, g)
check("greeter: wrong PIN refused", open(os.path.join(out, "greeter-fail")).read().startswith("False"))
check("socket removed after the greeter exits", not os.path.exists(os.path.join(conf["run_dir"], "greeter.sock")))
d.run_session()
s = open(os.path.join(out, "session")).read() if os.path.exists(os.path.join(out, "session")) else ""
check(f"session ran as {USER} (uid {UPW.pw_uid})", f"uid={UPW.pw_uid}" in s, s)
check("NOXIS_MODE=desktop passed through", "mode=desktop" in s, s)
check("LD_PRELOAD not in the session", "pre=empty" in s, s)
check("class user, HOME set", "class=user" in s and f"home={UPW.pw_dir}" in s, s)
check("umask 077", "umask=0077" in s, s)
check("state reset after logout", d.auth.pam is None and d.auth.session is None and not d.auth.authed)
check(f"run < 15 s ({time.time() - t0:.1f} s)", time.time() - t0 < 15)

print("== Config")
c = dm.load_conf(os.path.join(ROOT, "noxis-shell/etc/noxis/dm.conf"))
check("dm.conf: vt 1, greeter user, sessions", c["vt"] == 1 and c["greeter_user"] == "noxis-greeter" and c["sessions"] == ["phosh-session"], c)
check("dm.conf: greeter in cage", "cage" in c["greeter_cmd"] and "noxis-greeter" in c["greeter_cmd"])
check("dm.conf: renderer pixman", c["renderer"] == "pixman", c)

print("== Renderer + XDG_RUNTIME_DIR")
GPW = pwd.getpwnam("nobody")
e = dm.base_env(GPW, c, "greeter")
check("pixman renderer in the environment",
      e.get("WLR_RENDERER") == "pixman" and e.get("WLR_RENDERER_ALLOW_SOFTWARE") == "1"
      and e.get("GSK_RENDERER") == "cairo", e)
chw = dict(c); chw["renderer"] = "gles2"
e2 = dm.base_env(GPW, chw, "greeter")
check("gles2 without the software switches",
      e2.get("WLR_RENDERER") == "gles2" and "WLR_RENDERER_ALLOW_SOFTWARE" not in e2, e2)
chn = dict(c); chn["renderer"] = ""
e3 = dm.base_env(GPW, chn, "greeter")
check("renderer empty leaves WLR_RENDERER unset", "WLR_RENDERER" not in e3, e3)

print("== Ersteinrichtung: PIN + Benutzer")
sys.path.insert(0, DMDIR)
import setup as nxsetup  # noqa: E402
import i18n as nxi18n  # noqa: E402

check("PIN 1234 ist brauchbar", nxsetup.check_pin("1234") is None)
check("PIN 12 zu kurz", nxsetup.check_pin("12") == "length")
check("PIN mit Buchstaben abgelehnt", nxsetup.check_pin("12ab") == "digits")
check("PIN None abgelehnt", nxsetup.check_pin(None) == "digits")
check("PIN 33 Ziffern zu lang", nxsetup.check_pin("1" * 33) == "length")

rows = [("root", 0, "/bin/bash"), ("noxis-greeter", 103, "/usr/sbin/nologin"),
        ("nobody", 65534, "/usr/sbin/nologin"), ("zweiter", 1001, "/bin/bash"),
        ("noxis", 1000, "/bin/bash")]
check("default_user nimmt den ersten regulaeren", nxsetup.default_user(rows) == "noxis")
check("default_user ignoriert nologin und nobody",
      nxsetup.default_user([("noxis-greeter", 103, "/usr/sbin/nologin"),
                            ("nobody", 65534, "/usr/sbin/nologin")]) is None)

TR = os.path.join(T, "fakeroot")
os.makedirs(TR, exist_ok=True)
nxsetup.set_user("noxis", "4711", "Test Name", root=TR)   # darf nichts anfassen
check("set_user prueft, aendert aber nichts bei root != /", not os.path.exists(os.path.join(TR, "etc/shadow")))
for bad, why in ((("", "1234", None), "leerer Benutzer"), (("../root", "1234", None), "Pfad im Namen"),
                 (("noxis", "12", None), "zu kurze PIN"), (("noxis", "1234", "a:b"), "Doppelpunkt im Namen"),
                 (("noxis", "1234", "x" * 65), "zu langer Name")):
    try:
        nxsetup.set_user(bad[0], bad[1], bad[2], root=TR)
        check(f"set_user lehnt ab: {why}", False)
    except ValueError:
        check(f"set_user lehnt ab: {why}", True)

# Sprache/Zeitzone und PIN sind getrennt: ein Image kann mit fester Sprache
# gebaut werden, die PIN muss trotzdem jedes Mal gesetzt werden.
TD = os.path.join(T, "doneroot")
os.makedirs(os.path.join(TD, "var/lib/noxis"), exist_ok=True)
# apply() prueft die Zeitzone gegen die zoneinfo unterhalb von root, also
# braucht der Testbaum eine zone.tab und die Zonendatei selbst.
os.makedirs(os.path.join(TD, nxsetup.ZONEINFO, "Europe"), exist_ok=True)
with open(os.path.join(TD, nxsetup.ZONEINFO, "zone.tab"), "w") as f:
    f.write("# Testbaum\nDE\t+5230+01322\tEurope/Berlin\n")
open(os.path.join(TD, nxsetup.ZONEINFO, "Europe/Berlin"), "wb").close()
nxsetup.apply("de", "Europe/Berlin", root=TD, compile_schemas=False)
check("apply setzt die Sprach-Markierung", nxsetup.is_done(TD))
check("apply setzt NICHT die PIN-Markierung", not nxsetup.user_is_done(TD))
nxsetup.set_user("noxis", "4711", None, root=TD)
check("set_user setzt die PIN-Markierung", nxsetup.user_is_done(TD))

missing = [k for k in ("set_pin", "pin_repeat", "pin_mismatch", "pin_short", "later")
           if k not in nxi18n.T or len(nxi18n.T[k]) != len(nxi18n.ORDER)]
check("PIN-Texte in allen sieben Sprachen", not missing, missing)

# ---- Benutzername in der Ersteinrichtung
check("slug: Max Müller → max", nxsetup.slug("Max Müller") == "max")
check("slug: nichts Brauchbares → leer", nxsetup.slug("123 !!") == "" and nxsetup.slug("root") == "")
check("Benutzername gueltig", nxsetup.check_username("hakan", "noxis", names={"noxis"}) is None)
check("Benutzername: gleich bleibt erlaubt", nxsetup.check_username("noxis", "noxis", names={"noxis"}) is None)
check("Benutzername abgelehnt: Grossbuchstaben, root, vergeben",
      nxsetup.check_username("Max", "noxis", names=set()) == "invalid"
      and nxsetup.check_username("root", "noxis", names=set()) == "reserved"
      and nxsetup.check_username("anna", "noxis", names={"anna"}) == "taken")
os.makedirs(os.path.join(TD, "etc/noxis"), exist_ok=True)
open(os.path.join(TD, "etc/noxis/greeter.conf"), "w").write("[greeter]\nuser = noxis\nshuffle = true\n")
nxsetup.rename_user("noxis", "hakan", root=TD)
check("rename_user traegt den Namen in greeter.conf ein",
      "user = hakan" in open(os.path.join(TD, "etc/noxis/greeter.conf")).read())
try:
    nxsetup.rename_user("noxis", "Bad Name", root=TD); check("rename_user lehnt ungueltige Namen ab", False)
except ValueError:
    check("rename_user lehnt ungueltige Namen ab", True)
missing = [k for k in ("who_title", "your_name", "username", "user_bad")
           if k not in nxi18n.T or len(nxi18n.T[k]) != len(nxi18n.ORDER)]
check("Namens-Texte in allen sieben Sprachen", not missing, missing)

# ---- WLAN-Schritt der Ersteinrichtung
import wifi as nxwifi  # noqa: E402
scan = nxwifi.parse_scan("*:Heim\\:Netz:80:WPA2\n:Cafe:40:--\n:Heim\\:Netz:30:WPA2\n::70:WPA2\n:Nachbar:90:WPA3\n")
check("Scan: aktives Netz zuerst, Doppelte zusammengefasst",
      [n["ssid"] for n in scan] == ["Heim:Netz", "Nachbar", "Cafe"], scan)
check("Scan: offenes Netz erkannt", not scan[2]["secure"] and scan[1]["secure"])
check("WLAN: Passwort zu kurz abgelehnt", nxwifi.check("x", "1234567") is not None)
check("WLAN: offenes Netz ohne Passwort ok", nxwifi.check("x", "") is None)
check("WLAN: SSID mit Zeilenumbruch abgelehnt", nxwifi.check("a\nb", "12345678") is not None)
kf = nxwifi.keyfile("Ab", "pa\\ss word", "u-1")
check("Keyfile: SSID als Bytes, Backslash maskiert",
      "ssid=65;98;" in kf and "psk=pa\\\\ss word" in kf and "key-mgmt=wpa-psk" in kf, kf)
check("Keyfile: offenes Netz ohne wifi-security", "[wifi-security]" not in nxwifi.keyfile("Cafe", "", "u"))
uid = nxwifi.connect("Heim", "geheim123", root=TD)
kp = os.path.join(TD, nxwifi.NM_DIR, f"noxis-{uid}.nmconnection")
check("connect schreibt Keyfile mit 0600", os.path.exists(kp) and stat.S_IMODE(os.stat(kp).st_mode) == 0o600)
missing = [k for k in ("wifi_title", "wifi_pw", "wifi_ok", "wifi_fail", "skip", "connect")
           if k not in nxi18n.T or len(nxi18n.T[k]) != len(nxi18n.ORDER)]
check("WLAN-Texte in allen sieben Sprachen", not missing, missing)

# ---- Greeter verweist nur auf vorhandene Funktionen (core.Pin-Absturz)
import re as _re  # noqa: E402
import core as nxcore  # noqa: E402
_src = open(os.path.join(GREETER, "noxis-greeter")).read()
_bad = sorted({a for a in _re.findall(r"core\.(\w+)", _src) if not hasattr(nxcore, a)})
check("Greeter nutzt nur vorhandene core-Funktionen", not _bad, _bad)
_keys = set(_re.findall(r"i18n\.tr\([\w.]+,\s*[\"'](\w+)[\"']", _src))
_bad = sorted(k for k in _keys if k not in nxi18n.T)
check("Greeter nutzt nur vorhandene Texte", not _bad, _bad)

shutil.rmtree(T, ignore_errors=True)
print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
