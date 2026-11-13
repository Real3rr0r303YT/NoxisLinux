#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
# Mesa mit Turnip-KGSL-Backend fuer Noxis Linux (EXPERIMENTELL)
#
# Warum: der Kernel benutzt Qualcomms KGSL fuer die GPU. Debians Mesa spricht
# nur mit dem Mainline-msm-Treiber, deshalb gibt es kein GL und die Oberflaeche
# rendert in Software. Mesas Vulkan-Treiber "turnip" hat ein KGSL-Backend
# (-Dfreedreno-kmds=kgsl), dazu zink fuer GL ueber Vulkan.
#
# Offen und erst auf dem Geraet zu klaeren: ob turnip die Adreno-GPU des
# SM7635 kennt, und ob ein Compositor damit rendern kann.
#
#   ./build-mesa-kgsl.sh          baut in einem arm64-Container (qemu, dauert
#                                 ein bis drei Stunden, laeuft allein)
#   MESA_REF=mesa-25.2.0 ./...    anderer Stand (Standard: main)
#
# Ergebnis: ~/Desktop/noxis-linux/mesa-kgsl.tar.gz -> /opt/mesa-kgsl
set -euo pipefail
OUT="$HOME/Desktop/noxis-linux"
REF="${MESA_REF:-main}"
mkdir -p "$OUT"
command -v docker >/dev/null || { echo "docker fehlt"; exit 1; }
sudo docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 || true

echo "[mesa] baue $REF fuer arm64 – das dauert, Ausgabe kommt erst am Ende jedes Schritts"
sudo docker run --rm --platform linux/arm64 -v "$OUT:/out" -e REF="$REF" debian:trixie bash -c '
  set -e
  apt-get update -q >/dev/null
  apt-get install -y -q --no-install-recommends git ca-certificates build-essential meson ninja-build \
    pkg-config python3-mako python3-yaml python3-packaging python3-ply glslang-tools bison flex \
    libdrm-dev libwayland-dev libwayland-egl-backend-dev wayland-protocols libexpat1-dev zlib1g-dev \
    libzstd-dev libelf-dev vulkan-tools libvulkan1 >/dev/null
  git clone -q --depth 1 --branch "$REF" https://gitlab.freedesktop.org/mesa/mesa.git /src
  cd /src
  echo "[mesa] Stand: $(git log -1 --format=%h\ %s)"
  meson setup build --prefix=/opt/mesa-kgsl --buildtype=release \
    -Dplatforms=wayland -Dglx=disabled -Dgbm=enabled -Degl=enabled -Dgles1=disabled -Dgles2=enabled \
    -Dgallium-drivers=zink -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl \
    -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=enabled >/out/mesa-meson.log 2>&1 \
    || { tail -40 /out/mesa-meson.log; exit 1; }
  ninja -C build >/out/mesa-build.log 2>&1 || { tail -40 /out/mesa-build.log; exit 1; }
  DESTDIR=/stage ninja -C build install >/dev/null
  # vulkaninfo + libvulkan fuer den Test auf dem Geraet mitliefern
  mkdir -p /stage/opt/mesa-kgsl/bin /stage/opt/mesa-kgsl/lib
  cp /usr/bin/vulkaninfo /stage/opt/mesa-kgsl/bin/
  cp -a /usr/lib/aarch64-linux-gnu/libvulkan.so.1* /stage/opt/mesa-kgsl/lib/
  tar -C /stage/opt -czf /out/mesa-kgsl.tar.gz mesa-kgsl
'
ls -la "$OUT/mesa-kgsl.tar.gz"
echo "[mesa] fertig. Aufs Geraet (in der Recovery): kernel/tools/noxis-diag.sh gpu"
