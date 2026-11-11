#!/usr/bin/env bash
# Flow test for build-noxis-linux.sh
#  - downloads, git and mmdebstrap are fakes
#  - GPG signature checks, mkfs.ext4, debugfs, e2fsck, sha256sum are REAL
# Needs: root (ext4 from a directory with e2fsprogs < 1.47.1), gpg, e2fsprogs
#   test/test_build.sh <pfad-zu-arkenfox-user.js>
set -uo pipefail
NX="$(cd "$(dirname "$0")/.." && pwd)"
ARKENFOX_JS="${1:?Pfad zu arkenfox user.js}"
W=$(mktemp -d); BIN="$W/bin"; FIX="$W/fix"; LOG="$W/calls.log"; mkdir -p "$BIN" "$FIX"
pass=0; fail=0
ok() { if eval "$2" >/dev/null 2>&1; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }
no() { if eval "$2" >/dev/null 2>&1; then echo "FAIL $1"; fail=$((fail+1)); else echo "PASS $1"; pass=$((pass+1)); fi; }

# ---------- test keys (real GPG keys, test only)
export GNUPGHOME="$W/gpg-test"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
for who in tor mullvad evil; do
  gpg --batch --quiet --pinentry-mode loopback --passphrase '' --quick-gen-key "$who-test <$who@test>" rsa2048 sign never
done
fpr() { gpg --with-colons --list-keys "$1@test" | awk -F: '/^fpr:/ {print $10; exit}'; }
TORF=$(fpr tor); MULF=$(fpr mullvad)
gpg --batch --armor --export "$TORF" > "$FIX/tor.asc"
gpg --batch --armor --export "$MULF" > "$FIX/mullvad.asc"
gpg --batch --armor --export "$(fpr evil)" > "$FIX/evil.asc"
mkdir -p "$FIX/tb/tor-browser/Browser"; echo '#!/bin/sh' > "$FIX/tb/tor-browser/Browser/start-tor-browser"
tar -cJf "$FIX/tor-browser-linux-aarch64-16.0.tar.xz" -C "$FIX/tb" tor-browser
gpg --batch --yes --armor --local-user "$TORF" --detach-sign -o "$FIX/tor-browser-linux-aarch64-16.0.tar.xz.asc" "$FIX/tor-browser-linux-aarch64-16.0.tar.xz"
unset GNUPGHOME

# ---------- Attrappen
cat > "$BIN/curl" <<EOF
#!/bin/sh
echo "curl \$*" >> $LOG
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2;; -*) shift;; *) url="\$1"; shift;; esac; done
src=""
case "\$url" in
  */torbrowser/) printf '<a href="16.0a14/">a</a> <a href="16.0/">s</a> <a href="15.0.9/">o</a>\n'; exit 0 ;;
  */16.0/tor-browser-linux-aarch64-16.0.tar.xz) src="${FIX}/\${TAMPER:+evil-}tor-browser-linux-aarch64-16.0.tar.xz" ;;
  */16.0/tor-browser-linux-aarch64-16.0.tar.xz.asc) src="$FIX/tor-browser-linux-aarch64-16.0.tar.xz.asc" ;;
  *keys.openpgp.org/*) src="$FIX/tor.asc" ;;
  *mullvad-keyring.asc) src="$FIX/\${MULLVAD_KEY:-mullvad}.asc" ;;
  *) echo "unknown URL \$url" >&2; exit 22 ;;
esac
[ -f "\$src" ] || exit 22
if [ -n "\$out" ]; then cp "\$src" "\$out"; else cat "\$src"; fi
EOF
cp "$FIX/tor-browser-linux-aarch64-16.0.tar.xz" "$FIX/evil-tor-browser-linux-aarch64-16.0.tar.xz"
echo "manipuliert" | xz >> "$FIX/evil-tor-browser-linux-aarch64-16.0.tar.xz"

cat > "$BIN/git" <<EOF
#!/bin/sh
echo "git \$*" >> $LOG
case "\$*" in
  clone*) eval d=\\\${\$#}; mkdir -p "\$d/.git"; cp "$ARKENFOX_JS" "\$d/user.js" ;;
  *log*) echo 2026-10-31 ;;
esac
EOF

# fake mmdebstrap: emulates what customize.sh would do in the chroot
cat > "$BIN/mmdebstrap" <<'EOF'
#!/bin/bash
echo "mmdebstrap $*" >> LOGF
args=("$@"); target="${args[-2]}"
R=$(mktemp -d); DL="$NOXIS_WORK/downloads"
dpkg-deb -x "$DL"/noxis-opsec_*_all.deb "$R"
[ -n "${DROP_USBLOCK:-}" ] && rm -f "$R/usr/lib/noxis/usblock.py"
mkdir -p "$R/opt" "$R/usr/share/keyrings" "$R/etc"
tar -xJf "$DL/tor-browser.tar.xz" -C "$R/opt"
cp "$DL/mullvad-keyring.asc" "$R/usr/share/keyrings/"
echo noxis > "$R/etc/hostname"
grep -q 'chroot "$1" /tmp/noxis/customize.sh' <<<"$*" && echo ok > "$R/etc/.customize-hook"
tar --numeric-owner --owner=0 --group=0 -cf "$target" -C "$R" .
rm -rf "$R"
EOF
sed -i "s|LOGF|$LOG|" "$BIN/mmdebstrap"
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export NOXIS_WORK="$W/work" NOXIS_OUT="$W/out" NOXIS_TOR_FPR="$TORF" NOXIS_MULLVAD_FPR="$MULF"
B="$NX/build-noxis-linux.sh"

$B opsec > "$W/o1" 2>&1;                      ok "opsec: package built" "dpkg-deb -I $NOXIS_WORK/downloads/noxis-opsec_1.0.0_all.deb"
$B fetch > "$W/f1" 2>&1;                      ok "fetch: Tor signature valid (real gpgv)" "grep -q 'Tor Browser signature valid' $W/f1"
ok "fetch: latest stable Tor version (16.0, not alpha)" "grep -q 'Tor Browser 16.0 (Linux aarch64)' $W/f1"
ok "fetch: Mullvad fingerprint checked" "grep -q 'Mullvad key ok' $W/f1"
ok "fetch: arkenfox converted, no user_pref left" "grep -q 'arkenfox: 18[0-9] prefs' $W/f1 && ! grep -q '^user_pref' $NOXIS_WORK/downloads/noxis-arkenfox.js"
ok "fetch: git clone with --depth=1" "grep -q 'git clone -q --depth=1' $LOG"
TAMPER=1 $B fetch > "$W/f2" 2>&1;            ok "fetch: tampered Tor Browser rejected" "grep -q 'INVALID' $W/f2"
MULLVAD_KEY=evil $B fetch > "$W/f3" 2>&1;    ok "fetch: wrong Mullvad key rejected" "grep -q 'Unexpected Mullvad repository key' $W/f3"
NOXIS_TOR_FPR=0000000000000000000000000000000000000000 $B fetch > "$W/f4" 2>&1
ok "fetch: wrong Tor fingerprint rejected" "grep -q 'wrong fingerprint' $W/f4"
$B fetch > /dev/null 2>&1   # wieder sauberer Stand

$B rootfs > "$W/r1" 2>&1;                     ok "rootfs: tar created" "[ -s $NOXIS_WORK/rootfs.tar ]"
ok "rootfs: arm64, trixie, Phosh, Squeekboard, firewall packages" "grep -q -- '--arch=arm64' $LOG && grep -q 'trixie' $LOG && grep -q 'phosh-core' $LOG && grep -q 'squeekboard' $LOG && grep -q 'nftables' $LOG && grep -q 'usbguard' $LOG"
ok "rootfs: customize.sh runs in the chroot" "tar -tf $NOXIS_WORK/rootfs.tar | grep -q 'etc/.customize-hook'"
ok "rootfs: customize.sh syntax ok" "bash -n $NOXIS_WORK/customize.sh"
ok "rootfs: Mullvad repo + lockdown package + no SSH in the chroot script" "grep -q 'repository.mullvad.net/deb/stable' $NOXIS_WORK/customize.sh && grep -q 'noxis-opsec.deb' $NOXIS_WORK/customize.sh && grep -q 'mask --quiet ssh.service' $NOXIS_WORK/customize.sh"
ok "rootfs: Kali-style pentest tools in the chroot script" "grep -q 'PENTEST\\|pentest missing' $NOXIS_WORK/customize.sh && grep -q 'aircrack-ng' $NOXIS_WORK/customize.sh && grep -q 'distrobox' $NOXIS_WORK/customize.sh"
ok "opsec: noxis-kali helper + launcher in the package" "dpkg-deb -c $NOXIS_WORK/downloads/noxis-opsec_1.0.0_all.deb | grep -q 'usr/bin/noxis-kali' && dpkg-deb -c $NOXIS_WORK/downloads/noxis-opsec_1.0.0_all.deb | grep -q 'noxis-kali.desktop'"

$B image > "$W/i1" 2>&1;                      ok "image: rootfs.img is real ext4" "e2fsck -fn $NOXIS_OUT/rootfs.img"
ok "image: firewall rules readable in the image" "debugfs -R 'cat /etc/noxis/firewall.nft' $NOXIS_OUT/rootfs.img 2>/dev/null | grep -q 'policy drop'"
$B boot > "$W/b1" 2>&1;                       ok "boot: skipped cleanly without a 3a kernel" "grep -q 'No kernel for the Nothing Phone (3a)' $W/b1 && [ -f $NOXIS_OUT/.no-boot ]"
echo bootimg > "$W/boot.img"
BOOT_IMG="$W/boot.img" $B boot > "$W/b2" 2>&1; ok "boot: BOOT_IMG copied" "cmp -s $W/boot.img $NOXIS_OUT/boot.img"

$B verify > "$W/v1" 2>&1;                     ok "verify: required files + SHA-256" "grep -q 'SHA-256 ok' $W/v1 && [ -f $NOXIS_OUT/.verified ]"
ok "verify: SHA256SUMS contains rootfs.img and boot.img" "grep -q rootfs.img $NOXIS_OUT/SHA256SUMS && grep -q boot.img $NOXIS_OUT/SHA256SUMS"

# negative case: a broken image must not verify and must not be cleaned up
NW="$W/work2"; NO="$W/out2"
NOXIS_WORK=$NW NOXIS_OUT=$NO $B opsec >/dev/null 2>&1
NOXIS_WORK=$NW NOXIS_OUT=$NO $B fetch >/dev/null 2>&1
DROP_USBLOCK=1 NOXIS_WORK=$NW NOXIS_OUT=$NO $B rootfs >/dev/null 2>&1
NOXIS_WORK=$NW NOXIS_OUT=$NO $B image >/dev/null 2>&1
NOXIS_WORK=$NW NOXIS_OUT=$NO $B verify > "$W/v2" 2>&1
ok "verify: missing file in the image detected" "grep -q 'Required files missing' $W/v2"
NOXIS_WORK=$NW NOXIS_OUT=$NO $B cleanup > "$W/c2" 2>&1
ok "cleanup: nothing deleted without verification" "grep -q 'will NOT be deleted' $W/c2 && [ -d $NW ]"
echo kaputt >> "$NOXIS_OUT/rootfs.img"
$B cleanup > "$W/c3" 2>&1
ok "cleanup: changed output (SHA-256) → nothing deleted" "grep -q 'Output damaged' $W/c3 && [ -d $NOXIS_WORK ]"
( cd "$NOXIS_OUT" && sha256sum rootfs.img boot.img > SHA256SUMS )
NOXIS_WORK="$HOME" $B cleanup > "$W/c4" 2>&1
ok "cleanup: refuses WORK=\$HOME" "grep -q 'Unsafe WORK path' $W/c4"
$B cleanup > "$W/c5" 2>&1
ok "cleanup: build folder deleted, output kept" "[ ! -d $NOXIS_WORK ] && [ -f $NOXIS_OUT/rootfs.img ] && [ -f $NOXIS_OUT/boot.img ]"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ] && rm -rf "$W" || echo "Logs: $W"
[ "$fail" -eq 0 ]
