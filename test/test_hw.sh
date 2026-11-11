#!/usr/bin/env bash
# Tests for noxis-hw-asteroids: firmware links, radio bring-up, Bluetooth power helper, units, firmware tool.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HW="$ROOT/noxis-hw"
pass=0; fail=0
ok()  { echo "  ✓ $*"; pass=$((pass + 1)); }
bad() { echo "  ✗ $*"; fail=$((fail + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

echo "== Firmware links"
F="$T/fw"
mkdir -p "$F/vendor/firmware_mnt/image" "$F/vendor/firmware/wlan" "$F/vendor/dsp" "$F/lib/firmware"
for f in modem.mdt modem.b01 modemr.jsn wpss.mdt msbtfw11.mbn msnv11.bin a650_sqe.fw; do echo img > "$F/vendor/firmware_mnt/image/$f"; done
echo vendor > "$F/vendor/firmware/a650_sqe.fw"; echo v > "$F/vendor/firmware/gmu.bin"
echo real > "$F/lib/firmware/regulatory.db"; echo real > "$F/lib/firmware/gmu.bin"
NOXIS_FW_ROOT="$F" sh "$HW/usr/lib/noxis/hw/noxis-firmware-links" > "$T/l1"
[ "$(readlink "$F/lib/firmware/modem.mdt")" = /vendor/firmware_mnt/image/modem.mdt ] && ok "modem.mdt → modem partition (absolute target)" || bad "modem link: $(readlink "$F/lib/firmware/modem.mdt")"
[ -L "$F/lib/firmware/modemr.jsn" ] && ok "pd-mapper .jsn linked" || bad "jsn"
[ "$(readlink "$F/lib/firmware/a650_sqe.fw")" = /vendor/firmware_mnt/image/a650_sqe.fw ] && ok "modem image wins over /vendor/firmware for duplicates" || bad "priority"
[ ! -L "$F/lib/firmware/gmu.bin" ] && [ "$(cat "$F/lib/firmware/gmu.bin")" = real ] && ok "real Debian firmware never replaced" || bad "overwrote real firmware"
[ -L "$F/lib/firmware/qca/msbtfw11.mbn" ] && [ -L "$F/lib/firmware/qca/msnv11.bin" ] && ok "Bluetooth firmware in qca/ for btqca" || bad "qca links"
NOXIS_FW_ROOT="$F" sh "$HW/usr/lib/noxis/hw/noxis-firmware-links" > "$T/l2"
grep -q ": 0 links" "$T/l2" && ok "second run idempotent (0 new links)" || bad "not idempotent: $(cat "$T/l2")"
NOXIS_FW_ROOT="$T/empty" sh "$HW/usr/lib/noxis/hw/noxis-firmware-links" >/dev/null 2>&1 && ok "no /vendor → no error" || bad "fails without vendor"

echo "== Radio bring-up"
S="$T/sys"
mkdir -p "$S/kernel/boot_adsp" "$S/kernel/cnss"
: > "$S/kernel/boot_adsp/boot"; : > "$S/kernel/cnss/fs_ready"
for i in 0 1 2; do mkdir -p "$S/class/remoteproc/remoteproc$i"; done
printf 'modem\n' > "$S/class/remoteproc/remoteproc0/name"; echo offline > "$S/class/remoteproc/remoteproc0/state"
printf 'adsp\n'  > "$S/class/remoteproc/remoteproc1/name"; echo running > "$S/class/remoteproc/remoteproc1/state"
printf 'cdsp\n'  > "$S/class/remoteproc/remoteproc2/name"; echo offline > "$S/class/remoteproc/remoteproc2/state"
NOXIS_SYS="$S" sh "$HW/usr/lib/noxis/hw/noxis-radios" > "$T/r1"; rc=$?
[ $rc = 0 ] && ok "noxis-radios exits 0" || bad "rc $rc"
[ "$(cat "$S/kernel/boot_adsp/boot")" = 1 ] && ok "ADSP boot requested" || bad "adsp"
[ "$(cat "$S/class/remoteproc/remoteproc0/state")" = start ] && [ "$(cat "$S/class/remoteproc/remoteproc2/state")" = start ] && ok "offline remoteprocs started (modem, cdsp)" || bad "remoteproc start"
[ "$(cat "$S/class/remoteproc/remoteproc1/state")" = running ] && ok "running remoteproc untouched" || bad "touched running"
[ "$(cat "$S/kernel/cnss/fs_ready")" = 1 ] && ok "WLAN fs_ready signalled" || bad "fs_ready"
grep -q "modem: started" "$T/r1" && grep -q "adsp: running" "$T/r1" && ok "log names each remote processor" || bad "log: $(cat "$T/r1")"
NOXIS_SYS="$T/nosys" sh "$HW/usr/lib/noxis/hw/noxis-radios" >/dev/null 2>&1 && ok "no remoteprocs → still exits 0" || bad "fails on empty sys"

echo "== Bluetooth power helper"
BP="$HW/usr/lib/noxis/hw/noxis-btpower"
python3 "$BP" >/dev/null 2>&1; [ $? = 2 ] && ok "usage error → exit 2" || bad "usage"
NOXIS_BTPOWER="$T/nodev" python3 "$BP" on >/dev/null 2>&1; [ $? = 1 ] && ok "missing /dev/btpower → exit 1" || bad "missing dev"
: > "$T/regular"; NOXIS_BTPOWER="$T/regular" python3 "$BP" on > "$T/b1" 2>&1; [ $? = 1 ] && grep -q "ioctl failed" "$T/b1" && ok "ioctl on non-device → clean error" || bad "ioctl: $(cat "$T/b1")"
grep -q "0xBFAD" "$BP" && ok "ioctl BT_CMD_PWR_CTRL 0xbfad (from Nothing's btpower.h)" || bad "ioctl number"

echo "== Units & package"
U="$HW/usr/lib/systemd/system"
grep -q "Before=systemd-modules-load.service" "$U/noxis-firmware-links.service" && ok "firmware links before module loading" || bad "fw unit order"
grep -q "Before=NetworkManager.service ModemManager.service" "$U/noxis-radios.service" && grep -q "After=.*pd-mapper.service" "$U/noxis-radios.service" && ok "radios after pd-mapper, before NetworkManager/ModemManager" || bad "radios order"
grep -q "btattach -B /dev/ttyHS0 -P qca" "$U/noxis-bluetooth.service" && ok "Bluetooth: btattach qca on ttyHS0 (Android's BT UART)" || bad "bt unit"
grep -q "wlan_firmware_service\|qca_cld3_qca6750" "$ROOT/kernel/modules/modules.load.vendor_dlkm" && ok "WLAN modules in the load list" || bad "wlan modules"
grep -q 'wlan/qcacld-3.0|WLAN_ROOT' "$ROOT/kernel/build-noxis-kernel.sh" && grep -q 'volcano_gki_qca6750' "$ROOT/kernel/build-noxis-kernel.sh" && ok "kernel build: qcacld-3.0 with the volcano qca6750 profile" || bad "kernel wlan"
[ -f "$ROOT/kernel/../noxis-hw/DEBIAN/control" ] && grep -q "Recommends: rmtfs, pd-mapper, tqftpserv" "$HW/DEBIAN/control" && ok "package recommends rmtfs, pd-mapper, tqftpserv" || bad "control"
sh -n "$HW/DEBIAN/postinst" && ok "postinst syntax" || bad "postinst"
command -v dpkg-deb >/dev/null && dpkg-deb --root-owner-group -b "$HW" "$T/hw.deb" >/dev/null 2>&1 && ok "package builds" || bad "dpkg-deb"
bash -n "$ROOT/tools/pull-firmware.sh" && grep -q 'find "$OUT/firmware" -xtype l' "$ROOT/tools/pull-firmware.sh" && ok "pull-firmware.sh: syntax, drops dangling links" || bad "pull-firmware"

echo; echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
