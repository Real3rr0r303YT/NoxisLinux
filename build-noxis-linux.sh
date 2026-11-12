#!/usr/bin/env bash
# ============================================================
#  Noxis Linux – build script (Debian trixie arm64 + Phosh)
#  Target: Nothing Phone (3a) "asteroids" (Snapdragon 7s Gen 3 / SM7635)
#
#  ./build-noxis-linux.sh check       tools, RAM, disk space
#  ./build-noxis-linux.sh opsec       build noxis-opsec.deb + noxis-shell.deb
#  ./build-noxis-linux.sh fetch       Mullvad key, Tor Browser, arkenfox (signature-checked)
#  ./build-noxis-linux.sh rootfs      Debian rootfs (mmdebstrap) + Noxis layer
#  ./build-noxis-linux.sh image       rootfs.img (ext4) + rootfs-sparse.img (fastboot)
#  ./build-noxis-linux.sh boot        boot.img (from BOOT_IMG or the device kernel package)
#  ./build-noxis-linux.sh flash       aufs Handy installieren (vbmeta, userdata, boot, init_boot)
#  ./build-noxis-linux.sh restore     Stock-Bootkette zurueck (Recovery erreichbar, userdata bleibt)
#  ./build-noxis-linux.sh verify      SHA-256 + image check
#  ./build-noxis-linux.sh cleanup     delete the build folder (only after a successful verify)
#  ./build-noxis-linux.sh all         everything in order (asks for language + time zone)
#  ./build-noxis-linux.sh container   everything inside a Debian Docker container (e.g. from Gentoo)
#  ./build-noxis-linux.sh kernel      Nothing kernel + boot.img in a container → <output>/device/*.deb
#                                     ("container" then picks up the device packages automatically)
#
#  Variables: NOXIS_WORK NOXIS_OUT NOXIS_USER NOXIS_PIN NOXIS_LANG NOXIS_TZ NOXIS_DEVICE_DEBS BOOT_IMG NOXIS_PENTEST
#  NOXIS_LANG: de tr en fr bg ru uk, or "ask" = choose on the phone at first boot
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION="1.0.0"
SUITE="${NOXIS_SUITE:-trixie}"
ARCH="arm64"
MIRROR="${NOXIS_MIRROR:-http://deb.debian.org/debian}"
WORK="${NOXIS_WORK:-$HOME/noxis-linux-build}"
NUSER="${NOXIS_USER:-noxis}"
NPIN="${NOXIS_PIN:-147147}"
DEVICE_DEBS="${NOXIS_DEVICE_DEBS:-}"      # folder with device .debs (kernel/adaptation)
NLANG="${NOXIS_LANG:-}"
NTZ="${NOXIS_TZ:-}"
BOOT_IMG="${BOOT_IMG:-}"

MULLVAD_FPR="${NOXIS_MULLVAD_FPR:-A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF}"
TOR_FPR="${NOXIS_TOR_FPR:-EF6E286DDA85EA2A4BA7DE684E2C6E8793298290}"

c()    { printf '\033[38;5;111m[noxis]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

desktop_dir() {
  local d=""
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then   # sudo → the real user's desktop
    local h; h=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    d=$(sudo -u "$SUDO_USER" xdg-user-dir DESKTOP 2>/dev/null || true)
    { [ -n "$d" ] && [ "$d" != "$h" ]; } || d="$h/Desktop"
    echo "$d"; return 0
  fi
  command -v xdg-user-dir >/dev/null 2>&1 && d=$(xdg-user-dir DESKTOP 2>/dev/null || true)
  { [ -n "$d" ] && [ "$d" != "$HOME" ]; } || d="$HOME/Desktop"
  echo "$d"
}
OUT="${NOXIS_OUT:-$(desktop_dir)/noxis-linux}"

DL="$WORK/downloads"; GNUPGHOME="$WORK/gnupg"; export GNUPGHOME
ROOTFS_TAR="$WORK/rootfs.tar"

# rootfs packages ----------------------------------------------------------
PKG_BASE="systemd-sysv,systemd-resolved,systemd-timesyncd,dbus-user-session,sudo,locales,tzdata,ca-certificates,curl,gnupg,apt-transport-https,xz-utils,e2fsprogs,cryptsetup"
PKG_NET="network-manager,modemmanager,wpasupplicant,bluez,nftables,wireguard-tools,usbguard"
PKG_UI="phosh-core,cage,seatd,gir1.2-gtk-4.0,librsvg2-common,wlr-randr,fonts-inter,squeekboard,pipewire,pipewire-pulse,wireplumber,fonts-noto-core,python3,python3-gi"
PKG_APPS="firefox-esr,gnome-calls,chatty"
# pentest tools from Debian (Kali-style); NOXIS_PENTEST=0 leaves them out
PKG_PENTEST="nmap masscan aircrack-ng reaver hcxdumptool hcxtools wifite macchanger tshark wireshark tcpdump bettercap hydra john hashcat sqlmap gobuster ffuf netcat-openbsd socat proxychains4 dnsutils whois binwalk radare2 sslscan dsniff ettercap-text-only podman distrobox"
PENTEST="${NOXIS_PENTEST:-1}"
PKG_OPTIONAL="mobile-config-firefox waydroid kgx phosh-mobile-settings gnome-text-editor plymouth gnome-network-displays rmtfs pd-mapper tqftpserv qrtr-tools bluez-tools"

# ------------------------------------------------------------ language + time zone
LANG_CODES=(de tr en fr bg ru uk)
LANG_NAMES=("Deutsch" "Türkçe" "English" "Français" "Български" "Русский" "Українська")
LANG_TZ=(Europe/Berlin Europe/Istanbul "" Europe/Paris Europe/Sofia Europe/Moscow Europe/Kyiv)

host_tz() {  # time zone of the build machine (systemd, OpenRC/Gentoo, plain symlink)
  local tz=""
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  [ -n "$tz" ] || tz=$(cat /etc/timezone 2>/dev/null || true)
  [ -n "$tz" ] || tz=$(readlink /etc/localtime 2>/dev/null | sed -n 's|.*zoneinfo/||p')
  echo "$tz"
}

valid_tz() {  # Area/City present in tzdata
  [ "$1" = UTC ] && return 0
  [[ "$1" =~ ^[A-Z][A-Za-z_+-]*(/[A-Za-z0-9_+-]+){1,2}$ ]] || return 1
  grep -q "[[:space:]]$1\([[:space:]]\|$\)" /usr/share/zoneinfo/zone.tab 2>/dev/null || [ -f "/usr/share/zoneinfo/$1" ]
}

ask_locale() {
  if [ -n "$NLANG" ]; then
    [ "$NLANG" = ask ] && return 0
    [[ " ${LANG_CODES[*]} " == *" $NLANG "* ]] || die "NOXIS_LANG=$NLANG – use: ${LANG_CODES[*]} or ask"
    [ -n "$NTZ" ] || NTZ=$(host_tz)
    valid_tz "$NTZ" || die "NOXIS_TZ=$NTZ is not a valid time zone (e.g. Europe/Berlin)"
    export NOXIS_LANG="$NLANG" NOXIS_TZ="$NTZ"; return 0
  fi
  if [ ! -t 0 ]; then NLANG=ask; return 0; fi
  echo
  echo "  Language / Sprache / Dil / Langue / Език / Язык / Мова"
  local i
  for i in "${!LANG_CODES[@]}"; do printf '    %d) %s\n' $((i + 1)) "${LANG_NAMES[$i]}"; done
  echo "    0) ask on the phone at first boot"
  local pick
  while :; do
    read -r -p "  > " pick
    [[ "$pick" =~ ^[0-7]$ ]] && break
  done
  if [ "$pick" = 0 ]; then NLANG=ask; export NOXIS_LANG=ask; c "Language + time zone: chosen on the phone"; return 0; fi
  NLANG=${LANG_CODES[$((pick - 1))]}
  local def; def=$(host_tz)
  valid_tz "$def" || def=${LANG_TZ[$((pick - 1))]}
  valid_tz "$def" || def=UTC
  while :; do
    read -r -p "  Time zone [$def]: " NTZ
    NTZ=${NTZ:-$def}
    valid_tz "$NTZ" && break
    echo "  unknown time zone – examples: Europe/Berlin Europe/Istanbul America/New_York"
  done
  export NOXIS_LANG="$NLANG" NOXIS_TZ="$NTZ"
  c "Language: ${LANG_NAMES[$((pick - 1))]} · time zone: $NTZ"
}

# ------------------------------------------------------------ check
cmd_check() {
  local ram disk miss=0
  ram=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  mkdir -p "$WORK"
  disk=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc 0-9)
  c "RAM ${ram} GB (recommended ≥ 8) · free at $WORK: ${disk} GB (needed ≥ 25)"
  for t in mmdebstrap mkfs.ext4 debugfs e2fsck gpg gpgv curl git dpkg-deb sha256sum xz; do
    if command -v "$t" >/dev/null 2>&1; then echo "  ✓ $t"; else echo "  ✗ $t"; miss=1; fi
  done
  command -v img2simg >/dev/null 2>&1 && echo "  ✓ img2simg" || echo "  – img2simg (optional, for fastboot sparse)"
  if [ "$(uname -m)" != aarch64 ]; then
    # binfmt_misc is a host-wide setting; inside a container the directory may
    # not be mounted even though the registration is active. Test for real by
    # running an arm64 binary (arch-test / qemu) instead of only looking at
    # /proc/sys/fs/binfmt_misc.
    if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
      echo "  ✓ qemu-aarch64 binfmt"
    elif command -v arch-test >/dev/null 2>&1 && arch-test arm64 >/dev/null 2>&1; then
      echo "  ✓ qemu-aarch64 binfmt (via arch-test)"
    elif [ -f /.dockerenv ] && command -v qemu-aarch64-static >/dev/null 2>&1; then
      echo "  ✓ qemu-aarch64 binfmt (qemu-user-static present in container)"
    else
      echo "  ✗ qemu-aarch64 binfmt (for the arm64 chroot on x86)"; miss=1
    fi
  fi
  [ "$miss" = 0 ] && { c "All set."; return 0; }
  cat <<'EOF'

Missing tools:
  Debian/Ubuntu:  sudo apt install mmdebstrap qemu-user-static binfmt-support e2fsprogs gnupg curl git \
                  dpkg xz-utils android-sdk-libsparse-utils
  Gentoo/others:  easier with Docker:  ./build-noxis-linux.sh container
                  (binfmt once:  docker run --privileged --rm tonistiigi/binfmt --install arm64)
EOF
  return 1
}

# ------------------------------------------------------------ packages
cmd_opsec() {
  mkdir -p "$DL"
  local pkg="$HERE/noxis-opsec"
  sed -i "s/^Version: .*/Version: $VERSION/" "$pkg/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$pkg" "$DL/noxis-opsec_${VERSION}_all.deb" >/dev/null
  c "built noxis-opsec_${VERSION}_all.deb"
  pkg="$HERE/noxis-shell"
  sed -i "s/^Version: .*/Version: $VERSION/" "$pkg/DEBIAN/control"
  find "$pkg" -name __pycache__ -prune -exec rm -r {} +
  dpkg-deb --root-owner-group --build "$pkg" "$DL/noxis-shell_${VERSION}_all.deb" >/dev/null
  c "built noxis-shell_${VERSION}_all.deb"
  pkg="$HERE/noxis-hw"
  sed -i "s/^Version: .*/Version: $VERSION/" "$pkg/DEBIAN/control"
  find "$pkg" -name __pycache__ -prune -exec rm -r {} +
  dpkg-deb --root-owner-group --build "$pkg" "$DL/noxis-hw-asteroids_${VERSION}_all.deb" >/dev/null
  c "built noxis-hw-asteroids_${VERSION}_all.deb"
}

# ------------------------------------------------------------ downloads (signature-checked)
fpr_of() { gpg --batch --with-colons --show-keys "$1" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}'; }

fetch_mullvad_key() {
  local k="$DL/mullvad-keyring.asc" got
  curl -fsSL -o "$k" https://repository.mullvad.net/deb/mullvad-keyring.asc
  got=$(gpg --batch --with-colons --show-keys "$k" | awk -F: '/^fpr:/ {print $10}')
  if ! grep -qx "$MULLVAD_FPR" <<<"$got"; then
    die "Unexpected Mullvad repository key: $(echo $got). Check https://mullvad.net/help/verifying-signatures and set NOXIS_MULLVAD_FPR=<fingerprint> if it changed."
  fi
  c "Mullvad key ok ($MULLVAD_FPR)"
}

fetch_tor() {
  local ver base f vers found=
  # Newest first. Some releases are Android-only hotfixes with no desktop
  # build at all, so walk back until a version really carries the aarch64
  # tarball instead of trusting the highest version number.
  vers=$(curl -fsSL https://dist.torproject.org/torbrowser/ | grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' \
        | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V -r)
  [ -n "$vers" ] || die "Cannot determine the Tor Browser version"
  for ver in $vers; do
    base="https://dist.torproject.org/torbrowser/$ver"
    f="tor-browser-linux-aarch64-$ver.tar.xz"
    if curl -fsIL -o /dev/null "$base/$f" 2>/dev/null; then found=$ver; break; fi
    c "Tor Browser $ver has no Linux aarch64 build – trying the one before it"
  done
  [ -n "$found" ] || die "No Tor Browser release with a Linux aarch64 build found"
  ver=$found
  base="https://dist.torproject.org/torbrowser/$ver"
  f="tor-browser-linux-aarch64-$ver.tar.xz"
  c "Tor Browser $ver (Linux aarch64)"
  curl -fsSL -o "$DL/$f" "$base/$f"
  curl -fsSL -o "$DL/$f.asc" "$base/$f.asc"
  mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  curl -fsSL -o "$DL/tor.asc" "https://keys.openpgp.org/vks/v1/by-fingerprint/$TOR_FPR"
  [ "$(fpr_of "$DL/tor.asc")" = "$TOR_FPR" ] || die "Tor signing key has the wrong fingerprint"
  gpg --batch --quiet --import "$DL/tor.asc"
  gpg --batch --export "$TOR_FPR" > "$DL/tor.keyring"
  gpgv --keyring "$DL/tor.keyring" "$DL/$f.asc" "$DL/$f" 2>&1 | grep -q "Good signature" \
    || die "Tor Browser signature INVALID – aborting"
  ln -sf "$f" "$DL/tor-browser.tar.xz"
  c "Tor Browser signature valid"
}

fetch_arkenfox() {
  local d="$DL/arkenfox"
  [ -d "$d/.git" ] || git clone -q --depth=1 https://github.com/arkenfox/user.js "$d"
  sed -E 's/^([[:space:]]*)user_pref\(/\1pref(/' "$d/user.js" > "$DL/noxis-arkenfox.js"
  [ "$(grep -c '^[[:space:]]*user_pref(' "$DL/noxis-arkenfox.js")" = 0 ] || die "arkenfox conversion incomplete"
  c "arkenfox: $(grep -c '^[[:space:]]*pref(' "$DL/noxis-arkenfox.js") prefs ($(git -C "$d" log -1 --format=%cs))"
}

cmd_fetch() {
  mkdir -p "$DL" "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  fetch_mullvad_key
  fetch_tor
  fetch_arkenfox
}

# ------------------------------------------------------------ rootfs
write_customize() {  # script that runs inside the arm64 chroot
  cat > "$WORK/customize.sh" <<EOF
#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
echo noxis > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 noxis\n' > /etc/hosts
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
# all seven Noxis languages: de tr en fr bg ru uk
for l in de_DE tr_TR en_US fr_FR bg_BG ru_RU uk_UA; do sed -i "s/^# *\$l.UTF-8 UTF-8/\$l.UTF-8 UTF-8/" /etc/locale.gen; done
locale-gen >/dev/null
echo 'LANG=en_US.UTF-8' > /etc/default/locale

# Mullvad repository
install -m644 /tmp/noxis/mullvad-keyring.asc /usr/share/keyrings/mullvad-keyring.asc
echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=arm64] https://repository.mullvad.net/deb/stable stable main" > /etc/apt/sources.list.d/mullvad.list
apt-get update -q
apt-get install -y -q mullvad-vpn

# Noxis OPSEC layer
apt-get install -y -q /tmp/noxis/noxis-opsec.deb

# optional packages (build continues if missing from the archive)
for p in $PKG_OPTIONAL; do apt-get install -y -q "\$p" || echo "optional missing: \$p"; done

# Kali-style pentest tools (Debian packages) + Kali container helper (noxis-kali)
if [ "$PENTEST" = 1 ]; then
  echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
  for p in $PKG_PENTEST; do apt-get install -y -q --no-install-recommends "\$p" || echo "pentest missing: \$p"; done
fi

# hardware bring-up for the Nothing Phone (3a): firmware links, modem/WLAN/DSP start, Bluetooth
apt-get install -y -q /tmp/noxis/noxis-hw-asteroids_${VERSION}_all.deb
# device packages (kernel/adaptation), if given
if ls /tmp/noxis/device/*.deb >/dev/null 2>&1; then apt-get install -y -q /tmp/noxis/device/*.deb; fi
# root grows to the full userdata partition on first boot
grep -q 'LABEL=noxis-root' /etc/fstab 2>/dev/null || \
  echo 'LABEL=noxis-root / ext4 defaults,noatime,x-systemd.growfs 0 1' >> /etc/fstab

# Tor Browser in /opt
mkdir -p /opt
tar -xJf /tmp/noxis/tor-browser.tar.xz -C /opt
mv /opt/tor-browser* /opt/tor-browser 2>/dev/null || true
cat > /usr/share/applications/noxis-tor-browser.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=Tor Browser
Exec=sh -c '"/opt/tor-browser/Browser/start-tor-browser" --detach'
Icon=/opt/tor-browser/Browser/browser/chrome/icons/default/default128.png
Categories=Network;WebBrowser;Security;
X-Purism-FormFactor=Workstation;Mobile;
DESK

# Firefox ESR: arkenfox as system default
for d in /usr/lib/firefox-esr/defaults/pref /usr/lib/firefox/defaults/pref; do
  [ -d "\$(dirname "\$d")" ] && mkdir -p "\$d" && install -m644 /tmp/noxis/noxis-arkenfox.js "\$d/noxis-arkenfox.js"
done

# user account
id $NUSER >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,audio,video,render,input,netdev,plugdev,bluetooth,dialout $NUSER 2>/dev/null \
  || useradd -m -s /bin/bash -G sudo,audio,video,input $NUSER
echo "$NUSER:$NPIN" | chpasswd
# capture without root in Wireshark (only if the pentest tools are installed)
getent group wireshark >/dev/null && usermod -aG wireshark $NUSER || true
# login: own display manager noxis-dm + greeter → PIN after every boot, no autologin
apt-get install -y -q /tmp/noxis/noxis-shell.deb
sed -i "s/^user *=.*/user = $NUSER/" /etc/noxis/greeter.conf
# language + time zone: chosen at build time, or asked on the phone at first boot
if [ -n "$NLANG" ] && [ "$NLANG" != ask ]; then python3 /usr/lib/noxis/dm/setup.py apply "$NLANG" "$NTZ"; fi
systemctl enable noxis-dm.service
systemctl disable phosh.service greetd.service 2>/dev/null || true
systemctl set-default graphical.target

# no SSH, no remote access
apt-get purge -y -q openssh-server 2>/dev/null || true
systemctl mask --quiet ssh.service 2>/dev/null || true

# clean up the image
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/noxis /var/log/*.log
: > /etc/machine-id
EOF
  chmod 755 "$WORK/customize.sh"
}

cmd_rootfs() {
  command -v mmdebstrap >/dev/null || die "mmdebstrap missing – ./build-noxis-linux.sh check"
  [ -f "$DL/noxis-opsec_${VERSION}_all.deb" ] && [ -f "$DL/noxis-shell_${VERSION}_all.deb" ] && [ -f "$DL/noxis-hw-asteroids_${VERSION}_all.deb" ] || cmd_opsec
  [ -f "$DL/tor-browser.tar.xz" ] && [ -f "$DL/noxis-arkenfox.js" ] && [ -f "$DL/mullvad-keyring.asc" ] || cmd_fetch
  write_customize
  local devdir="$WORK/device"; mkdir -p "$devdir"
  if [ -n "$DEVICE_DEBS" ]; then cp "$DEVICE_DEBS"/*.deb "$devdir/"; fi
  c "Building Debian $SUITE ($ARCH) + Phosh + Noxis ($( [ -n "$NLANG" ] && [ "$NLANG" != ask ] && echo "$NLANG, $NTZ" || echo "language on first boot")) …"
  mmdebstrap --mode=auto --arch="$ARCH" --variant=important \
    --components="main contrib non-free-firmware" \
    --include="$PKG_BASE,$PKG_NET,$PKG_UI,$PKG_APPS" \
    --customize-hook='mkdir -p "$1/tmp/noxis/device"' \
    --customize-hook="copy-in $DL/noxis-opsec_${VERSION}_all.deb /tmp/noxis/" \
    --customize-hook="chroot \"\$1\" mv /tmp/noxis/noxis-opsec_${VERSION}_all.deb /tmp/noxis/noxis-opsec.deb" \
    --customize-hook="copy-in $DL/noxis-shell_${VERSION}_all.deb /tmp/noxis/" \
    --customize-hook="chroot \"\$1\" mv /tmp/noxis/noxis-shell_${VERSION}_all.deb /tmp/noxis/noxis-shell.deb" \
    --customize-hook="copy-in $DL/noxis-hw-asteroids_${VERSION}_all.deb /tmp/noxis/" \
    --customize-hook="copy-in $DL/mullvad-keyring.asc $DL/noxis-arkenfox.js $(readlink -f "$DL/tor-browser.tar.xz") /tmp/noxis/" \
    --customize-hook="chroot \"\$1\" sh -c 'cd /tmp/noxis && ln -sf tor-browser-linux-aarch64-*.tar.xz tor-browser.tar.xz'" \
    --customize-hook="sync-in $devdir /tmp/noxis/device" \
    --customize-hook="copy-in $WORK/customize.sh /tmp/noxis/" \
    --customize-hook='chroot "$1" /tmp/noxis/customize.sh' \
    "$SUITE" "$ROOTFS_TAR" "$MIRROR"
  c "Rootfs: $(du -h "$ROOTFS_TAR" | cut -f1)"
}

# ------------------------------------------------------------ image
cmd_image() {
  [ -f "$ROOTFS_TAR" ] || die "Run ./build-noxis-linux.sh rootfs first"
  mkdir -p "$OUT"
  local img="$OUT/rootfs.img" mb
  mb=$(( $(stat -c %s "$ROOTFS_TAR") / 1048576 * 13 / 10 + 1024 ))
  rm -f "$img"; truncate -s "${mb}M" "$img"
  c "rootfs.img (${mb} MB, ext4)"
  if ! mkfs.ext4 -q -F -L noxis-root -d "$ROOTFS_TAR" "$img" 2>/dev/null; then
    # e2fsprogs < 1.47.1 cannot read tar → unpack (needs root for ownership)
    [ "$(id -u)" = 0 ] || die "mkfs.ext4 cannot read tar and not root – use ./build-noxis-linux.sh container"
    local tdir="$WORK/rootfs-dir"; rm -rf "$tdir"; mkdir -p "$tdir"
    tar -xpf "$ROOTFS_TAR" -C "$tdir" --numeric-owner
    mkfs.ext4 -q -F -L noxis-root -d "$tdir" "$img"
    rm -rf "$tdir"
  fi
  e2fsck -fy "$img" >/dev/null 2>&1 || true
  if command -v img2simg >/dev/null 2>&1; then
    img2simg "$img" "$OUT/rootfs-sparse.img" && c "rootfs-sparse.img for fastboot"
  fi
}

# ------------------------------------------------------------ boot
cmd_boot() {
  mkdir -p "$OUT"
  if [ -n "$BOOT_IMG" ]; then
    [ -f "$BOOT_IMG" ] || die "BOOT_IMG=$BOOT_IMG not found"
    cp -f "$BOOT_IMG" "$OUT/boot.img"; c "boot.img copied"; return 0
  fi
  if [ -n "$DEVICE_DEBS" ]; then
    local t; t=$(mktemp -d)
    for d in "$DEVICE_DEBS"/linux-bootimage-*.deb; do [ -f "$d" ] && dpkg-deb -x "$d" "$t"; done
    local b; b=$(find "$t" -name 'boot.img' | head -1)
    if [ -n "$b" ]; then cp -f "$b" "$OUT/boot.img"; c "boot.img from the device kernel package"
      local vb; vb=$(find "$t" -name 'vendor_boot.img' | head -1); [ -n "$vb" ] && cp -f "$vb" "$OUT/vendor_boot.img"
      local dt; dt=$(find "$t" -name 'dtbo.img' | head -1); [ -n "$dt" ] && cp -f "$dt" "$OUT/dtbo.img"
      local vm; vm=$(find "$t" -name 'vbmeta.img' | head -1); [ -n "$vm" ] && cp -f "$vm" "$OUT/vbmeta.img"
    fi
    rm -r "$t"
    [ -f "$OUT/boot.img" ] && return 0
  fi
  warn "No kernel for the Nothing Phone (3a) given – skipping boot.img."
  warn "Build one with ./build-noxis-linux.sh kernel, or pass NOXIS_DEVICE_DEBS=<folder> / BOOT_IMG=<file>."
  : > "$OUT/.no-boot"
}

# ------------------------------------------------------------ verify
# ------------------------------------------------------------ flash
# Auf diesem Geraet gibt es zwei Fallen, die wir teuer gelernt haben:
#
#  1. Die Ramdisk MUSS nach init_boot. Der Bootloader ignoriert die Ramdisk im
#     boot.img, sobald eine init_boot-Partition existiert -- mit rdinit auf eine
#     Datei in der boot-Ramdisk endet es in "VFS: Unable to mount root fs on
#     unknown-block(0,0)".
#
#  2. Nur das HAUPT-vbmeta darf entschaerft werden. Werden vbmeta_system und
#     vbmeta_vendor mit --disable-verity --disable-verification geflasht,
#     startet das Geraet ueberhaupt nicht mehr und faellt sofort in fastboot
#     zurueck, auch mit Stock-Kernel und Stock-Recovery.
#
# Deshalb dieser Befehl: eine Reihenfolge, die nachweislich bootet.
cmd_flash() {
  command -v fastboot >/dev/null || die "fastboot fehlt"
  command -v adb      >/dev/null || die "adb fehlt"
  local out; out="$(desktop_dir)/noxis-linux"
  local rootfs="$out/rootfs-sparse.img" boot="$out/boot.img"
  local rd="$out/initramfs.cpio.lz4" tpl="$out/stock"
  [ -f "$rootfs" ] || die "$rootfs fehlt – erst: $0 container"
  [ -f "$boot" ]   || die "$boot fehlt – erst: $0 kernel"
  [ -f "$rd" ]     || die "$rd fehlt – erst: $0 kernel (neu bauen, liefert die lz4-Ramdisk mit)"
  command -v python3 >/dev/null || die "python3 fehlt"
  mkdir -p "$tpl"

  # Rohlinge vom Geraet: init_boot als Vorlage fuer unsere Ramdisk, vbmeta zum
  # Entschaerfen und zum Zurücksetzen. Einmal abziehen reicht.
  if [ ! -f "$tpl/init_boot.img" ] || [ ! -f "$tpl/vbmeta.img" ]; then
    c "Rohlinge vom Geraet holen (Recovery mit adb nötig)"
    adb wait-for-any >/dev/null 2>&1 || true
    adb shell 'SL=$(getprop ro.boot.slot_suffix);
      dd if=/dev/block/by-name/init_boot$SL of=/sdcard/__init_boot.img 2>/dev/null;
      dd if=/dev/block/by-name/vbmeta$SL    of=/sdcard/__vbmeta.img    2>/dev/null' \
      || die "Abziehen fehlgeschlagen – Geraet in die Recovery bringen"
    adb pull /sdcard/__init_boot.img "$tpl/init_boot.img" >/dev/null || die "init_boot nicht geholt"
    adb pull /sdcard/__vbmeta.img    "$tpl/vbmeta.img"    >/dev/null || die "vbmeta nicht geholt"
    adb shell 'rm -f /sdcard/__init_boot.img /sdcard/__vbmeta.img' >/dev/null 2>&1
    c "Rohlinge in $tpl"
  fi

  c "init_boot mit der Noxis-Ramdisk bauen"
  python3 "$HERE/kernel/tools/mkinitboot.py" "$tpl/init_boot.img" "$rd" "$out/init_boot.img" \
    || die "init_boot konnte nicht gebaut werden"
  local isz psz
  isz=$(stat -c %s "$out/init_boot.img")
  psz=$(stat -c %s "$tpl/init_boot.img")
  [ "$isz" -le "$psz" ] || die "init_boot.img $isz Bytes > Partition $psz Bytes – Module aus dem Initramfs nehmen"
  c "init_boot.img: $((isz / 1024)) KB von $((psz / 1024)) KB"

  if adb devices 2>/dev/null | grep -qE 'recovery|device$'; then
    c "Geraet in den Bootloader schicken"
    adb reboot bootloader >/dev/null 2>&1; sleep 3
  fi
  local i=0
  until fastboot devices 2>/dev/null | grep -q fastboot; do
    sleep 1; i=$((i + 1))
    [ "$i" -ge 180 ] && die "kein Geraet im Bootloader"
    [ "$i" = 1 ] && c "Handy in den Bootloader bringen: Power lang, dann Power + Leiser"
  done

  c "vbmeta entschaerfen (nur das Haupt-vbmeta)"
  fastboot --disable-verity --disable-verification flash vbmeta "$tpl/vbmeta.img" || die "flash vbmeta"
  c "Rootfs schreiben (dauert ein paar Minuten)"
  fastboot flash userdata "$rootfs" || die "flash userdata"
  c "Kernel schreiben"
  fastboot flash boot "$boot" || die "flash boot"
  c "Initramfs schreiben"
  fastboot flash init_boot "$out/init_boot.img" || die "flash init_boot"
  fastboot set_active a >/dev/null 2>&1
  c "starten"
  fastboot reboot >/dev/null 2>&1
  c "Fertig. Erster Start dauert ein bis drei Minuten (resize2fs + systemd)."
  c "Anmeldung: Benutzer $NUSER, PIN $NPIN"
}

# ------------------------------------------------------------ restore
# Stock-Bootkette zurueck, damit die Recovery wieder erreichbar ist. userdata
# bleibt unangetastet.
cmd_restore() {
  command -v fastboot >/dev/null || die "fastboot fehlt"
  local out tpl
  out="$(desktop_dir)/noxis-linux"
  tpl="$out/stock"
  [ -f "$tpl/vbmeta.img" ] && [ -f "$tpl/init_boot.img" ] || die "keine Rohlinge in $tpl – erst: $0 flash"
  [ -f "$tpl/boot.img" ] || die "$tpl/boot.img fehlt – Stock-boot aus einem Backup dorthin legen"
  local i=0
  until fastboot devices 2>/dev/null | grep -q fastboot; do
    sleep 1; i=$((i + 1))
    [ "$i" -ge 180 ] && die "kein Geraet im Bootloader"
    [ "$i" = 1 ] && c "Handy in den Bootloader bringen: Power lang, dann Power + Leiser"
  done
  fastboot flash vbmeta    "$tpl/vbmeta.img"    || die "flash vbmeta"
  fastboot flash boot      "$tpl/boot.img"      || die "flash boot"
  fastboot flash init_boot "$tpl/init_boot.img" || die "flash init_boot"
  fastboot set_active a >/dev/null 2>&1
  c "Stock wiederhergestellt – Recovery mit: fastboot reboot recovery"
}

cmd_verify() {
  local img="$OUT/rootfs.img"
  [ -f "$img" ] || die "rootfs.img missing"
  c "Checking file system"
  e2fsck -fn "$img" >/dev/null 2>&1 || die "rootfs.img: file system errors"
  local f missing=0
  for f in /usr/lib/noxis/usblock.py /etc/noxis/firewall.nft /usr/lib/systemd/system/noxis-firewall.service \
           /etc/systemd/resolved.conf.d/90-noxis.conf /opt/tor-browser /usr/share/keyrings/mullvad-keyring.asc \
           /etc/hostname; do
    if debugfs -R "stat $f" "$img" 2>/dev/null | grep -q "Inode:"; then echo "  ✓ $f"; else echo "  ✗ $f"; missing=1; fi
  done
  [ "$missing" = 0 ] || die "Required files missing from the image"
  ( cd "$OUT" && sha256sum $(ls rootfs.img rootfs-sparse.img boot.img vendor_boot.img dtbo.img vbmeta.img 2>/dev/null) > SHA256SUMS )
  ( cd "$OUT" && sha256sum -c --quiet SHA256SUMS ) || die "SHA-256 check failed"
  c "SHA-256 ok:"; sed 's,^,  ,' "$OUT/SHA256SUMS"
  : > "$OUT/.verified"
}

# ------------------------------------------------------------ cleanup
cmd_cleanup() {
  [ -f "$OUT/.verified" ] || die "Not verified – build folder will NOT be deleted"
  ( cd "$OUT" && sha256sum -c --quiet SHA256SUMS ) || die "Output damaged – build folder is kept"
  case "$WORK" in ""|/|"$HOME"|"$HOME/") die "Unsafe WORK path: '$WORK'";; esac
  [ -d "$WORK" ] || { c "Build folder already gone"; return 0; }
  [ -f "$WORK/customize.sh" ] || [ -d "$WORK/downloads" ] || die "$WORK does not look like a Noxis build folder"
  c "Deleting $WORK ($(du -sh "$WORK" 2>/dev/null | cut -f1))"
  rm -rf -- "$WORK"
  c "Done. Output: $OUT"; ls -lh "$OUT" | tail -n +2 | sed 's,^,  ,'
}

# ------------------------------------------------------------ container
cmd_container() {
  command -v docker >/dev/null || die "docker missing"
  ask_locale
  [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || \
    docker run --privileged --rm tonistiigi/binfmt --install arm64
  local out; out="$(desktop_dir)"; mkdir -p "$out"
  local devargs=()
  if ls "$out/noxis-linux/device/"*.deb >/dev/null 2>&1; then
    c "Device packages found: $out/noxis-linux/device"
    devargs=(-v "$out/noxis-linux/device:/device:ro" -e NOXIS_DEVICE_DEBS=/device)
  fi
  docker run --rm --privileged \
    -v "$HERE:/noxis:ro" -v "$out:/out" -v "noxis-build:/work" "${devargs[@]}" \
    -e NOXIS_WORK=/work/build -e NOXIS_OUT=/out/noxis-linux -e NOXIS_USER -e NOXIS_PIN \
    -e NOXIS_LANG="$NLANG" -e NOXIS_TZ="$NTZ" -e NOXIS_PENTEST \
    debian:trixie bash -c '
      set -e
      apt-get update -q && apt-get install -y -q mmdebstrap qemu-user-static e2fsprogs gnupg curl git \
        dpkg xz-utils android-sdk-libsparse-utils ca-certificates arch-test >/dev/null
      cp -r /noxis /tmp/noxis-src && cd /tmp/noxis-src && ./build-noxis-linux.sh all'
}

# ------------------------------------------------------------ kernel (Docker)
cmd_kernel() {
  command -v docker >/dev/null || die "docker missing"
  local out; out="$(desktop_dir)/noxis-linux"; mkdir -p "$out"
  local fw=()
  if [ -n "${NOXIS_FIRMWARE:-}" ]; then
    [ -d "$NOXIS_FIRMWARE" ] || die "NOXIS_FIRMWARE=$NOXIS_FIRMWARE not found"
    fw=(-v "$(readlink -f "$NOXIS_FIRMWARE"):/firmware:ro" -e NOXIS_FIRMWARE=/firmware)
  fi
  c "Building the kernel in a Debian container (sources + objects stay in the noxis-kernel volume)"
  docker run --rm \
    -v "$HERE:/noxis:ro" -v "$out:/out" -v "noxis-kernel:/kwork" "${fw[@]}" \
    -e NOXIS_KWORK=/kwork -e NOXIS_KOUT=/out -e NOXIS_JOBS -e NOXIS_KERNEL_BRANCH -e NOXIS_CMDLINE -e NOXIS_BOOT_SIZE \
    debian:trixie bash -c '
      set -e
      apt-get update -q && apt-get install -y -q --no-install-recommends clang lld llvm make bc bison flex perl \
        python3 git cpio kmod mkbootimg libelf-dev libssl-dev dpkg-dev ca-certificates openssl lz4 >/dev/null
      /noxis/kernel/build-noxis-kernel.sh all'
  c "Done: $out/boot.img + $out/device/*.deb"
}

cmd_all() { ask_locale; cmd_check; cmd_opsec; cmd_fetch; cmd_rootfs; cmd_image; cmd_boot; cmd_verify; cmd_cleanup; }

case "${1:-}" in
  check) cmd_check ;; opsec) cmd_opsec ;; fetch) cmd_fetch ;; rootfs) cmd_rootfs ;;
  image) cmd_image ;; boot) cmd_boot ;; verify) cmd_verify ;; cleanup) cmd_cleanup ;;
  all) cmd_all ;; container) cmd_container ;; kernel) cmd_kernel ;;
  flash) cmd_flash ;; restore) cmd_restore ;;
  *) sed -n '2,21p' "$0" ;;
esac
