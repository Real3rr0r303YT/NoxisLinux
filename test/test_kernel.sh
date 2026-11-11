#!/usr/bin/env bash
# Tests für kernel/: Config-Fragment gegen echte Nothing-Quellen, Modullisten, Initramfs-Funktionen, Pakete
# ./test/test_kernel.sh [<pfad-zum-nothing-kernel>]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KSRC="${1:-}"
pass=0; fail=0
ok()  { echo "  ✓ $*"; pass=$((pass + 1)); }
bad() { echo "  ✗ $*"; fail=$((fail + 1)); }
t()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# shellcheck source=/dev/null
NOXIS_KWORK="$T/kw" NOXIS_KOUT="$T/out" source "$ROOT/kernel/build-noxis-kernel.sh"
set +e

echo "== Syntax"
t "build-noxis-kernel.sh"  bash -n "$ROOT/kernel/build-noxis-kernel.sh"
t "initramfs/init (sh)"    sh -n "$ROOT/kernel/initramfs/init"
t "build-noxis-linux.sh"   bash -n "$ROOT/build-noxis-linux.sh"

echo "== Config-Fragment"
t "jede Zeile ist CONFIG_*=wert" bash -c "grep -vE '^(#|$)' '$ROOT/kernel/noxis.config' | grep -vqE '^CONFIG_[A-Z0-9_]+=' && exit 1 || exit 0"
if [ -n "$KSRC" ] && [ -d "$KSRC/scripts/kconfig" ]; then
  missing=""
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; k="${k#CONFIG_}"
    grep -rqx "config $k" --include='Kconfig*' "$KSRC" || missing="$missing $k"
  done < "$ROOT/kernel/noxis.config"
  [ -z "$missing" ] && ok "alle Symbole existieren im Nothing-Kernel" || bad "unbekannte Symbole:$missing"

  O="$T/obj"; mkdir -p "$O"; cfg="$KSRC/arch/arm64/configs"
  ( cd "$KSRC" && scripts/kconfig/merge_config.sh -m -r -O "$O" "$cfg/gki_defconfig" "$cfg/vendor/pineapple_GKI.config" \
      "$cfg/vendor/Asteroids.config" "$ROOT/kernel/noxis.config" >/dev/null 2>&1 )
  t "merge_config.sh erzeugt .config" test -s "$O/.config"
  out=$(verify_config 2>&1)
  echo "$out" | grep -q "Alle Noxis-Optionen gesetzt" && ok "verify_config: alle Optionen im Merge" || { bad "verify_config"; echo "$out"; }
  t "ARCH_VOLCANO bleibt an"        grep -qx 'CONFIG_ARCH_VOLCANO=y' "$O/.config"
  t "NOTHING_IS_ASTEROIDS bleibt an" grep -qx 'CONFIG_NOTHING_IS_ASTEROIDS=y' "$O/.config"
  t "CFI_CLANG bleibt an"           grep -qx 'CONFIG_CFI_CLANG=y' "$O/.config"
  echo 'CONFIG_DEVTMPFS=n' > "$T/frag"; sed -i 's/^CONFIG_DEVTMPFS=y$/# CONFIG_DEVTMPFS is not set/' "$O/.config"
  out=$(verify_config 2>&1); echo "$out" | grep -q "CONFIG_DEVTMPFS=y nicht übernommen" && ok "verify_config meldet fehlende Option" || bad "verify_config erkennt Fehler nicht"
  for d in mmrm-driver mm-drivers/hw_fence mm-drivers/sync_fence mm-drivers/msm_ext_display securemsm-kernel synx-kernel graphics-kernel display-drivers touch-drivers; do
    [ -d "$KSRC/vendor/qcom/opensource/$d" ] || { bad "externes Modul fehlt: $d"; continue; }
  done; ok "externe Modulordner vorhanden (9)"
else
  echo "  – kein Kernelpfad: Config-Tests übersprungen"
fi

echo "== Modullisten"
mkdir -p "$T/l"
printf 'a.ko\nb.ko\n8250_of.ko\n' > "$T/l/1"; printf 'b.ko\nc.ko\n\n' > "$T/l/2"
res=$(resolve_list "$T/l/1" "$T/l/2" | tr '\n' ' ')
[ "$res" = "a b c " ] && ok "Reihenfolge, ohne Doppelte, Blocklist (8250_of) entfernt" || bad "resolve_list: '$res'"
n=$(resolve_list "$ROOT/kernel/modules/modules.load.vendor_boot" "$ROOT/kernel/modules/modules.load.recovery" | wc -l)
[ "$n" -gt 90 ] && ok "First-Stage-Liste: $n Module" || bad "First-Stage-Liste zu kurz: $n"
all=$(resolve_list "$ROOT/kernel/modules/modules.load.vendor_boot" "$ROOT/kernel/modules/modules.load.recovery" \
    "$ROOT/kernel/modules/modules.load.vendor_dlkm")
for m in ufs-qcom dwc3-msm msm_drm msm_kgsl focaltech_fts; do
  printf '%s\n' "$all" | grep -qx "$m" && ok "Liste enthält $m" || bad "Liste ohne $m"
done

echo "== Initramfs-Funktionen"
mkdir -p "$T/sys/sda1" "$T/sys/sda17" "$T/sys/sde5"
printf 'MAJOR=8\nDEVNAME=sda1\nPARTNAME=ssd\n'        > "$T/sys/sda1/uevent"
printf 'MAJOR=8\nDEVNAME=sda17\nPARTNAME=userdata\n'  > "$T/sys/sda17/uevent"
printf 'MAJOR=8\nDEVNAME=sde5\nPARTNAME=modem_b\n'    > "$T/sys/sde5/uevent"
echo 'console=tty0 noxis.root=userdata noxis.debug=0 androidboot.slot_suffix=_a' > "$T/cmdline"
printf 'androidboot.hardware = "qcom"\nandroidboot.slot_suffix = "_b"\n' > "$T/bootconfig"
run_init() { NOXIS_T_LIB=1 NOXIS_T_CMDLINE="$T/cmdline" NOXIS_T_BOOTCONFIG="$T/bootconfig" NOXIS_T_SYSBLOCK="$T/sys" \
  sh -c ". '$ROOT/kernel/initramfs/init'; $1"; }
[ "$(run_init 'find_part userdata')" = /dev/sda17 ] && ok "find_part userdata → /dev/sda17" || bad "find_part userdata"
[ "$(run_init 'find_part modem_b')" = /dev/sde5 ] && ok "find_part modem_b → /dev/sde5" || bad "find_part modem_b"
run_init 'find_part user' >/dev/null && bad "find_part matcht Teilnamen" || ok "kein Teil-Treffer (user ≠ userdata)"
[ "$(run_init 'bootconfig_get androidboot.slot_suffix')" = _b ] && ok "Slot aus bootconfig (_b)" || bad "bootconfig_get"
[ "$(run_init 'cmdline_get noxis.root')" = userdata ] && ok "cmdline noxis.root" || bad "cmdline_get"
[ "$(run_init 'cmdline_get noxis.debug')" = 0 ] && ok "noxis.debug=0 → kein Debug" || bad "noxis.debug"
run_init 'cmdline_get fehlt' >/dev/null && bad "cmdline_get liefert Unbekanntes" || ok "unbekannter Schlüssel → Fehler"
s=$(date +%s); run_init 'wait_part gibtsnicht 1' >/dev/null; e=$(( $(date +%s) - s ))
[ "$e" -le 3 ] && ok "wait_part bricht nach Zeitlimit ab (${e}s)" || bad "wait_part hängt (${e}s)"
grep -q 'telnetd -b 172.16.42.1' "$ROOT/kernel/initramfs/init" && ok "Debug-Shell nur auf USB-Adresse" || bad "telnetd-Bindung"
grep -q 'cmdline_get noxis.debug)" = 1' "$ROOT/kernel/initramfs/init" && ok "Debug nur mit noxis.debug=1" || bad "Debug-Bedingung"

echo "== Pakete"
if command -v dpkg-deb >/dev/null; then
  mkdir -p "$KWORK" "$KOUT/device" "$T/r/usr/lib/noxis"; echo 0123456789abcdef0123 > "$KWORK/commit"
  echo test > "$T/r/usr/lib/noxis/boot.img"
  mkdeb linux-bootimage-noxis-asteroids "$T/r" "Test" 2>/dev/null
  d="$KOUT/device/linux-bootimage-noxis-asteroids_1.0.0_arm64.deb"
  t "linux-bootimage-*.deb gebaut" test -f "$d"
  dpkg-deb -c "$d" | grep -q './usr/lib/noxis/boot.img' && ok "boot.img im Paket (cmd_boot findet es)" || bad "boot.img nicht im Paket"
  [ "$(dpkg-deb -f "$d" Architecture)" = arm64 ] && ok "Architektur arm64" || bad "Architektur"
  dpkg-deb -f "$d" Version | grep -q '^1.0.0+0123456789ab$' && ok "Version enthält Commit" || bad "Version"
fi

echo
echo "$pass bestanden, $fail fehlgeschlagen"
[ "$fail" = 0 ]
