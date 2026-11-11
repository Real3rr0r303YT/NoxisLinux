#!/usr/bin/env bash
# Tests for kernel/: config fragment against the real Nothing sources, module lists, initramfs functions, packages
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

echo "== Config fragment"
t "every line is CONFIG_*=value" bash -c "grep -vE '^(#|$)' '$ROOT/kernel/noxis.config' | grep -vqE '^CONFIG_[A-Z0-9_]+=' && exit 1 || exit 0"
if [ -n "$KSRC" ] && [ -d "$KSRC/scripts/kconfig" ]; then
  missing=""
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    k="${line%%=*}"; k="${k#CONFIG_}"
    grep -rqx "config $k" --include='Kconfig*' "$KSRC" || missing="$missing $k"
  done < "$ROOT/kernel/noxis.config"
  [ -z "$missing" ] && ok "all symbols exist in the Nothing kernel" || bad "unknown symbols:$missing"

  O="$T/obj"; mkdir -p "$O"; cfg="$KSRC/arch/arm64/configs"
  ( cd "$KSRC" && scripts/kconfig/merge_config.sh -m -r -O "$O" "$cfg/gki_defconfig" "$cfg/vendor/pineapple_GKI.config" \
      "$cfg/vendor/Asteroids.config" "$ROOT/kernel/noxis.config" >/dev/null 2>&1 )
  t "merge_config.sh creates .config" test -s "$O/.config"
  out=$(verify_config 2>&1)
  echo "$out" | grep -q "All Noxis options set" && ok "verify_config: all options in the merge" || { bad "verify_config"; echo "$out"; }
  t "ARCH_VOLCANO stays on"         grep -qx 'CONFIG_ARCH_VOLCANO=y' "$O/.config"
  t "NOTHING_IS_ASTEROIDS stays on" grep -qx 'CONFIG_NOTHING_IS_ASTEROIDS=y' "$O/.config"
  t "CFI_CLANG stays on"            grep -qx 'CONFIG_CFI_CLANG=y' "$O/.config"
  echo 'CONFIG_DEVTMPFS=n' > "$T/frag"; sed -i 's/^CONFIG_DEVTMPFS=y$/# CONFIG_DEVTMPFS is not set/' "$O/.config"
  out=$(verify_config 2>&1); echo "$out" | grep -q "CONFIG_DEVTMPFS=y not applied" && ok "verify_config reports a missing option" || bad "verify_config misses errors"
  for d in mmrm-driver mm-drivers/hw_fence mm-drivers/sync_fence mm-drivers/msm_ext_display securemsm-kernel synx-kernel graphics-kernel display-drivers touch-drivers; do
    [ -d "$KSRC/vendor/qcom/opensource/$d" ] || { bad "external module missing: $d"; continue; }
  done; ok "external module folders present (9)"
else
  echo "  – no kernel path: config tests skipped"
fi

echo "== Module lists"
mkdir -p "$T/l"
printf 'a.ko\nb.ko\n8250_of.ko\n' > "$T/l/1"; printf 'b.ko\nc.ko\n\n' > "$T/l/2"
res=$(resolve_list "$T/l/1" "$T/l/2" | tr '\n' ' ')
[ "$res" = "a b c " ] && ok "order kept, no duplicates, blocklist (8250_of) removed" || bad "resolve_list: '$res'"
n=$(resolve_list "$ROOT/kernel/modules/modules.load.vendor_boot" "$ROOT/kernel/modules/modules.load.recovery" | wc -l)
[ "$n" -gt 90 ] && ok "first-stage list: $n modules" || bad "first-stage list too short: $n"
all=$(resolve_list "$ROOT/kernel/modules/modules.load.vendor_boot" "$ROOT/kernel/modules/modules.load.recovery" \
    "$ROOT/kernel/modules/modules.load.vendor_dlkm")
for m in ufs-qcom dwc3-msm msm_drm msm_kgsl focaltech_fts; do
  printf '%s\n' "$all" | grep -qx "$m" && ok "list contains $m" || bad "list lacks $m"
done

echo "== Initramfs functions"
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
run_init 'find_part user' >/dev/null && bad "find_part matches partial names" || ok "no partial match (user ≠ userdata)"
[ "$(run_init 'bootconfig_get androidboot.slot_suffix')" = _b ] && ok "slot from bootconfig (_b)" || bad "bootconfig_get"
[ "$(run_init 'cmdline_get noxis.root')" = userdata ] && ok "cmdline noxis.root" || bad "cmdline_get"
[ "$(run_init 'cmdline_get noxis.debug')" = 0 ] && ok "noxis.debug=0 → no debug" || bad "noxis.debug"
run_init 'cmdline_get fehlt' >/dev/null && bad "cmdline_get returns unknown keys" || ok "unknown key → error"
s=$(date +%s); run_init 'wait_part gibtsnicht 1' >/dev/null; e=$(( $(date +%s) - s ))
[ "$e" -le 3 ] && ok "wait_part stops after the timeout (${e}s)" || bad "wait_part hangs (${e}s)"
grep -q 'telnetd -b 172.16.42.1' "$ROOT/kernel/initramfs/init" && ok "debug shell only on the USB address" || bad "telnetd binding"
grep -q 'cmdline_get noxis.debug)" = 1' "$ROOT/kernel/initramfs/init" && ok "debug only with noxis.debug=1" || bad "debug condition"

echo "== Packages"
if command -v dpkg-deb >/dev/null; then
  mkdir -p "$KWORK" "$KOUT/device" "$T/r/usr/lib/noxis"; echo 0123456789abcdef0123 > "$KWORK/commit"
  echo test > "$T/r/usr/lib/noxis/boot.img"
  mkdeb linux-bootimage-noxis-asteroids "$T/r" "Test" 2>/dev/null
  d="$KOUT/device/linux-bootimage-noxis-asteroids_1.0.0_arm64.deb"
  t "linux-bootimage-*.deb built" test -f "$d"
  dpkg-deb -c "$d" | grep -q './usr/lib/noxis/boot.img' && ok "boot.img in the package (cmd_boot finds it)" || bad "boot.img not in the package"
  [ "$(dpkg-deb -f "$d" Architecture)" = arm64 ] && ok "architecture arm64" || bad "architecture"
  dpkg-deb -f "$d" Version | grep -q '^1.0.0+0123456789ab$' && ok "version contains the commit" || bad "Version"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
