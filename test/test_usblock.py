#!/usr/bin/env python3
"""Integrationstest für usblock.py: privater D-Bus + nachgebautes logind + Fake-Gadget/USBGuard.
Start:  dbus-run-session -- python3 test/test_usblock.py   (braucht python3-gi)"""
import os
import subprocess
import sys
import tempfile
import threading
import time

from gi.repository import Gio, GLib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
USBLOCK = os.path.join(ROOT, "noxis-opsec/usr/lib/noxis/usblock.py")

XML = """<node>
 <interface name="org.freedesktop.login1.Manager">
  <method name="ListSessions"><arg type="a(susso)" direction="out"/></method>
  <signal name="SessionNew"><arg type="s"/><arg type="o"/></signal>
  <signal name="SessionRemoved"><arg type="s"/><arg type="o"/></signal>
 </interface>
</node>"""
PROPS_XML = """<node><interface name="org.freedesktop.DBus.Properties">
 <method name="Get"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/></method>
 <signal name="PropertiesChanged"><arg type="s"/><arg type="a{sv}"/><arg type="as"/></signal>
</interface></node>"""

USER = "/org/freedesktop/login1/session/_31"
GREETER = "/org/freedesktop/login1/session/c1"
sessions = {USER: {"uid": 1000, "user": "noxis", "locked": True},
            GREETER: {"uid": 120, "user": "greeter", "locked": False}}

tmp = tempfile.mkdtemp()
cfs = os.path.join(tmp, "usb_gadget/g1")
os.makedirs(cfs)
UDC = os.path.join(cfs, "UDC")
open(UDC, "w").write("a600000.dwc3\n")
ug_log = os.path.join(tmp, "usbguard.log")
ug = os.path.join(tmp, "usbguard")
open(ug, "w").write(f'#!/bin/sh\necho "$*" >> {ug_log}\n')
os.chmod(ug, 0o755)

bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
mgr_info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
props_info = Gio.DBusNodeInfo.new_for_xml(PROPS_XML).interfaces[0]


def mgr_call(conn, sender, path, iface, method, params, inv):
    out = [(p.rsplit("/", 1)[1], s["uid"], s["user"], "seat0", p) for p, s in sessions.items()]
    inv.return_value(GLib.Variant("(a(susso))", (out,)))


def props_call(conn, sender, path, iface, method, params, inv):
    _i, name = params.unpack()
    inv.return_value(GLib.Variant("(v)", (GLib.Variant("b", sessions[path]["locked"]),)))


bus.register_object("/org/freedesktop/login1", mgr_info, mgr_call, None, None)
for p in sessions:
    bus.register_object(p, props_info, props_call, None, None)
Gio.bus_own_name_on_connection(bus, "org.freedesktop.login1", Gio.BusNameOwnerFlags.NONE, None, None)

loop = GLib.MainLoop()
threading.Thread(target=loop.run, daemon=True).start()
time.sleep(0.3)


def set_lock(path, locked):
    sessions[path]["locked"] = locked
    GLib.idle_add(lambda: bus.emit_signal(None, path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                  GLib.Variant("(sa{sv}as)", ("org.freedesktop.login1.Session", {"LockedHint": GLib.Variant("b", locked)}, []))) and False)
    time.sleep(0.6)


env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=os.environ["DBUS_SESSION_BUS_ADDRESS"],
           NOXIS_CONFIGFS=os.path.join(tmp, "usb_gadget"), NOXIS_RUN=os.path.join(tmp, "run"), NOXIS_USBGUARD=ug)
proc = subprocess.Popen([sys.executable, USBLOCK], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(1.2)

fails = 0


def check(name, ok):
    global fails
    print(("PASS " if ok else "FAIL ") + name)
    fails += not ok


def udc():
    return open(UDC).read().strip()


def last_ug():
    return open(ug_log).read().strip().splitlines()[-1] if os.path.exists(ug_log) else ""


check("Start gesperrt: USBGuard blockiert neue Geräte", last_ug() == "set-parameter ImplicitPolicyTarget block")
check("Start gesperrt: Gadget getrennt (Laden bleibt)", udc() == "")
set_lock(USER, False)
check("Entsperrt: USBGuard erlaubt", last_ug() == "set-parameter ImplicitPolicyTarget allow")
check("Entsperrt: Gadget wieder verbunden", udc() == "a600000.dwc3")
set_lock(USER, True)
check("Wieder gesperrt: blockiert + getrennt", last_ug().endswith("block") and udc() == "")
n = len(open(ug_log).read().splitlines())
set_lock(GREETER, False)
check("Greeter-Sitzung 'entsperrt' wird ignoriert", udc() == "" and len(open(ug_log).read().splitlines()) == n)
set_lock(USER, False)
GLib.idle_add(lambda: bus.emit_signal(None, "/org/freedesktop/login1", "org.freedesktop.login1.Manager", "SessionRemoved",
              GLib.Variant("(so)", ("31", USER))) and False)
del sessions[USER]
time.sleep(0.8)
check("Abmelden → wieder gesperrt", last_ug().endswith("block") and udc() == "")

proc.terminate()
out = proc.communicate(timeout=3)[0]
check("Keine Python-Fehler im Dienst", "Traceback" not in out)
if fails:
    print(out)
print(f"\n{8 - fails}/8 bestanden")
sys.exit(1 if fails else 0)
