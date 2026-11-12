#!/usr/bin/env bash
# ============================================================
#  Noxis Linux – kernel for the Nothing Phone (3a) from the Nothing sources
#  Source: github.com/NothingOSS/android_kernel_msm-6.1_nothing_sm7635 (--depth=1)
#  Runs on Debian trixie (amd64 or arm64), easiest via:
#      sudo ./build-noxis-linux.sh kernel
#
#  Output in $NOXIS_KOUT (default: ./out-kernel):
#    boot.img                                   GKI kernel + Noxis initramfs (header v4)
#    device/linux-bootimage-noxis-asteroids_*.deb   → for build-noxis-linux.sh (NOXIS_DEVICE_DEBS)
#    device/noxis-kernel-asteroids_*.deb            modules + load lists for the rootfs
#    device/noxis-firmware-asteroids_*.deb          only with NOXIS_FIRMWARE=<folder> (adb pull /vendor/firmware)
#    build-report.txt  SHA256SUMS
#
#  Variables: NOXIS_KWORK NOXIS_KOUT NOXIS_KERNEL_BRANCH NOXIS_JOBS NOXIS_FIRMWARE NOXIS_BOOT_SIZE NOXIS_CMDLINE
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${NOXIS_KERNEL_REPO:-https://github.com/NothingOSS/android_kernel_msm-6.1_nothing_sm7635}"
BRANCH="${NOXIS_KERNEL_BRANCH:-sm7635/b/mr}"
KWORK="${NOXIS_KWORK:-$HOME/noxis-kernel-build}"
KOUT="${NOXIS_KOUT:-$HERE/out-kernel}"
JOBS="${NOXIS_JOBS:-$(nproc)}"
BOOT_SIZE="${NOXIS_BOOT_SIZE:-67108864}"          # 64 MiB, taken from BOOT_STOCK=<boot.img> if given
CMDLINE="${NOXIS_CMDLINE:-console=tty0 quiet splash loglevel=3 selinux=0 rdinit=/noxis-init noxis.root=userdata}"
PKGVER="1.0.0"

# Qualcomm module makefiles expect the Android layout kernel_platform/msm-kernel + ../../vendor
SRC="$KWORK/kernel_platform/msm-kernel"; O="$KWORK/obj"; STAGE="$KWORK/stage"; IRD="$KWORK/initramfs"; DEBS="$KWORK/debs"
BASE_KCFLAGS="-D__ANDROID_COMMON_KERNEL__ -DNT_PROJECT=Asteroids -Wno-error"
MAKEARGS=(ARCH=arm64 LLVM=1 LLVM_IAS=1 O="$O" KCFLAGS="$BASE_KCFLAGS")

c()    { printf '\033[38;5;111m[noxis-kernel]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# external Qualcomm/Nothing modules: folder | ROOT variable | extra make arguments
#                                    | extra KCFLAGS (may contain spaces)
# (order = dependencies; @P = module path, @V = vendor/qcom/opensource)
WLAN_PLATFORM_OPTS="CONFIG_CNSS_OUT_OF_TREE=y CONFIG_CNSS2=m CONFIG_ICNSS2=m CONFIG_CNSS2_QMI=y CONFIG_ICNSS2_QMI=y \
CONFIG_CNSS_QMI_SVC=m CONFIG_CNSS_PLAT_IPC_QMI_SVC=m CONFIG_CNSS_GENL=m CONFIG_WCNSS_MEM_PRE_ALLOC=m CONFIG_CNSS_UTILS=m"
WLAN_CLD_OPTS="MODNAME=qca_cld3_qca6750 WLAN_PROFILE=volcano_gki_qca6750 CONFIG_QCA_CLD_WLAN=m \
CONFIG_CNSS_OUT_OF_TREE=y QCA_WIFI_FTM_NL80211=y \
CONFIG_QCA_WIFI_ISOC=0 CONFIG_QCA_WIFI_2_0=1 WLAN_COMMON_ROOT=cmn WLAN_COMMON_INC=@P/cmn WLAN_FW_API=@V/wlan/fw-api \
WLAN_PLATFORM_INC=@V/wlan/platform/inc"
EXT_MODULES=(
  "mmrm-driver|MMRM_ROOT|"
  "mm-drivers/hw_fence|MSM_HW_FENCE_ROOT|"
  "mm-drivers/sync_fence|SYNC_FENCE_ROOT|"
  "mm-drivers/msm_ext_display|MSM_EXT_DISPLAY_ROOT|"
  "securemsm-kernel|SSG_MODULE_ROOT|"
  "synx-kernel|SYNX_ROOT|"
  "graphics-kernel|KGSL_MODULE_ROOT|"
  "display-drivers|DISPLAY_ROOT|"
  "touch-drivers|TOUCH_ROOT|"
  "wlan/platform|WLAN_PLATFORM_ROOT|$WLAN_PLATFORM_OPTS"
  "wlan/qcacld-3.0|WLAN_ROOT|$WLAN_CLD_OPTS"
  "dataipa|DATAIPA_ROOT|"
  "datarmnet-ext/mem|RMNET_MEM_ROOT|"
  "datarmnet/core|RMNET_CORE_ROOT||-DCONFIG_RMNET_LA_PLATFORM -I@V/dataipa/drivers/platform/msm/include -I@V/dataipa/drivers/platform/msm/include/uapi -I@V/datarmnet-ext/mem"
  "bt-kernel|BT_ROOT|CONFIG_MSM_BT_POWER=m CONFIG_BTFM_SLIM=m"
)

# ------------------------------------------------------------ check
cmd_check() {
  local miss=0 t
  for t in clang ld.lld llvm-ar llvm-objcopy make bc bison flex perl python3 git cpio gzip depmod \
           mkbootimg dpkg-deb openssl sha256sum; do
    if command -v "$t" >/dev/null 2>&1; then echo "  ✓ $t"; else echo "  ✗ $t"; miss=1; fi
  done
  [ -f /usr/include/libelf.h ] && echo "  ✓ libelf-dev" || { echo "  ✗ libelf-dev"; miss=1; }
  [ -f /usr/include/openssl/ssl.h ] && echo "  ✓ libssl-dev" || { echo "  ✗ libssl-dev"; miss=1; }
  [ "$miss" = 0 ] && { c "All set (clang $(clang -dumpversion), $JOBS jobs)."; return 0; }
  cat <<'EOF'

Debian:  sudo apt install clang lld llvm make bc bison flex perl python3 git cpio kmod mkbootimg \
                 libelf-dev libssl-dev dpkg-dev ca-certificates
Other:   sudo ./build-noxis-linux.sh kernel   (everything in a Debian container)
EOF
  return 1
}

# ------------------------------------------------------------ source
cmd_source() {
  mkdir -p "$KWORK"
  if [ -d "$SRC/.git" ]; then
    c "Updating sources ($BRANCH, --depth=1)"
    git -C "$SRC" fetch -q --depth=1 origin "$BRANCH"
    git -C "$SRC" reset -q --hard FETCH_HEAD
    git -C "$SRC" clean -qfdx
  else
    c "Cloning the Nothing kernel ($BRANCH, --depth=1, ~2 GB)"
    mkdir -p "$(dirname "$SRC")"
    git clone -q --depth=1 --single-branch -b "$BRANCH" "$REPO" "$SRC"
  fi
  ln -sfn kernel_platform/msm-kernel/vendor "$KWORK/vendor"   # $(srctree)/../../vendor
  git -C "$SRC" rev-parse HEAD > "$KWORK/commit"
  c "Commit $(cat "$KWORK/commit")"
}

# ------------------------------------------------------------ config
cmd_config() {
  [ -d "$SRC" ] || cmd_source
  mkdir -p "$O"
  local cfg="$SRC/arch/arm64/configs"
  c "Config: gki_defconfig + pineapple_GKI + Asteroids + noxis"
  ( cd "$SRC" && ARCH=arm64 LLVM=1 \
      scripts/kconfig/merge_config.sh -m -r -O "$O" "$cfg/gki_defconfig" "$cfg/vendor/pineapple_GKI.config" \
      "$cfg/vendor/Asteroids.config" "$HERE/noxis.config" >/dev/null )
  make -s -C "$SRC" "${MAKEARGS[@]}" olddefconfig
  verify_config
}

verify_config() {  # every Noxis option must end up in the result
  local bad=0 line key val got
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    got=$(grep -E "^$key=|^# $key is not set" "$O/.config" | head -n1 || true)
    if [ "$val" = n ]; then
      case "$got" in ""|"# $key is not set"|"$key=n") ;; *) warn "$key should be n, is: $got"; bad=1 ;; esac
    elif [ "$got" != "$key=$val" ]; then
      warn "$key=$val not applied (is: ${got:-missing})"; bad=1
    fi
  done < "$HERE/noxis.config"
  [ "$bad" = 0 ] && c "All Noxis options set." || warn "Some options missing (dependencies) – see above."
  return 0
}

# ------------------------------------------------------------ build
cmd_build() {
  [ -f "$O/.config" ] || cmd_config
  c "Building kernel + in-tree modules ($JOBS jobs)"
  if ! make -C "$SRC" "${MAKEARGS[@]}" -j"$JOBS" Image.gz modules >"$KWORK/build.log" 2>&1; then
    grep -E 'error|Error' "$KWORK/build.log" | tail -n 30 >&2 || true
    die "Kernel build failed – $KWORK/build.log"
  fi
  [ -f "$O/arch/arm64/boot/Image.gz" ] || die "Image.gz missing"
  c "Image.gz: $(du -h "$O/arch/arm64/boot/Image.gz" | cut -f1)"
  build_external
}

# The mm-drivers Kbuilds expect their ROOT to point at mm-drivers/ itself, with
# a trailing slash: they use both $(ROOT)/config/kalamammdrivers.conf and
# $(ROOT)hw_fence/include/. Passing the module path made them look for
# hw_fence/config/, which does not exist, and took graphics-kernel down with
# them for the missing symbols.
root_for() {
  case "$1" in
    mm-drivers/*) printf '%s/mm-drivers/' "$2" ;;
    *)            printf '%s' "$3" ;;
  esac
}

build_external() {
  local syms="" entry dir var extra kcf path ok=() fail=() vend="$SRC/vendor/qcom/opensource"
  for entry in "${EXT_MODULES[@]}"; do
    IFS='|' read -r dir var extra kcf <<<"$entry"
    path="$vend/$dir"
    [ -d "$path" ] || { fail+=("$dir (missing)"); continue; }
    extra="${extra//@P/$path}"; extra="${extra//@V/$vend}"
    kcf="${kcf//@P/$path}"; kcf="${kcf//@V/$vend}"
    c "External module: $dir"
    # shellcheck disable=SC2086  # extra = several make variables
    if make -C "$SRC" "${MAKEARGS[@]}" -j"$JOBS" M="$path" KERNEL_SRC="$SRC" TOP="$KWORK" \
         "$var=$(root_for "$dir" "$vend" "$path")" KCFLAGS="$BASE_KCFLAGS${kcf:+ $kcf}" $extra \
         KBUILD_EXTRA_SYMBOLS="$syms" modules >>"$KWORK/build-ext.log" 2>&1; then
      ok+=("$dir"); [ -f "$path/Module.symvers" ] && syms="$syms $path/Module.symvers"
    else
      fail+=("$dir"); warn "$dir failed – $KWORK/build-ext.log"
    fi
  done
  printf '%s\n' "${ok[@]}" > "$KWORK/ext-ok"; printf '%s\n' "${fail[@]}" > "$KWORK/ext-fail"
  c "External modules: ${#ok[@]} ok, ${#fail[@]} failed"
}

# ------------------------------------------------------------ install
cmd_install() {
  [ -f "$O/arch/arm64/boot/Image.gz" ] || cmd_build
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  make -s -C "$SRC" "${MAKEARGS[@]}" INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 modules_install
  local dir path
  while read -r dir; do
    [ -n "$dir" ] || continue; path="$SRC/vendor/qcom/opensource/$dir"
    local extra; extra=$(printf '%s\n' "${EXT_MODULES[@]}" | awk -F'|' -v d="$dir" '$1 == d {print $3}')
    extra="${extra//@P/$path}"; extra="${extra//@V/$SRC/vendor/qcom/opensource}"
    local var; var=$(printf '%s\n' "${EXT_MODULES[@]}" | awk -F'|' -v d="$dir" '$1 == d {print $2}')
    local kcf; kcf=$(printf '%s\n' "${EXT_MODULES[@]}" | awk -F'|' -v d="$dir" '$1 == d {print $4}')
    kcf="${kcf//@P/$path}"; kcf="${kcf//@V/$SRC/vendor/qcom/opensource}"
    # shellcheck disable=SC2086
    make -s -C "$SRC" "${MAKEARGS[@]}" M="$path" KERNEL_SRC="$SRC" TOP="$KWORK" \
      "$var=$(root_for "$dir" "$SRC/vendor/qcom/opensource" "$path")" KCFLAGS="$BASE_KCFLAGS${kcf:+ $kcf}" $extra \
      INSTALL_MOD_PATH="$STAGE" INSTALL_MOD_STRIP=1 INSTALL_MOD_DIR=extra modules_install || warn "Installing $dir failed"
  done < "$KWORK/ext-ok"
  KREL=$(cat "$O/include/config/kernel.release")
  rm -f "$STAGE/lib/modules/$KREL/build" "$STAGE/lib/modules/$KREL/source"
  depmod -b "$STAGE" "$KREL"
  echo "$KREL" > "$KWORK/krel"
  c "Modules: $(find "$STAGE/lib/modules/$KREL" -name '*.ko' | wc -l) for $KREL"
}

# module list → paths in the stage (missing ones are reported)
resolve_list() {  # $@ = Listen-Dateien → stdout: Modulnamen (ohne .ko), Reihenfolge erhalten, ohne Doppelte/Blocklist
  local f m seen=" " block
  block=" $(sed -n 's/^blocklist[[:space:]]\+//p' "$HERE/modules/modules.blocklist" | tr '\n' ' ') "
  for f in "$@"; do
    while read -r m; do
      m="${m%.ko}"; [ -n "$m" ] || continue
      case "$seen" in *" $m "*) continue ;; esac
      case "$block" in *" $m "*) continue ;; esac
      seen="$seen$m "; echo "$m"
    done < "$f"
  done
}

# ------------------------------------------------------------ initramfs
fetch_static_tools() {  # busybox-static + e2fsck-static (arm64, apt-signiert)
  local t="$KWORK/static"
  is_elf() { [ -f "$1" ] && [ "$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; }
  # Cache nur akzeptieren, wenn wirklich Binaries drinliegen: ein frueherer
  # Build hat hier eine 16-Byte-Textdatei als "busybox" abgelegt, und ein
  # reiner -x-Test haette sie weiterbenutzt.
  is_elf "$t/busybox" && is_elf "$t/e2fsck" && return 0
  rm -rf "$t/x" "$t/busybox" "$t/e2fsck"
  mkdir -p "$t/x"
  if [ "$(dpkg --print-architecture)" != arm64 ]; then
    dpkg --print-foreign-architectures | grep -qx arm64 || { dpkg --add-architecture arm64; apt-get update -q >/dev/null; }
  fi
  ( cd "$t" && apt-get download -q busybox-static:arm64 e2fsck-static:arm64 >/dev/null )
  for d in "$t"/*.deb; do dpkg-deb -x "$d" "$t/x"; done
  # Nur echte Binaries aus bin/ oder sbin/ nehmen: busybox-static enthaelt
  # zusaetzlich usr/share/initramfs-tools/conf-hooks.d/busybox, eine 16-Byte-
  # Textdatei. Landet die im Initramfs, scheitert /init mit ENOEXEC.
  pick_bin() {  # $1 = Dateiname im Paket, $2 = Ziel
    local f
    for f in $(find "$t/x" -type f \( -path '*/bin/*' -o -path '*/sbin/*' \) -name "$1"); do
      is_elf "$f" || continue
      cp "$f" "$2"; return 0
    done
    return 1
  }
  pick_bin busybox       "$t/busybox" || die "busybox-static (arm64): kein ELF-Binary im Paket"
  pick_bin e2fsck.static "$t/e2fsck"  || die "e2fsck-static (arm64): kein ELF-Binary im Paket"
  chmod 0755 "$t/busybox" "$t/e2fsck"
}

cmd_initramfs() {
  [ -f "$KWORK/krel" ] || cmd_install
  KREL=$(cat "$KWORK/krel")
  fetch_static_tools
  rm -rf "$IRD"; mkdir -p "$IRD"/{bin,sbin,etc,proc,sys,dev,run,tmp,sysroot,lib/modules/"$KREL"}
  install -m 0755 "$KWORK/static/busybox" "$IRD/bin/busybox"
  install -m 0755 "$KWORK/static/e2fsck" "$IRD/sbin/e2fsck"
  local a
  for a in sh ash cat ls mkdir mount umount sed grep head sleep echo ln tr uname \
           modprobe insmod lsmod switch_root ip ifconfig udhcpd telnetd dmesg ps kill reboot poweroff \
           vi less find blkid df free losetup; do
    ln -sf busybox "$IRD/bin/$a"
  done
  install -m 0755 "$HERE/initramfs/init" "$IRD/init"
  # Zweite Kopie unter eigenem Namen, passend zu rdinit=/noxis-init. Das
  # schuetzt davor, dass Androids /init unseres beim Zusammenhaengen der
  # Ramdisks ueberschreibt. Es ersetzt das Flashen von init_boot NICHT: der
  # Bootloader dieses Geraets ignoriert die Ramdisk im boot.img, sobald eine
  # init_boot-Partition da ist (getestet, Ergebnis war "VFS: Unable to mount
  # root fs on unknown-block(0,0)").
  install -m 0755 "$HERE/initramfs/init" "$IRD/noxis-init"
  install -m 0644 "$HERE/initramfs/udhcpd.conf" "$IRD/etc/udhcpd.conf"

  # first-stage modules (vendor_boot + recovery: storage, USB, display, touch)
  # Module samt Abhaengigkeiten uebernehmen. modprobe --show-depends liest die
  # modules.dep des Stage-Baums und gibt die Kette in Ladereihenfolge aus; ohne
  # das fehlen Symbol-Lieferanten wie qti_regmap_debugfs oder thermal_minidump
  # im Initramfs und qcom-spmi-pmic bzw. dwc3-msm laden spaeter nicht.
  local list="$IRD/lib/modules/$KREL/modules.load.noxis" m out p missing=0
  local MODROOT="$STAGE/lib/modules/$KREL" seen="$KWORK/.modseen" block
  block=" $(sed -n 's/^blocklist[[:space:]]\+//p' "$HERE/modules/modules.blocklist" | tr '\n' ' ') "
  : > "$list"; : > "$seen"; : > "$KWORK/initramfs-missing"
  copy_mod() {  # $1 = Pfad aus modprobe --show-depends
    local src="$1" rel base
    rel="${src##*/lib/modules/$KREL/}"; base="${rel##*/}"
    [ -f "$MODROOT/$rel" ] || return 0
    case "$block" in *" ${base%.ko} "*) return 0 ;; esac
    grep -qxF "$base" "$seen" && return 0
    printf '%s\n' "$base" >> "$seen"
    mkdir -p "$IRD/lib/modules/$KREL/$(dirname "$rel")"
    cp "$MODROOT/$rel" "$IRD/lib/modules/$KREL/$rel"
    printf '%s\n' "$base" >> "$list"
  }
  while read -r m; do
    if out=$(modprobe -d "$STAGE" --set-version "$KREL" --show-depends --ignore-install "$m" 2>/dev/null); then
      printf '%s\n' "$out" | awk '$1=="insmod"{print $2}' | while read -r p; do copy_mod "$p"; done
    else
      missing=$((missing + 1)); printf '%s\n' "$m" >> "$KWORK/initramfs-missing"
    fi
  done < <(resolve_list "$HERE/modules/modules.load.vendor_boot" "$HERE/modules/modules.load.recovery")
  rm -f "$seen"
  cp "$STAGE/lib/modules/$KREL"/modules.{order,builtin,builtin.modinfo} "$IRD/lib/modules/$KREL/" 2>/dev/null || true
  depmod -b "$IRD" "$KREL"
  c "Initramfs: $(grep -c . "$list") modules, $missing not built"
  ( cd "$IRD" && find . -print0 | sort -z | cpio --null -o -H newc -R 0:0 --quiet ) > "$KWORK/initramfs.cpio"
  gzip -9nc "$KWORK/initramfs.cpio" > "$KWORK/initramfs.cpio.gz"
  # Zusaetzlich lz4-legacy: der Bootloader haengt die vendor_boot-Ramdisk (lz4)
  # und diese hier aneinander. Der lz4-Dekomprimierer des Kernels liest nach
  # seinem Stream die naechsten vier Bytes und erwartet wieder die lz4-Magic;
  # steht dort ein gzip-Header, bricht das Auspacken mit "Decoding failed" ab.
  if command -v lz4 >/dev/null 2>&1; then
    lz4 -l -9 -f "$KWORK/initramfs.cpio" "$KWORK/initramfs.cpio.lz4" >/dev/null 2>&1 \
      && c "initramfs.cpio.lz4: $(du -h "$KWORK/initramfs.cpio.lz4" | cut -f1)  (fuer init_boot)"
  else
    warn "lz4 fehlt - initramfs.cpio.lz4 wird nicht erzeugt (noetig fuer init_boot)"
  fi
  rm -f "$KWORK/initramfs.cpio"
  c "initramfs.cpio.gz: $(du -h "$KWORK/initramfs.cpio.gz" | cut -f1)"
}

# ------------------------------------------------------------ boot.img
cmd_bootimg() {
  [ -f "$KWORK/initramfs.cpio.gz" ] || cmd_initramfs
  mkdir -p "$KOUT"
  local size="$BOOT_SIZE"
  [ -n "${BOOT_STOCK:-}" ] && [ -f "$BOOT_STOCK" ] && size=$(stat -c %s "$BOOT_STOCK")
  mkbootimg --header_version 4 \
    --kernel "$O/arch/arm64/boot/Image.gz" \
    --ramdisk "$KWORK/initramfs.cpio.gz" \
    --cmdline "$CMDLINE" \
    --os_version 15.0.0 --os_patch_level "$(date +%Y-%m)" \
    --output "$KOUT/boot.img"
  # Die lz4-Ramdisk gehoert zur Ausgabe: sie wird fuer init_boot gebraucht,
  # das dieses Geraet zwingend verlangt.
  [ -f "$KWORK/initramfs.cpio.lz4" ] && cp "$KWORK/initramfs.cpio.lz4" "$KOUT/initramfs.cpio.lz4"
  local got; got=$(stat -c %s "$KOUT/boot.img")
  [ "$got" -le "$size" ] || die "boot.img $got Bytes > Partition $size Bytes"
  c "boot.img: $((got / 1048576)) MiB von $((size / 1048576)) MiB"
}

# ------------------------------------------------------------ Debian packages
mkdeb() {  # $1 Name, $2 Wurzelordner, $3 Beschreibung
  local n="$1" r="$2"
  mkdir -p "$r/DEBIAN"
  cat > "$r/DEBIAN/control" <<EOF
Package: $n
Version: $PKGVER+$(cut -c1-12 "$KWORK/commit")
Architecture: arm64
Maintainer: 3rr0r <noxis@localhost>
Section: kernel
Priority: optional
Description: $3
EOF
  dpkg-deb --root-owner-group -Zxz -b "$r" "$KOUT/device/${n}_${PKGVER}_arm64.deb" >/dev/null
}

cmd_debs() {
  [ -f "$KOUT/boot.img" ] || cmd_bootimg
  KREL=$(cat "$KWORK/krel")
  rm -rf "$DEBS" "$KOUT/device"; mkdir -p "$DEBS" "$KOUT/device"

  local b="$DEBS/bootimage"; mkdir -p "$b/usr/lib/noxis"
  cp "$KOUT/boot.img" "$b/usr/lib/noxis/boot.img"
  mkdeb linux-bootimage-noxis-asteroids "$b" "Noxis boot.img (Nothing GKI $KREL + initramfs) for the Nothing Phone (3a)"

  local k="$DEBS/kernel"; mkdir -p "$k/lib/modules" "$k/etc/modules-load.d" "$k/etc/modprobe.d"
  cp -a "$STAGE/lib/modules/$KREL" "$k/lib/modules/"
  resolve_list "$HERE/modules/modules.load.vendor_dlkm" "$HERE/modules/modules.load.system_dlkm" \
    > "$k/etc/modules-load.d/noxis-asteroids.conf"
  sed -n 's/^blocklist[[:space:]]\+/blacklist /p' "$HERE/modules/modules.blocklist" > "$k/etc/modprobe.d/noxis-asteroids.conf"
  mkdeb noxis-kernel-asteroids "$k" "Noxis kernel modules $KREL for the Nothing Phone (3a)"

  if [ -n "${NOXIS_FIRMWARE:-}" ]; then
    [ -d "$NOXIS_FIRMWARE" ] || die "NOXIS_FIRMWARE=$NOXIS_FIRMWARE not found"
    local f="$DEBS/firmware"; mkdir -p "$f/vendor/firmware"
    cp -a "$NOXIS_FIRMWARE"/. "$f/vendor/firmware/"
    mkdeb noxis-firmware-asteroids "$f" "Firmware from /vendor/firmware (local use only, do not redistribute)"
  fi
  c "Packages: $(ls "$KOUT/device" | tr '\n' ' ')"
}

# ------------------------------------------------------------ report
cmd_report() {
  local r="$KOUT/build-report.txt"
  {
    echo "Noxis Kernel – $(date -u +%Y-%m-%dT%H:%MZ)"
    echo "Source:  $REPO ($BRANCH)"
    echo "Commit:  $(cat "$KWORK/commit")"
    echo "Release: $(cat "$KWORK/krel")"
    echo "Compiler: $(clang --version | head -n1)"
    echo "External modules ok:";     sed 's/^/  /' "$KWORK/ext-ok"
    echo "External modules failed:"; sed 's/^/  /' "$KWORK/ext-fail"
    echo "Initramfs modules not built: $(grep -c . "$KWORK/initramfs-missing" 2>/dev/null || echo 0)"
    [ -s "$KWORK/initramfs-missing" ] && sed 's/^/  /' "$KWORK/initramfs-missing"
  } > "$r"
  ( cd "$KOUT" && sha256sum boot.img device/*.deb > SHA256SUMS )
  c "Done → $KOUT  (report: build-report.txt)"
}

cmd_all() { cmd_check; cmd_source; cmd_config; cmd_build; cmd_install; cmd_initramfs; cmd_bootimg; cmd_debs; cmd_report; }

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0   # sourceable for tests
case "${1:-}" in
  check) cmd_check ;; source) cmd_source ;; config) cmd_config ;; build) cmd_build ;;
  install) cmd_install ;; initramfs) cmd_initramfs ;; bootimg) cmd_bootimg ;; debs) cmd_debs ;;
  report) cmd_report ;; all) cmd_all ;;
  *) sed -n '2,17p' "$0" ;;
esac
