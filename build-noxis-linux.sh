#!/usr/bin/env bash
# ============================================================
#  Noxis Linux – Build-Skript (Debian trixie arm64 + Phosh)
#  Ziel: Nothing Phone (3a) "asteroids" (Snapdragon 7s Gen 3 / SM7635)
#
#  ./build-noxis-linux.sh check       Werkzeuge, RAM, Platz
#  ./build-noxis-linux.sh opsec       noxis-opsec.deb + noxis-shell.deb bauen
#  ./build-noxis-linux.sh fetch       Mullvad-Schlüssel, Tor Browser, arkenfox (signaturgeprüft)
#  ./build-noxis-linux.sh rootfs      Debian-Rootfs (mmdebstrap) + Noxis-Schicht
#  ./build-noxis-linux.sh image       rootfs.img (ext4) + rootfs-sparse.img (fastboot)
#  ./build-noxis-linux.sh boot        boot.img (aus BOOT_IMG oder Geräte-Kernelpaket)
#  ./build-noxis-linux.sh verify      SHA-256 + Image-Prüfung
#  ./build-noxis-linux.sh cleanup     Build-Ordner löschen (nur nach erfolgreichem verify)
#  ./build-noxis-linux.sh all         alles nacheinander
#  ./build-noxis-linux.sh container   alles in einem Debian-Docker-Container (z. B. von Gentoo aus)
#  ./build-noxis-linux.sh kernel      Nothing-Kernel + boot.img im Container → <Ausgabe>/device/*.deb
#                                     (danach "container" nimmt die Geräte-Pakete automatisch mit)
#
#  Variablen: NOXIS_WORK  NOXIS_OUT  NOXIS_USER  NOXIS_PIN  NOXIS_DEVICE_DEBS  BOOT_IMG
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
DEVICE_DEBS="${NOXIS_DEVICE_DEBS:-}"      # Ordner mit Geräte-.debs (Kernel/Adaptation)
BOOT_IMG="${BOOT_IMG:-}"

MULLVAD_FPR="${NOXIS_MULLVAD_FPR:-A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF}"
TOR_FPR="${NOXIS_TOR_FPR:-EF6E286DDA85EA2A4BA7DE684E2C6E8793298290}"

c()    { printf '\033[38;5;111m[noxis]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[fehler]\033[0m %s\n' "$*" >&2; exit 1; }

desktop_dir() {
  local d=""
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then   # sudo → Desktop des echten Nutzers
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

# Pakete im Rootfs ---------------------------------------------------------
PKG_BASE="systemd-sysv,systemd-resolved,systemd-timesyncd,dbus-user-session,sudo,locales,tzdata,ca-certificates,curl,gnupg,apt-transport-https,xz-utils,e2fsprogs,cryptsetup"
PKG_NET="network-manager,modemmanager,wpasupplicant,bluez,nftables,wireguard-tools,usbguard"
PKG_UI="phosh-core,cage,gir1.2-gtk-4.0,librsvg2-common,wlr-randr,fonts-inter,squeekboard,pipewire,pipewire-pulse,wireplumber,fonts-noto-core,python3,python3-gi"
PKG_APPS="firefox-esr,gnome-calls,chatty"
PKG_OPTIONAL="mobile-config-firefox waydroid phosh-mobile-settings gnome-text-editor plymouth gnome-network-displays"

# ------------------------------------------------------------ check
cmd_check() {
  local ram disk miss=0
  ram=$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
  mkdir -p "$WORK"
  disk=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc 0-9)
  c "RAM ${ram} GB (empfohlen ≥ 8) · frei bei $WORK: ${disk} GB (nötig ≥ 25)"
  for t in mmdebstrap mkfs.ext4 debugfs e2fsck gpg gpgv curl git dpkg-deb sha256sum xz; do
    if command -v "$t" >/dev/null 2>&1; then echo "  ✓ $t"; else echo "  ✗ $t"; miss=1; fi
  done
  command -v img2simg >/dev/null 2>&1 && echo "  ✓ img2simg" || echo "  – img2simg (optional, für fastboot-sparse)"
  if [ "$(uname -m)" != aarch64 ]; then
    if [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then echo "  ✓ qemu-aarch64 binfmt"
    else echo "  ✗ qemu-aarch64 binfmt (für arm64-Chroot auf x86)"; miss=1; fi
  fi
  [ "$miss" = 0 ] && { c "Alles da."; return 0; }
  cat <<'EOF'

Fehlende Werkzeuge:
  Debian/Ubuntu:  sudo apt install mmdebstrap qemu-user-static binfmt-support e2fsprogs gnupg curl git \
                  dpkg xz-utils android-sdk-libsparse-utils
  Gentoo:         einfacher über Docker:  ./build-noxis-linux.sh container
                  (einmalig binfmt:  docker run --privileged --rm tonistiigi/binfmt --install arm64)
EOF
  return 1
}

# ------------------------------------------------------------ opsec-Paket
cmd_opsec() {
  mkdir -p "$DL"
  local pkg="$HERE/noxis-opsec"
  sed -i "s/^Version: .*/Version: $VERSION/" "$pkg/DEBIAN/control"
  dpkg-deb --root-owner-group --build "$pkg" "$DL/noxis-opsec_${VERSION}_all.deb" >/dev/null
  c "noxis-opsec_${VERSION}_all.deb gebaut"
  pkg="$HERE/noxis-shell"
  sed -i "s/^Version: .*/Version: $VERSION/" "$pkg/DEBIAN/control"
  find "$pkg" -name __pycache__ -prune -exec rm -r {} +
  dpkg-deb --root-owner-group --build "$pkg" "$DL/noxis-shell_${VERSION}_all.deb" >/dev/null
  c "noxis-shell_${VERSION}_all.deb gebaut"
}

# ------------------------------------------------------------ Downloads (signaturgeprüft)
fpr_of() { gpg --batch --with-colons --show-keys "$1" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}'; }

fetch_mullvad_key() {
  local k="$DL/mullvad-keyring.asc" got
  curl -fsSL -o "$k" https://repository.mullvad.net/deb/mullvad-keyring.asc
  got=$(gpg --batch --with-colons --show-keys "$k" | awk -F: '/^fpr:/ {print $10}')
  if ! grep -qx "$MULLVAD_FPR" <<<"$got"; then
    die "Mullvad-Repo-Schlüssel unerwartet: $(echo $got). Prüfen auf https://mullvad.net/help/verifying-signatures und ggf. NOXIS_MULLVAD_FPR=<fingerprint> setzen."
  fi
  c "Mullvad-Schlüssel ok ($MULLVAD_FPR)"
}

fetch_tor() {
  local ver base f
  ver=$(curl -fsSL https://dist.torproject.org/torbrowser/ | grep -oE 'href="[0-9]+\.[0-9]+(\.[0-9]+)?/"' \
        | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sort -V | tail -1)
  [ -n "$ver" ] || die "Tor-Version nicht ermittelbar"
  base="https://dist.torproject.org/torbrowser/$ver"
  f="tor-browser-linux-aarch64-$ver.tar.xz"
  c "Tor Browser $ver (Linux aarch64)"
  curl -fsSL -o "$DL/$f" "$base/$f"
  curl -fsSL -o "$DL/$f.asc" "$base/$f.asc"
  mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  curl -fsSL -o "$DL/tor.asc" "https://keys.openpgp.org/vks/v1/by-fingerprint/$TOR_FPR"
  [ "$(fpr_of "$DL/tor.asc")" = "$TOR_FPR" ] || die "Tor-Schlüssel hat falschen Fingerabdruck"
  gpg --batch --quiet --import "$DL/tor.asc"
  gpg --batch --export "$TOR_FPR" > "$DL/tor.keyring"
  gpgv --keyring "$DL/tor.keyring" "$DL/$f.asc" "$DL/$f" 2>&1 | grep -q "Good signature" \
    || die "Tor-Browser-Signatur UNGÜLTIG – Abbruch"
  ln -sf "$f" "$DL/tor-browser.tar.xz"
  c "Tor-Browser-Signatur gültig"
}

fetch_arkenfox() {
  local d="$DL/arkenfox"
  [ -d "$d/.git" ] || git clone -q --depth=1 https://github.com/arkenfox/user.js "$d"
  sed -E 's/^([[:space:]]*)user_pref\(/\1pref(/' "$d/user.js" > "$DL/noxis-arkenfox.js"
  [ "$(grep -c '^[[:space:]]*user_pref(' "$DL/noxis-arkenfox.js")" = 0 ] || die "arkenfox-Umwandlung unvollständig"
  c "arkenfox: $(grep -c '^[[:space:]]*pref(' "$DL/noxis-arkenfox.js") Einstellungen ($(git -C "$d" log -1 --format=%cs))"
}

cmd_fetch() {
  mkdir -p "$DL" "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  fetch_mullvad_key
  fetch_tor
  fetch_arkenfox
}

# ------------------------------------------------------------ rootfs
write_customize() {  # Skript, das im arm64-Chroot läuft
  cat > "$WORK/customize.sh" <<EOF
#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
echo noxis > /etc/hostname
printf '127.0.0.1 localhost\n127.0.1.1 noxis\n' > /etc/hosts
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
sed -i 's/^# *de_DE.UTF-8/de_DE.UTF-8/; s/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen >/dev/null
echo 'LANG=de_DE.UTF-8' > /etc/default/locale

# Mullvad-Repository
install -m644 /tmp/noxis/mullvad-keyring.asc /usr/share/keyrings/mullvad-keyring.asc
echo "deb [signed-by=/usr/share/keyrings/mullvad-keyring.asc arch=arm64] https://repository.mullvad.net/deb/stable stable main" > /etc/apt/sources.list.d/mullvad.list
apt-get update -q
apt-get install -y -q mullvad-vpn

# Noxis-OPSEC-Schicht
apt-get install -y -q /tmp/noxis/noxis-opsec.deb

# Optionale Pakete (fehlen sie im Archiv, wird weitergebaut)
for p in $PKG_OPTIONAL; do apt-get install -y -q "\$p" || echo "optional fehlt: \$p"; done

# Geräte-Pakete (Kernel/Adaptation), falls übergeben
if ls /tmp/noxis/device/*.deb >/dev/null 2>&1; then apt-get install -y -q /tmp/noxis/device/*.deb; fi
# Root wächst beim ersten Start auf die volle userdata-Partition
grep -q 'LABEL=noxis-root' /etc/fstab 2>/dev/null || \
  echo 'LABEL=noxis-root / ext4 defaults,noatime,x-systemd.growfs 0 1' >> /etc/fstab

# Tor Browser nach /opt
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

# Firefox ESR: arkenfox als Systemstandard
for d in /usr/lib/firefox-esr/defaults/pref /usr/lib/firefox/defaults/pref; do
  [ -d "\$(dirname "\$d")" ] && mkdir -p "\$d" && install -m644 /tmp/noxis/noxis-arkenfox.js "\$d/noxis-arkenfox.js"
done

# Benutzer + Phosh-Autostart
id $NUSER >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,audio,video,render,input,netdev,plugdev,bluetooth,dialout $NUSER 2>/dev/null \
  || useradd -m -s /bin/bash -G sudo,audio,video,input $NUSER
echo "$NUSER:$NPIN" | chpasswd
# Anmeldung: eigener Display-Manager noxis-dm + Greeter → PIN nach jedem Start, kein Autologin
apt-get install -y -q /tmp/noxis/noxis-shell.deb
sed -i "s/^user *=.*/user = $NUSER/" /etc/noxis/greeter.conf
systemctl enable noxis-dm.service
systemctl disable phosh.service greetd.service 2>/dev/null || true
systemctl set-default graphical.target

# Kein SSH, keine Fernzugänge
apt-get purge -y -q openssh-server 2>/dev/null || true
systemctl mask --quiet ssh.service 2>/dev/null || true

# Aufräumen im Image
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/noxis /var/log/*.log
: > /etc/machine-id
EOF
  chmod 755 "$WORK/customize.sh"
}

cmd_rootfs() {
  command -v mmdebstrap >/dev/null || die "mmdebstrap fehlt – ./build-noxis-linux.sh check"
  [ -f "$DL/noxis-opsec_${VERSION}_all.deb" ] && [ -f "$DL/noxis-shell_${VERSION}_all.deb" ] || cmd_opsec
  [ -f "$DL/tor-browser.tar.xz" ] && [ -f "$DL/noxis-arkenfox.js" ] && [ -f "$DL/mullvad-keyring.asc" ] || cmd_fetch
  write_customize
  local devdir="$WORK/device"; mkdir -p "$devdir"
  if [ -n "$DEVICE_DEBS" ]; then cp "$DEVICE_DEBS"/*.deb "$devdir/"; fi
  c "Debian $SUITE ($ARCH) + Phosh + Noxis bauen …"
  mmdebstrap --mode=auto --arch="$ARCH" --variant=important \
    --components="main contrib non-free-firmware" \
    --include="$PKG_BASE,$PKG_NET,$PKG_UI,$PKG_APPS" \
    --customize-hook='mkdir -p "$1/tmp/noxis/device"' \
    --customize-hook="copy-in $DL/noxis-opsec_${VERSION}_all.deb /tmp/noxis/" \
    --customize-hook="chroot \"\$1\" mv /tmp/noxis/noxis-opsec_${VERSION}_all.deb /tmp/noxis/noxis-opsec.deb" \
    --customize-hook="copy-in $DL/noxis-shell_${VERSION}_all.deb /tmp/noxis/" \
    --customize-hook="chroot \"\$1\" mv /tmp/noxis/noxis-shell_${VERSION}_all.deb /tmp/noxis/noxis-shell.deb" \
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
  [ -f "$ROOTFS_TAR" ] || die "Erst ./build-noxis-linux.sh rootfs"
  mkdir -p "$OUT"
  local img="$OUT/rootfs.img" mb
  mb=$(( $(stat -c %s "$ROOTFS_TAR") / 1048576 * 13 / 10 + 1024 ))
  rm -f "$img"; truncate -s "${mb}M" "$img"
  c "rootfs.img (${mb} MB, ext4)"
  if ! mkfs.ext4 -q -F -L noxis-root -d "$ROOTFS_TAR" "$img" 2>/dev/null; then
    # e2fsprogs < 1.47.1 kann kein Tar → entpacken (braucht root wegen Besitzrechten)
    [ "$(id -u)" = 0 ] || die "mkfs.ext4 kann kein Tar und kein root – ./build-noxis-linux.sh container nutzen"
    local tdir="$WORK/rootfs-dir"; rm -rf "$tdir"; mkdir -p "$tdir"
    tar -xpf "$ROOTFS_TAR" -C "$tdir" --numeric-owner
    mkfs.ext4 -q -F -L noxis-root -d "$tdir" "$img"
    rm -rf "$tdir"
  fi
  e2fsck -fy "$img" >/dev/null 2>&1 || true
  if command -v img2simg >/dev/null 2>&1; then
    img2simg "$img" "$OUT/rootfs-sparse.img" && c "rootfs-sparse.img für fastboot"
  fi
}

# ------------------------------------------------------------ boot
cmd_boot() {
  mkdir -p "$OUT"
  if [ -n "$BOOT_IMG" ]; then
    [ -f "$BOOT_IMG" ] || die "BOOT_IMG=$BOOT_IMG fehlt"
    cp -f "$BOOT_IMG" "$OUT/boot.img"; c "boot.img übernommen"; return 0
  fi
  if [ -n "$DEVICE_DEBS" ]; then
    local t; t=$(mktemp -d)
    for d in "$DEVICE_DEBS"/linux-bootimage-*.deb; do [ -f "$d" ] && dpkg-deb -x "$d" "$t"; done
    local b; b=$(find "$t" -name 'boot.img' | head -1)
    if [ -n "$b" ]; then cp -f "$b" "$OUT/boot.img"; c "boot.img aus Geräte-Kernelpaket"
      local vb; vb=$(find "$t" -name 'vendor_boot.img' | head -1); [ -n "$vb" ] && cp -f "$vb" "$OUT/vendor_boot.img"
      local dt; dt=$(find "$t" -name 'dtbo.img' | head -1); [ -n "$dt" ] && cp -f "$dt" "$OUT/dtbo.img"
      local vm; vm=$(find "$t" -name 'vbmeta.img' | head -1); [ -n "$vm" ] && cp -f "$vm" "$OUT/vbmeta.img"
    fi
    rm -r "$t"
    [ -f "$OUT/boot.img" ] && return 0
  fi
  warn "Kein Kernel für Nothing Phone (3a) verfügbar – boot.img wird übersprungen."
  warn "Sobald ein Halium-/Mainline-Kernel existiert: NOXIS_DEVICE_DEBS=<ordner> oder BOOT_IMG=<datei>."
  : > "$OUT/.no-boot"
}

# ------------------------------------------------------------ verify
cmd_verify() {
  local img="$OUT/rootfs.img"
  [ -f "$img" ] || die "rootfs.img fehlt"
  c "Prüfe Dateisystem"
  e2fsck -fn "$img" >/dev/null 2>&1 || die "rootfs.img: Dateisystemfehler"
  local f missing=0
  for f in /usr/lib/noxis/usblock.py /etc/noxis/firewall.nft /usr/lib/systemd/system/noxis-firewall.service \
           /etc/systemd/resolved.conf.d/90-noxis.conf /opt/tor-browser /usr/share/keyrings/mullvad-keyring.asc \
           /etc/hostname; do
    if debugfs -R "stat $f" "$img" 2>/dev/null | grep -q "Inode:"; then echo "  ✓ $f"; else echo "  ✗ $f"; missing=1; fi
  done
  [ "$missing" = 0 ] || die "Pflichtdateien fehlen im Image"
  ( cd "$OUT" && sha256sum $(ls rootfs.img rootfs-sparse.img boot.img vendor_boot.img dtbo.img vbmeta.img 2>/dev/null) > SHA256SUMS )
  ( cd "$OUT" && sha256sum -c --quiet SHA256SUMS ) || die "SHA-256-Prüfung fehlgeschlagen"
  c "SHA-256 ok:"; sed 's,^,  ,' "$OUT/SHA256SUMS"
  : > "$OUT/.verified"
}

# ------------------------------------------------------------ cleanup
cmd_cleanup() {
  [ -f "$OUT/.verified" ] || die "Nicht verifiziert – Build-Ordner wird NICHT gelöscht"
  ( cd "$OUT" && sha256sum -c --quiet SHA256SUMS ) || die "Ausgabe beschädigt – Build-Ordner bleibt"
  case "$WORK" in ""|/|"$HOME"|"$HOME/") die "Unsicherer WORK-Pfad: '$WORK'";; esac
  [ -d "$WORK" ] || { c "Build-Ordner schon weg"; return 0; }
  [ -f "$WORK/customize.sh" ] || [ -d "$WORK/downloads" ] || die "$WORK sieht nicht wie ein Noxis-Build-Ordner aus"
  c "Lösche $WORK ($(du -sh "$WORK" 2>/dev/null | cut -f1))"
  rm -rf -- "$WORK"
  c "Fertig. Ergebnis: $OUT"; ls -lh "$OUT" | tail -n +2 | sed 's,^,  ,'
}

# ------------------------------------------------------------ container
cmd_container() {
  command -v docker >/dev/null || die "docker fehlt"
  [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || \
    docker run --privileged --rm tonistiigi/binfmt --install arm64
  local out; out="$(desktop_dir)"; mkdir -p "$out"
  local devargs=()
  if ls "$out/noxis-linux/device/"*.deb >/dev/null 2>&1; then
    c "Geräte-Pakete gefunden: $out/noxis-linux/device"
    devargs=(-v "$out/noxis-linux/device:/device:ro" -e NOXIS_DEVICE_DEBS=/device)
  fi
  docker run --rm --privileged \
    -v "$HERE:/noxis:ro" -v "$out:/out" -v "noxis-build:/work" "${devargs[@]}" \
    -e NOXIS_WORK=/work/build -e NOXIS_OUT=/out/noxis-linux -e NOXIS_USER -e NOXIS_PIN \
    debian:trixie bash -c '
      set -e
      apt-get update -q && apt-get install -y -q mmdebstrap qemu-user-static e2fsprogs gnupg curl git \
        dpkg xz-utils android-sdk-libsparse-utils ca-certificates arch-test >/dev/null
      cp -r /noxis /tmp/noxis-src && cd /tmp/noxis-src && ./build-noxis-linux.sh all'
}

# ------------------------------------------------------------ kernel (Docker)
cmd_kernel() {
  command -v docker >/dev/null || die "docker fehlt"
  local out; out="$(desktop_dir)/noxis-linux"; mkdir -p "$out"
  local fw=()
  if [ -n "${NOXIS_FIRMWARE:-}" ]; then
    [ -d "$NOXIS_FIRMWARE" ] || die "NOXIS_FIRMWARE=$NOXIS_FIRMWARE fehlt"
    fw=(-v "$(readlink -f "$NOXIS_FIRMWARE"):/firmware:ro" -e NOXIS_FIRMWARE=/firmware)
  fi
  c "Kernel im Debian-Container bauen (Quellen + Objekte bleiben im Volume noxis-kernel)"
  docker run --rm \
    -v "$HERE:/noxis:ro" -v "$out:/out" -v "noxis-kernel:/kwork" "${fw[@]}" \
    -e NOXIS_KWORK=/kwork -e NOXIS_KOUT=/out -e NOXIS_JOBS -e NOXIS_KERNEL_BRANCH -e NOXIS_CMDLINE -e NOXIS_BOOT_SIZE \
    debian:trixie bash -c '
      set -e
      apt-get update -q && apt-get install -y -q --no-install-recommends clang lld llvm make bc bison flex perl \
        python3 git cpio kmod mkbootimg libelf-dev libssl-dev dpkg-dev ca-certificates openssl >/dev/null
      /noxis/kernel/build-noxis-kernel.sh all'
  c "Fertig: $out/boot.img + $out/device/*.deb"
}

cmd_all() { cmd_check; cmd_opsec; cmd_fetch; cmd_rootfs; cmd_image; cmd_boot; cmd_verify; cmd_cleanup; }

case "${1:-}" in
  check) cmd_check ;; opsec) cmd_opsec ;; fetch) cmd_fetch ;; rootfs) cmd_rootfs ;;
  image) cmd_image ;; boot) cmd_boot ;; verify) cmd_verify ;; cleanup) cmd_cleanup ;;
  all) cmd_all ;; container) cmd_container ;; kernel) cmd_kernel ;;
  *) sed -n '2,19p' "$0" ;;
esac
