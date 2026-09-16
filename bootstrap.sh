#!/usr/bin/env bash
set -euo pipefail

VIDEO2X_VERSION="${VIDEO2X_VERSION:-6.4.0}"
TILE_SIZE="${TILE_SIZE:-1024}"
SRC_DIR="${SRC_DIR:-/workspace/video2x-src}"
INSTALL_DIR="${INSTALL_DIR:-/workspace/video2x-custom}"
WORK_DIR="${WORK_DIR:-/workspace/video2x}"

if [[ $EUID -ne 0 ]]; then
  echo 'Ejecuta este script como root.' >&2
  exit 1
fi

echo '== Verificando GPU =='
nvidia-smi

echo '== Instalando dependencias =='
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  git curl ca-certificates python3 build-essential cmake pkg-config ninja-build \
  ffmpeg vulkan-tools libvulkan-dev glslang-tools libomp-dev \
  libavcodec-dev libavdevice-dev libavfilter-dev libavformat-dev \
  libavutil-dev libswscale-dev libboost-program-options-dev

mkdir -p "$WORK_DIR/input" "$WORK_DIR/output" "$WORK_DIR/logs"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  echo '== Clonando Video2X =='
  git clone --depth 1 --branch "$VIDEO2X_VERSION" \
    https://github.com/k4yt3x/video2x.git "$SRC_DIR"
fi

cd "$SRC_DIR"

echo '== Inicializando submódulos necesarios =='
git submodule sync --recursive
# Usamos Boost del sistema; evitamos descargar third_party/boost completo.
git submodule update --init --depth 1 \
  third_party/ncnn \
  third_party/spdlog \
  third_party/librealesrgan_ncnn_vulkan \
  third_party/librealcugan_ncnn_vulkan \
  third_party/librife_ncnn_vulkan

# Los wrappers y ncnn tienen submódulos internos necesarios para compilar.
for module in \
  third_party/librealesrgan_ncnn_vulkan \
  third_party/librealcugan_ncnn_vulkan \
  third_party/librife_ncnn_vulkan \
  third_party/ncnn; do
  git -C "$module" submodule update --init --recursive --depth 1 || true
done

echo "== Aplicando TILE_SIZE=$TILE_SIZE =="
python3 - <<PY
from pathlib import Path
import re
p = Path('$SRC_DIR/src/filter_realesrgan.cpp')
s = p.read_text()
s2, n = re.subn(
    r'realesrgan_->tilesize = (?:200|512|768|1024|1536|2048);',
    'realesrgan_->tilesize = $TILE_SIZE;',
    s,
    count=1,
)
if n != 1:
    raise SystemExit('No se encontró la asignación principal de tilesize para modificar.')
p.write_text(s2)
PY

grep -n 'tilesize' src/filter_realesrgan.cpp

echo '== Configurando build =='
rm -rf build "$INSTALL_DIR"
cmake -G Ninja -B build -S . \
  -DVIDEO2X_USE_EXTERNAL_NCNN=OFF \
  -DVIDEO2X_USE_EXTERNAL_SPDLOG=OFF \
  -DCMAKE_CXX_COMPILER=g++ \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"

echo '== Compilando =='
cmake --build build --config Release --target install --parallel

cd "$INSTALL_DIR"
if [[ ! -e models ]]; then
  ln -s share/video2x/models models
fi

cat > "$INSTALL_DIR/env.sh" <<EOF
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:\${LD_LIBRARY_PATH:-}"
export VIDEO2X_BIN="$INSTALL_DIR/bin/video2x"
export VIDEO2X_WORK_DIR="$WORK_DIR"
EOF

export LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"

echo '== Validación =='
"$INSTALL_DIR/bin/video2x" --help >/dev/null
vulkaninfo --summary 2>/dev/null | grep -m1 -A8 'GPU0:' || true

echo
echo 'Listo.'
echo "Video2X: $INSTALL_DIR/bin/video2x"
echo "Trabajo: $WORK_DIR"
echo "Tile: $TILE_SIZE"
echo 'Ejecuta: source /workspace/video2x-custom/env.sh'
