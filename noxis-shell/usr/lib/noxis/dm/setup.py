"""First-boot setup: language + time zone. Runs as root inside noxis-dm."""
import os
import re
import subprocess
import sys

sys.path.insert(0, "/usr/lib/noxis/greeter")
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "greeter"))
from i18n import LANGS  # noqa: E402

ZONEINFO = "usr/share/zoneinfo"
DONE = "var/lib/noxis/setup-done"
TZ_RE = re.compile(r"^(UTC|[A-Z][A-Za-z_+-]*(/[A-Za-z0-9_+-]+){1,2})$")

# Mobile country code → ISO country (ITU-T E.212)
MCC = {
    "202": "GR", "204": "NL", "206": "BE", "208": "FR", "212": "MC", "213": "AD", "214": "ES", "216": "HU",
    "218": "BA", "219": "HR", "220": "RS", "221": "XK", "222": "IT", "226": "RO", "228": "CH", "230": "CZ",
    "231": "SK", "232": "AT", "234": "GB", "235": "GB", "238": "DK", "240": "SE", "242": "NO", "244": "FI",
    "246": "LT", "247": "LV", "248": "EE", "250": "RU", "255": "UA", "257": "BY", "259": "MD", "260": "PL",
    "262": "DE", "266": "GI", "268": "PT", "270": "LU", "272": "IE", "274": "IS", "276": "AL", "278": "MT",
    "280": "CY", "282": "GE", "283": "AM", "284": "BG", "286": "TR", "288": "FO", "293": "SI", "294": "MK",
    "295": "LI", "297": "ME", "302": "CA", "310": "US", "311": "US", "312": "US", "313": "US", "314": "US",
    "315": "US", "316": "US", "334": "MX", "400": "AZ", "401": "KZ", "404": "IN", "405": "IN", "410": "PK",
    "412": "AF", "415": "LB", "416": "JO", "417": "SY", "418": "IQ", "420": "SA", "424": "AE", "425": "IL",
    "432": "IR", "434": "UZ", "436": "TJ", "437": "KG", "438": "TM", "440": "JP", "441": "JP", "450": "KR",
    "454": "HK", "460": "CN", "466": "TW", "502": "MY", "505": "AU", "510": "ID", "515": "PH", "520": "TH",
    "525": "SG", "530": "NZ", "602": "EG", "603": "DZ", "604": "MA", "605": "TN", "655": "ZA", "722": "AR",
    "724": "BR", "730": "CL", "732": "CO",
}

# main zone for countries with several zones in zone.tab
PRIMARY = {
    "UA": "Europe/Kyiv", "RU": "Europe/Moscow", "DE": "Europe/Berlin", "ES": "Europe/Madrid", "PT": "Europe/Lisbon",
    "CY": "Asia/Nicosia", "US": "America/New_York", "CA": "America/Toronto", "MX": "America/Mexico_City",
    "BR": "America/Sao_Paulo", "AR": "America/Argentina/Buenos_Aires", "CL": "America/Santiago",
    "AU": "Australia/Sydney", "NZ": "Pacific/Auckland", "KZ": "Asia/Almaty", "UZ": "Asia/Tashkent",
    "CN": "Asia/Shanghai", "ID": "Asia/Jakarta", "MY": "Asia/Kuala_Lumpur", "GB": "Europe/London",
}


def _zone_tab(root="/"):
    rows = []
    try:
        with open(os.path.join(root, ZONEINFO, "zone.tab")) as f:
            for line in f:
                if line.startswith("#") or not line.strip():
                    continue
                p = line.rstrip("\n").split("\t")
                if len(p) >= 3:
                    rows.append((p[0], p[2]))
    except OSError:
        pass
    return rows


def all_zones(root="/"):
    return sorted({tz for _, tz in _zone_tab(root)} | {"UTC"})


def country_zones(cc, root="/"):
    return [tz for c, tz in _zone_tab(root) if c == cc]


def valid_tz(tz, root="/"):
    if not isinstance(tz, str) or not TZ_RE.match(tz) or ".." in tz:
        return False
    if tz != "UTC" and tz not in all_zones(root):
        return False
    return os.path.isfile(os.path.join(root, ZONEINFO, tz))


def detect_mcc(run=subprocess.run):
    """MCC of the registered network via ModemManager (offline, no location services)."""
    try:
        lst = run(["mmcli", "-L"], capture_output=True, text=True, timeout=3).stdout
        m = re.search(r"/Modem/(\d+)", lst)
        if not m:
            return None
        kv = run(["mmcli", "-m", m.group(1), "-K"], capture_output=True, text=True, timeout=3).stdout
        code = re.search(r"modem\.3gpp\.operator-code\s*:\s*(\d{5,6})", kv)
        return code.group(1)[:3] if code else None
    except (OSError, subprocess.SubprocessError):
        return None


def suggest(lang, mcc=None, root="/"):
    """→ (time zone, source 'network'|'lang'|'none', zones of the country)"""
    default = LANGS.get(lang, LANGS["en"])[3]
    cc = MCC.get(mcc or "")
    if cc:
        zones = country_zones(cc, root)
        if zones:
            if default in zones:
                return default, "network", zones
            if PRIMARY.get(cc) in zones:
                return PRIMARY[cc], "network", zones
            return zones[0], "network", zones
    if default and valid_tz(default, root):
        return default, "lang", country_zones(LANGS[lang][4], root)
    return "UTC", "none", []


def is_done(root="/"):
    return os.path.exists(os.path.join(root, DONE))


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".noxis-tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def apply(lang, tz, root="/", compile_schemas=True):
    if lang not in LANGS:
        raise ValueError(f"unknown language: {lang}")
    if not valid_tz(tz, root):
        raise ValueError(f"invalid time zone: {tz}")
    _name, loc, xkb, _tz, _cc = LANGS[lang]
    etc = os.path.join(root, "etc")
    _write(os.path.join(etc, "default/locale"), f"LANG={loc}\n")
    lc = os.path.join(etc, "locale.conf")
    if not os.path.islink(lc):
        _write(lc, f"LANG={loc}\n")
    link = os.path.join(etc, "localtime")
    tmp = link + ".noxis-tmp"
    if os.path.lexists(tmp):
        os.unlink(tmp)
    os.symlink(f"/usr/share/zoneinfo/{tz}", tmp)
    os.replace(tmp, link)
    _write(os.path.join(etc, "timezone"), tz + "\n")
    _write(os.path.join(etc, "default/keyboard"),
           f'XKBMODEL="pc105"\nXKBLAYOUT="{xkb}"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n')
    _write(os.path.join(root, "usr/share/glib-2.0/schemas/95_noxis-lang.gschema.override"),
           f"[org.gnome.desktop.input-sources]\nsources=[('xkb', '{xkb}')]\n\n"
           f"[org.gnome.system.locale]\nregion='{loc}'\n")
    if compile_schemas and root == "/":
        subprocess.run(["glib-compile-schemas", "/usr/share/glib-2.0/schemas"], capture_output=True, timeout=30)
    _write(os.path.join(root, DONE), f"lang={lang}\ntimezone={tz}\n")


if __name__ == "__main__":
    # setup.py apply <lang> <timezone>   (used by the image build when the language is chosen up front)
    if len(sys.argv) == 4 and sys.argv[1] == "apply":
        apply(sys.argv[2], sys.argv[3])
        print(f"noxis setup: {sys.argv[2]} {sys.argv[3]}")
    else:
        print("usage: setup.py apply <de|tr|en|fr|bg|ru|uk> <Area/City>", file=sys.stderr)
        sys.exit(2)
