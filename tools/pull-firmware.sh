#!/usr/bin/env bash
# Noxis – copy the device firmware from your own Nothing Phone (3a) while it still runs Android.
# Needed for Wi-Fi, Bluetooth, GPU, audio DSP and camera firmware that is not on the modem partition.
# usage: ./tools/pull-firmware.sh [output folder]   (USB debugging on, "adb devices" shows the phone)
# Then:  NOXIS_FIRMWARE=<output folder>/firmware sudo -E ./build-noxis-linux.sh kernel
# The firmware is proprietary – keep it on your machine, never commit or share it.
set -euo pipefail
OUT="${1:-$HOME/noxis-firmware}"
command -v adb >/dev/null || { echo "adb missing (Gentoo: emerge dev-util/android-tools, Debian: apt install adb)"; exit 1; }
model=$(adb shell getprop ro.product.device 2>/dev/null | tr -d '\r')
case "$model" in
  Asteroids|asteroids|AsteroidsP*) ;;
  "") echo "no phone found – enable USB debugging and accept the prompt"; exit 1 ;;
  *) echo "warning: device '$model' is not the Nothing Phone (3a) (asteroids)"; read -r -p "continue anyway? [y/N] " a; [ "$a" = y ] || exit 1 ;;
esac
mkdir -p "$OUT"
echo "[noxis] /vendor/firmware → $OUT/firmware"
adb pull -a /vendor/firmware "$OUT/" >/dev/null
# Wi-Fi config: Android links it from /vendor/etc/wifi into the firmware tree
ini=wlan/qca_cld/qca6750/WCNSS_qcom_cfg.ini
mkdir -p "$OUT/firmware/$(dirname "$ini")"
adb pull /vendor/etc/wifi/qca6750/WCNSS_qcom_cfg.ini "$OUT/firmware/$ini" >/dev/null 2>&1 \
  || echo "[noxis] note: WCNSS_qcom_cfg.ini not readable – Wi-Fi uses driver defaults"
# replace dangling symlinks (they point into Android-only paths)
find "$OUT/firmware" -xtype l -print -delete | sed 's/^/[noxis] removed dangling link: /' || true
n=$(find "$OUT/firmware" -type f | wc -l)
du -sh "$OUT/firmware" | sed "s/^/[noxis] $n files, /"
( cd "$OUT/firmware" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$OUT/firmware.sha256"
echo "[noxis] next: NOXIS_FIRMWARE=$OUT/firmware sudo -E ./build-noxis-linux.sh kernel"
