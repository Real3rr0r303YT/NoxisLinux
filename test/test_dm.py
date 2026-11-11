#!/usr/bin/env python3
"""Tests für noxis-dm mit echtem Linux-PAM (eigenes confdir, pam_exec prüft die PIN).
Muss als root laufen (Rechteabgabe, Sitzungsstart). Nutzt die Konten 'nobody' (Greeter) und
einen normalen Benutzer mit Shell (Standard: erster uid ≥ 1000) – ohne /etc zu ändern."""
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
    print("als root starten")
    sys.exit(2)

USER = os.environ.get("NOXIS_TEST_USER") or next(
    p.pw_name for p in sorted(pwd.getpwall(), key=lambda p: p.pw_uid)
    if 1000 <= p.pw_uid < 60000 and p.pw_shell.endswith(("bash", "/sh", "zsh")))
UPW = pwd.getpwnam(USER)

# Testumgebung: für nobody/USER lesbar
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
    f.write(f"#!/bin/sh\n{{ echo uid=$(id -u); echo mode=$NOXIS_MODE; echo pre=${{LD_PRELOAD:-leer}};"
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
    """Authenticator auf einer Seite eines socketpair, fn(client) auf der anderen."""
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


print("== PAM + greetd-Protokoll")
a, (ok, e) = client_server(lambda g: g.login(USER, "147147", ["phosh-session"], ["NOXIS_MODE=mobile", "LD_PRELOAD=x"]))
check("richtige PIN über echtes PAM → angemeldet", ok and a.authed, e)
check("Sitzung vorgemerkt", a.session == (["phosh-session"], {"NOXIS_MODE": "mobile"}), a.session)
check("LD_PRELOAD aus Greeter-Umgebung verworfen", "LD_PRELOAD" not in a.session[1])
a.reset()
a, (ok, e) = client_server(lambda g: g.login(USER, "123456", ["phosh-session"], []))
check("falsche PIN → abgelehnt", not ok and e == "Falsche PIN" and not a.authed and a.pam is None, e)
a, (ok, e) = client_server(lambda g: g.login(USER, "147147", ["bash"], []))
check("nicht erlaubte Sitzung (bash) → abgelehnt", not ok and a.session is None, e)
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
check("start_session ohne Anmeldung → Fehler", r1["type"] == "error")
check("create_session → PIN-Abfrage (secret)", r2.get("auth_message_type") == "secret", r2)
check("cancel während Abfrage → success, Zustand leer", r3["type"] == "success" and a.pam is None, r3)
check("Antwort ohne Abfrage → Fehler", r4["type"] == "error")
check("Benutzername mit '/' → Fehler", r5["type"] == "error")
check("unbekannte Anfrage → Fehler", r6["type"] == "error")
check("unbekannter Benutzer = gleiche Meldung wie falsche PIN", dm.pam.PAM_USER_UNKNOWN in dm.AUTH_FAIL)

print("== Ablauf Greeter → Sitzung (fork, Rechteabgabe)")
d = dm.DM(conf)
t0 = time.time()
ready = d.run_greeter()
check("Greeter beendet, Sitzung bereit", ready, open(os.path.join(out, "greeter-ok")).read() if os.path.exists(os.path.join(out, "greeter-ok")) else "")
g = open(os.path.join(out, "greeter")).read()
check("Greeter lief als nobody", "uid=65534" in g, g)
check("Greeter bekam GREETD_SOCK und Klasse greeter", "sock=" + os.path.join(conf["run_dir"], "greeter.sock") in g and "class=greeter" in g, g)
check("Greeter: falsche PIN abgelehnt", open(os.path.join(out, "greeter-fail")).read().startswith("False"))
check("Socket nach Greeter-Ende entfernt", not os.path.exists(os.path.join(conf["run_dir"], "greeter.sock")))
d.run_session()
s = open(os.path.join(out, "session")).read() if os.path.exists(os.path.join(out, "session")) else ""
check(f"Sitzung lief als {USER} (uid {UPW.pw_uid})", f"uid={UPW.pw_uid}" in s, s)
check("NOXIS_MODE=desktop durchgereicht", "mode=desktop" in s, s)
check("LD_PRELOAD nicht in der Sitzung", "pre=leer" in s, s)
check("Klasse user, HOME gesetzt", "class=user" in s and f"home={UPW.pw_dir}" in s, s)
check("umask 077", "umask=0077" in s, s)
check("Zustand nach Abmelden zurückgesetzt", d.auth.pam is None and d.auth.session is None and not d.auth.authed)
check(f"Durchlauf < 15 s ({time.time() - t0:.1f} s)", time.time() - t0 < 15)

print("== Konfiguration")
c = dm.load_conf(os.path.join(ROOT, "noxis-shell/etc/noxis/dm.conf"))
check("dm.conf: vt 1, Greeter-Nutzer, Sitzungen", c["vt"] == 1 and c["greeter_user"] == "noxis-greeter" and c["sessions"] == ["phosh-session"], c)
check("dm.conf: Greeter in cage", "cage" in c["greeter_cmd"] and "noxis-greeter" in c["greeter_cmd"])

shutil.rmtree(T, ignore_errors=True)
print(f"\n{passed} bestanden, {failed} fehlgeschlagen")
sys.exit(1 if failed else 0)
