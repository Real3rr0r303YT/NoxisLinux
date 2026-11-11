"""Logik des Noxis-Greeters ohne GTK (testbar)."""
import configparser
import glob
import os
import pwd
import secrets

CONF = os.environ.get("NOXIS_GREETER_CONF", "/etc/noxis/greeter.conf")
DRM = os.environ.get("NOXIS_DRM", "/sys/class/drm")
INTERNAL_PREFIXES = ("DSI", "eDP", "LVDS")

SESSIONS = {
    "mobile":  {"label": "Mobil",   "cmd": ["phosh-session"], "env": ["NOXIS_MODE=mobile"]},
    "desktop": {"label": "Desktop", "cmd": ["phosh-session"], "env": ["NOXIS_MODE=desktop"]},
}


def load_conf(path=None):
    cp = configparser.ConfigParser()
    cp.read(path or CONF)
    s = cp["greeter"] if cp.has_section("greeter") else {}
    return {
        "user": s.get("user", "").strip(),
        "shuffle": str(s.get("shuffle", "true")).lower() not in ("0", "false", "no", "nein"),
        "pin_length": int(s.get("pin_length", "0") or 0),
        "show_user": str(s.get("show_user", "false")).lower() in ("1", "true", "yes", "ja"),
    }


def pick_user(conf, passwd=None):
    """Konfigurierter Nutzer, sonst erster normaler Nutzer (uid ≥ 1000, gültige Shell)."""
    entries = passwd if passwd is not None else pwd.getpwall()
    names = {e.pw_name for e in entries}
    if conf.get("user") and conf["user"] in names:
        return conf["user"]
    for e in sorted(entries, key=lambda e: e.pw_uid):
        if 1000 <= e.pw_uid < 60000 and not e.pw_shell.endswith(("nologin", "false")):
            return e.pw_name
    return None


def keypad(shuffle=True, rng=None):
    """10 Ziffern für ein 3×4-Feld; Platz 9 = Löschen, Platz 11 = OK, Ziffer 10 unten Mitte."""
    digits = list("1234567890")
    if shuffle:
        r = rng or secrets.SystemRandom()
        r.shuffle(digits)
    return digits[:9] + ["⌫", digits[9], "✓"]


def backoff(failures):
    """Wartezeit in Sekunden nach Fehlversuchen: 0,0,0,0,30,60,120,… max. 15 min."""
    if failures < 4:
        return 0
    return min(30 * 2 ** (failures - 4), 900)


def connected_outputs(drm=None):
    """Angeschlossene Ausgänge aus /sys/class/drm: [(name, intern?)]."""
    out = []
    for st in sorted(glob.glob(os.path.join(drm or DRM, "card*-*", "status"))):
        try:
            with open(st) as f:
                if f.read().strip() != "connected":
                    continue
        except OSError:
            continue
        name = os.path.basename(os.path.dirname(st)).split("-", 1)[1]
        out.append((name, name.startswith(INTERNAL_PREFIXES)))
    return out


def has_external(drm=None):
    return any(not internal for _, internal in connected_outputs(drm))


def default_mode(drm=None):
    return "desktop" if has_external(drm) else "mobile"


class PinState:
    def __init__(self, max_len=12):
        self.max_len = max_len
        self.digits = []

    def add(self, d):
        if d.isdigit() and len(self.digits) < self.max_len:
            self.digits.append(d)

    def back(self):
        if self.digits:
            self.digits.pop()

    def take(self):
        """PIN herausgeben und sofort vergessen."""
        pin = "".join(self.digits)
        self.digits.clear()
        return pin

    def __len__(self):
        return len(self.digits)
