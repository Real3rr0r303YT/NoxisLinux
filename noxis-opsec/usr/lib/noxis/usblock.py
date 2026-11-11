#!/usr/bin/env python3
"""Noxis USB-Sperre.

Gesperrt (Phosh-Sperrbildschirm → logind LockedHint=true) oder noch kein Benutzer angemeldet:
  * USBGuard: neue USB-Geräte (OTG) werden blockiert
  * USB-Gadget: Handy trennt sich als USB-Gerät (kein MTP/RNDIS/ADB) – Laden bleibt
Entsperrt: alles wieder wie vorher.

Umgebung (für Tests): NOXIS_CONFIGFS, NOXIS_RUN, NOXIS_USBGUARD
"""
import os
import subprocess
import sys

CONFIGFS = os.environ.get("NOXIS_CONFIGFS", "/sys/kernel/config/usb_gadget")
RUN = os.environ.get("NOXIS_RUN", "/run/noxis")
USBGUARD = os.environ.get("NOXIS_USBGUARD", "usbguard")
LOGIN1 = "org.freedesktop.login1"


def log(msg):
    print(f"noxis-usblock: {msg}", flush=True)


def gadgets():
    try:
        return sorted(g for g in os.listdir(CONFIGFS) if os.path.isfile(os.path.join(CONFIGFS, g, "UDC")))
    except OSError:
        return []


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def _write(path, value):
    try:
        with open(path, "w") as f:
            f.write(value)
        return True
    except OSError as e:
        log(f"Schreiben fehlgeschlagen {path}: {e}")
        return False


def lock_gadgets():
    os.makedirs(RUN, exist_ok=True)
    for g in gadgets():
        udc_path = os.path.join(CONFIGFS, g, "UDC")
        udc = _read(udc_path)
        if not udc:
            continue
        _write(os.path.join(RUN, f"udc-{g}"), udc)
        if _write(udc_path, "\n"):
            log(f"Gadget {g} getrennt ({udc})")


def unlock_gadgets():
    for g in gadgets():
        saved = os.path.join(RUN, f"udc-{g}")
        udc = _read(saved)
        if not udc:
            continue
        if _write(os.path.join(CONFIGFS, g, "UDC"), udc):
            log(f"Gadget {g} wieder verbunden ({udc})")
            os.remove(saved)


def usbguard(target):
    try:
        subprocess.run([USBGUARD, "set-parameter", "ImplicitPolicyTarget", target],
                       check=True, capture_output=True, timeout=10)
        log(f"USBGuard: neue Geräte → {target}")
    except (OSError, subprocess.SubprocessError) as e:
        log(f"USBGuard nicht erreichbar: {e}")


_state = {"locked": None}


def apply(locked):
    if _state["locked"] is locked:
        return
    _state["locked"] = locked
    if locked:
        usbguard("block")
        lock_gadgets()
    else:
        usbguard("allow")
        unlock_gadgets()


# ------------------------------------------------------------ D-Bus (logind)
def main():
    from gi.repository import Gio, GLib

    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    sessions = {}

    def session_locked(path):
        try:
            v = bus.call_sync(LOGIN1, path, "org.freedesktop.DBus.Properties", "Get",
                              GLib.Variant("(ss)", ("org.freedesktop.login1.Session", "LockedHint")),
                              GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 2000, None)
            return bool(v.unpack()[0])
        except GLib.Error:
            return True

    def user_sessions():
        try:
            r = bus.call_sync(LOGIN1, "/org/freedesktop/login1", "org.freedesktop.login1.Manager",
                              "ListSessions", None, None, Gio.DBusCallFlags.NONE, 2000, None)
            # (session_id, uid, user, seat, path); nur echte Benutzer
            return [s[4] for s in r.unpack()[0] if s[1] >= 1000]
        except GLib.Error:
            return []

    def recompute():
        # Gesperrt, solange kein Benutzer angemeldet ist oder irgendeine Sitzung gesperrt ist
        apply(not sessions or any(sessions.values()))

    def on_props(_c, _s, path, _i, _sig, params, *_):
        iface, changed, _inv = params.unpack()
        if iface == "org.freedesktop.login1.Session" and "LockedHint" in changed:
            if path not in sessions and path not in user_sessions():
                return  # Greeter-/Systemsitzungen ignorieren
            sessions[path] = bool(changed["LockedHint"])
            recompute()

    def on_manager(_c, _s, _p, _i, sig, params, *_):
        if sig not in ("SessionNew", "SessionRemoved"):
            return
        _sid, path = params.unpack()
        users = user_sessions()
        if sig == "SessionNew" and path in users:
            sessions[path] = session_locked(path)
        for p in list(sessions):
            if p not in users:
                sessions.pop(p, None)
        recompute()

    bus.signal_subscribe(LOGIN1, "org.freedesktop.DBus.Properties", "PropertiesChanged", None,
                         "org.freedesktop.login1.Session", Gio.DBusSignalFlags.NONE, on_props)
    bus.signal_subscribe(LOGIN1, "org.freedesktop.login1.Manager", None, "/org/freedesktop/login1",
                         None, Gio.DBusSignalFlags.NONE, on_manager)
    for p in user_sessions():
        sessions[p] = session_locked(p)
    recompute()
    log("aktiv")
    GLib.MainLoop().run()


if __name__ == "__main__":
    sys.exit(main())
