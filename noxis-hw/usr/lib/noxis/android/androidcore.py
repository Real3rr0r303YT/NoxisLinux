# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
"""Logik hinter "Noxis Android": Zustand lesen, Schritte und Knopf bestimmen.

Ohne GTK, damit sie sich testen laesst. Die Oberflaeche in
/usr/bin/noxis-android setzt nur um, was hier entschieden wird.
"""

HELPER = "/usr/lib/noxis/hw/noxis-waydroid"

# Schluessel -> (Ueberschrift, Text wenn gut, Text wenn nicht, Rat)
CHECKS = (
    ("kernel", "Kernel", "bereit", "nicht bereit",
     "Dieser Kernel kann Android nicht ausfuehren. Daran laesst sich hier nichts drehen."),
    ("paket", "Waydroid", "installiert", "nicht installiert",
     "Das Paket fehlt. Es kommt mit dem naechsten Abbild mit."),
    ("abbild", "Android-Abbild", "vorhanden", "fehlt (etwa 1 GB)",
     "Wird beim Einrichten geholt. Dafuer brauchst du WLAN und etwas Geduld."),
    ("netz", "Weg nach draussen", "frei", "vom Killswitch blockiert",
     "Ohne verbundenes Mullvad kommt der Download nicht raus. "
     "Entweder Mullvad verbinden oder den Killswitch am Rechner abschalten."),
)
GOOD = {"kernel": "ok", "paket": "ok", "abbild": "ok", "netz": "ok"}


def parse_kv(text):
    """Ausgabe von 'noxis-waydroid kv' einlesen. Unbekannte Zeilen stoeren nicht."""
    out = {}
    for line in (text or "").splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            k, v = k.strip(), v.strip()
            if k and v:
                out[k] = v
    return out


def rows(state):
    """-> [(Ueberschrift, Text, gut?)] fuer die Anzeige."""
    res = []
    for key, title, yes, no, _ in CHECKS:
        v = state.get(key, "unbekannt")
        if v == "unbekannt":
            res.append((title, "ungeprueft", None))
        else:
            res.append((title, yes if v == GOOD[key] else no, v == GOOD[key]))
    return res


def blockers(state):
    """Was dem naechsten Schritt im Weg steht, als Ratschlaege."""
    out = []
    for key, _, _, _, hint in CHECKS:
        v = state.get(key, "unbekannt")
        if v == "unbekannt":
            continue
        if v != GOOD[key]:
            # Das Abbild ist kein Hindernis, es ist ja der Zweck des Einrichtens.
            # Und das Netz stoert nur, solange das Abbild fehlt.
            if key == "abbild":
                continue
            if key == "netz" and state.get("abbild") == "ok":
                continue
            out.append(hint)
    return out


def action(state):
    """Was der grosse Knopf tut: einrichten | start | stop | None."""
    if state.get("kernel") == "fehlt" or state.get("paket") == "fehlt":
        return None
    if state.get("abbild") != "ok":
        return "einrichten"
    if state.get("sitzung") == "an":
        return "stop"
    return "start"


LABELS = {
    "einrichten": ("Android einrichten", "Holt das Abbild und richtet alles ein"),
    "start": ("Android starten", "Der erste Start dauert einige Minuten"),
    "stop": ("Android beenden", "Sitzung und Behaelter anhalten"),
}


def label(state):
    a = action(state)
    if a is None:
        return ("Nicht moeglich", "Siehe die Hinweise oben")
    return LABELS[a]


def needs_root(what):
    """'start' laeuft als Benutzer, der Rest braucht Rechte."""
    return what in ("einrichten", "weg")
