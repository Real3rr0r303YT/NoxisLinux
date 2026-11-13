#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
#
# write_customize erzeugt das Skript, das IM Handy-Rootfs laeuft. Es steckt in
# einem nicht gequoteten Heredoc: jedes $ darin muss mit \$ maskiert sein,
# sonst ersetzt es schon das Bau-Skript auf dem PC. Unter "set -u" bricht der
# Bau dann mit "unbound variable" ab - und zwar erst nach dem Kernelbau, also
# eine halbe Stunde zu spaet. Genau das ist einmal passiert.
#
# Dieser Test erzeugt customize.sh und prueft es samt der darin eingebetteten
# Skripte auf Syntax.
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail + 1)); }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# Die Funktion allein herausloesen und mit gesetzten Variablen laufen lassen.
start=$(grep -n '^write_customize()' "$HERE/build-noxis-linux.sh" | cut -d: -f1)
[ -n "$start" ] || { echo "write_customize nicht gefunden"; exit 1; }
end=$(awk -v s="$start" 'NR>=s && /^}/ {print NR; exit}' "$HERE/build-noxis-linux.sh")
sed -n "${start},${end}p" "$HERE/build-noxis-linux.sh" > "$W/fn.sh"

cat > "$W/run.sh" <<OUTER
set -eu
WORK="$W"
NUSER=noxis; NPIN=1234; NLANG=de; NTZ=Europe/Berlin
VERSION=1.0.0; SUITE=trixie; ARCH=arm64
PKG_PENTEST="nmap"; PENTEST=1; PKG_OPTIONAL="gnome-console"
. "$W/fn.sh"
write_customize
OUTER

echo "write_customize"
if bash "$W/run.sh" 2>"$W/err"; then
  ok "laeuft unter set -u durch (keine unmaskierten Variablen)"
else
  bad "bricht ab: $(head -2 "$W/err" | tr '\n' ' ')"
fi

if [ -f "$W/customize.sh" ]; then
  check "customize.sh: Syntax" "sh -n '$W/customize.sh'"

  # Die eingebetteten Skripte einzeln pruefen: ein Syntaxfehler darin faellt
  # sonst erst auf dem Handy auf.
  for name in noxis-gpu; do
    awk -v n="/usr/bin/$name" '
      $0 ~ "cat > " n " <<" {inside=1; next}
      inside && /^[A-Z]+$/ {inside=0}
      inside {print}
    ' "$W/customize.sh" > "$W/$name"
    if [ -s "$W/$name" ]; then
      check "$name: Syntax" "sh -n '$W/$name'"
      check "$name: \$D kam unmaskiert durch" "grep -q 'F=\$D/' '$W/$name'"
    else
      bad "$name: nicht im erzeugten Skript gefunden"
    fi
  done

  check "Branding: os-release wird umgebogen" "grep -q 'noxis-shell.deb' '$W/customize.sh'"
  check "Tastatur: Schemas werden uebersetzt"  "grep -q 'glib-compile-schemas' '$W/customize.sh'"
else
  bad "customize.sh wurde nicht erzeugt"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
