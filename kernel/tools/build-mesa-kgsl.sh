#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Noxis Linux – Made by 3rr0r303YT on TikTok
# https://github.com/Real3rr0r303YT/NoxisLinux
# Mesa mit Turnip-KGSL-Backend fuer Noxis Linux (EXPERIMENTELL)
#
# Warum: der Kernel benutzt Qualcomms KGSL fuer die GPU. Debians Mesa spricht
# nur mit dem Mainline-msm-Treiber, deshalb gibt es kein GL und die Oberfläche
# rendert in Software. Mesas Vulkan-Treiber "turnip" hat ein KGSL-Backend
# (-Dfreedreno-kmds=kgsl).
#
# Stufe 1 (vulkan) ist auf dem Geraet bestanden: turnip meldet
# "Adreno (TM) 810", Vulkan 1.4. Damit ist klar, dass die GPU nutzbar ist.
#
# Stufe 2 (zink, Standard) setzt GL obendrauf: zink ist der Gallium-Treiber,
# der OpenGL auf Vulkan abbildet. Erst damit kann die Oberflaeche ueberhaupt
# beschleunigt rendern - Vulkan allein bringt ihr nichts.
#
#   ./build-mesa-kgsl.sh          zink + Vulkan (dauert ein bis drei Stunden)
#   ./build-mesa-kgsl.sh vulkan   nur Vulkan, wie Stufe 1
#   MESA_REF=mesa-25.2.0 ./...    anderer Stand (Standard: main)
#
# Ergebnis: ~/Desktop/noxis-linux/mesa-kgsl.tar.gz -> /opt/mesa-kgsl
set -euo pipefail
OUT="$HOME/Desktop/noxis-linux"
REF="${MESA_REF:-main}"
STUFE="${1:-zink}"
case "$STUFE" in
  zink|vulkan) ;;
  *) echo "Nutzung: $0 [zink|vulkan]"; exit 1 ;;
esac
mkdir -p "$OUT"
command -v docker >/dev/null || { echo "docker fehlt"; exit 1; }
sudo docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 || true

echo "[mesa] baue $REF ($STUFE) fuer arm64 – das dauert, Ausgabe kommt erst am Ende jedes Schritts"
sudo docker run --rm --platform linux/arm64 -v "$OUT:/out" -e REF="$REF" -e STUFE="$STUFE" debian:trixie bash -c '
  set -e
  apt-get update -q >/dev/null
  apt-get install -y -q --no-install-recommends git ca-certificates build-essential meson ninja-build \
    pkg-config python3-mako python3-yaml python3-packaging python3-ply glslang-tools bison flex \
    libdrm-dev libwayland-dev libwayland-egl-backend-dev wayland-protocols libexpat1-dev zlib1g-dev \
    libzstd-dev libelf-dev vulkan-tools libvulkan1 mesa-utils-bin >/dev/null
  git clone -q --depth 1 --branch "$REF" https://gitlab.freedesktop.org/mesa/mesa.git /src
  cd /src
  echo "[mesa] Stand: $(git log -1 --format=%h\ %s)"
  if [ "$STUFE" = zink ]; then
    # zink braucht GBM fuer den Bildschirmpuffer. Mesa gibt GBM nur mit einem
    # Gallium-Treiber heraus - zink ist einer, also geht es diesmal. Scheitert
    # es doch, bauen wir ohne GBM weiter: EGL/GLES allein ist immer noch mehr
    # als Software-Rendering.
    GEM="-Dgbm=enabled"
    meson setup build --prefix=/opt/mesa-kgsl --buildtype=release \
      -Dplatforms=wayland -Dglx=disabled $GEM -Degl=enabled -Dopengl=true \
      -Dgles1=disabled -Dgles2=enabled -Dshared-glapi=enabled \
      -Dgallium-drivers=zink \
      -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl \
      -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=enabled \
      >/out/mesa-meson.log 2>&1 || {
        echo "[mesa] mit GBM gescheitert - nochmal ohne"
        rm -rf build
        meson setup build --prefix=/opt/mesa-kgsl --buildtype=release \
          -Dplatforms=wayland -Dglx=disabled -Dgbm=disabled -Degl=enabled -Dopengl=true \
          -Dgles1=disabled -Dgles2=enabled -Dshared-glapi=enabled \
          -Dgallium-drivers=zink \
          -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl \
          -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=enabled \
          >/out/mesa-meson.log 2>&1 || { tail -40 /out/mesa-meson.log; exit 1; }
      }
  else
    # Stufe 1: nur Vulkan. Das ist der Test, der schon bestanden ist.
    meson setup build --prefix=/opt/mesa-kgsl --buildtype=release \
      -Dplatforms=wayland -Dglx=disabled -Dgbm=disabled -Degl=disabled -Dopengl=false \
      -Dgles1=disabled -Dgles2=disabled -Dgallium-drivers= \
      -Dvulkan-drivers=freedreno -Dfreedreno-kmds=kgsl \
      -Dllvm=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=enabled \
      >/out/mesa-meson.log 2>&1 || { tail -40 /out/mesa-meson.log; exit 1; }
  fi
  ninja -C build >/out/mesa-build.log 2>&1 || { tail -40 /out/mesa-build.log; exit 1; }
  DESTDIR=/stage ninja -C build install >/dev/null
  # Werkzeuge fuer den Test auf dem Geraet mitliefern
  mkdir -p /stage/opt/mesa-kgsl/bin /stage/opt/mesa-kgsl/lib
  cp /usr/bin/vulkaninfo /stage/opt/mesa-kgsl/bin/
  for t in eglinfo es2_info es2gears_wayland; do
    [ -x "/usr/bin/$t" ] && cp "/usr/bin/$t" /stage/opt/mesa-kgsl/bin/
  done
  cp -a /usr/lib/aarch64-linux-gnu/libvulkan.so.1* /stage/opt/mesa-kgsl/lib/
  tar -C /stage/opt -czf /out/mesa-kgsl.tar.gz mesa-kgsl
'
ls -la "$OUT/mesa-kgsl.tar.gz"
echo "[mesa] fertig ($STUFE). Aufs Geraet (in der Recovery): kernel/tools/noxis-diag.sh gpu"
