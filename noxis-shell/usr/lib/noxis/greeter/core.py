"""Noxis greeter logic without GTK (testable)."""
import configparser
import glob
import os
import pwd
import secrets

CONF = os.environ.get("NOXIS_GREETER_CONF", "/etc/noxis/greeter.conf")
DRM = os.environ.get("NOXIS_DRM", "/sys/class/drm")
INTERNAL_PREFIXES = ("DSI", "eDP", "LVDS")

SYS = os.environ.get("NOXIS_SYS", "/sys")

SESSIONS = {
    "mobile":  {"cmd": ["phosh-session"], "env": ["NOXIS_MODE=mobile"]},
    "desktop": {"cmd": ["phosh-session"], "env": ["NOXIS_MODE=desktop"]},
}


def load_conf(path=None):
    cp = configparser.ConfigParser()
    cp.read(path or CONF)
    s = cp["greeter"] if cp.has_section("greeter") else {}
    return {
        "user": s.get("user", "").strip(),
        "shuffle": str(s.get("shuffle", "true")).lower() not in ("0", "false", "no", "nein", "hayır"),
        "pin_length": int(s.get("pin_length", "0") or 0),
        "show_user": str(s.get("show_user", "false")).lower() in ("1", "true", "yes", "ja"),
    }


def pick_user(conf, passwd=None):
    """Configured user, else the first regular user (uid ≥ 1000, real shell)."""
    entries = passwd if passwd is not None else pwd.getpwall()
    names = {e.pw_name for e in entries}
    if conf.get("user") and conf["user"] in names:
        return conf["user"]
    for e in sorted(entries, key=lambda e: e.pw_uid):
        if 1000 <= e.pw_uid < 60000 and not e.pw_shell.endswith(("nologin", "false")):
            return e.pw_name
    return None


def keypad(shuffle=True, rng=None):
    """10 digits for a 3×4 pad; slot 9 = delete, slot 11 = OK, 10th digit bottom centre."""
    digits = list("1234567890")
    if shuffle:
        r = rng or secrets.SystemRandom()
        r.shuffle(digits)
    return digits[:9] + ["⌫", digits[9], "✓"]


def backoff(failures):
    """Lockout in seconds after failed attempts: 0,0,0,30,60,120,… max 15 min."""
    if failures < 4:
        return 0
    return min(30 * 2 ** (failures - 4), 900)


def connected_outputs(drm=None):
    """Connected outputs from /sys/class/drm: [(name, internal?)]."""
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
        """Return the PIN and forget it immediately."""
        pin = "".join(self.digits)
        self.digits.clear()
        return pin

    def __len__(self):
        return len(self.digits)


def _read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def status(sys_root=None):
    """VPN, network and battery for the status row (sysfs only, no D-Bus, no network access)."""
    root = sys_root or SYS
    net = os.path.join(root, "class/net")
    ifaces = os.listdir(net) if os.path.isdir(net) else []
    vpn = any(i in ("wg0-mullvad", "wg-mullvad") for i in ifaces)
    up = {i for i in ifaces if _read(os.path.join(net, i, "operstate")) in ("up", "unknown")
          and not i.startswith(("lo", "wg", "tun", "waydroid", "dummy"))}
    if any(i.startswith(("wlan", "wlp", "wl")) for i in up):
        net_icon = "network-wireless-signal-good-symbolic"
    elif any(i.startswith(("rmnet", "wwan", "ccmni")) for i in up):
        net_icon = "network-cellular-signal-good-symbolic"
    elif any(i.startswith(("eth", "en", "usb")) for i in up):
        net_icon = "network-wired-symbolic"
    else:
        net_icon = "network-offline-symbolic"
    battery, bat_icon = None, "battery-missing-symbolic"
    ps = os.path.join(root, "class/power_supply")
    for d in sorted(os.listdir(ps)) if os.path.isdir(ps) else []:
        if _read(os.path.join(ps, d, "type")) == "Battery":
            cap = _read(os.path.join(ps, d, "capacity"))
            if cap and cap.isdigit():
                battery = max(0, min(100, int(cap)))
                level = min(100, (battery + 5) // 10 * 10)
                charging = _read(os.path.join(ps, d, "status")) in ("Charging", "Full")
                bat_icon = f"battery-level-{level}{'-charging' if charging else ''}-symbolic"
                break
    return {"vpn": vpn, "net_icon": net_icon, "battery": battery, "bat_icon": bat_icon}
