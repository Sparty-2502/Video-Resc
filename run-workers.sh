#!/usr/bin/env bash
set -euo pipefail

WORKERS="${WORKERS:-3}"
WORK_DIR="${WORK_DIR:-/workspace/video2x}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-/workspace/video2x-custom/env.sh}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

mkdir -p "$WORK_DIR/input" "$WORK_DIR/output" "$WORK_DIR/logs"

echo '== Preflight Vulkan =='
if ! command -v vulkaninfo >/dev/null 2>&1; then
  echo 'ERROR: vulkaninfo no está disponible. Ejecuta bootstrap.sh primero.' >&2
  exit 2
fi
VK_SUMMARY="$(vulkaninfo --summary 2>&1 || true)"
if ! echo "$VK_SUMMARY" | grep -qiE 'deviceName.*NVIDIA|NVIDIA GeForce RTX'; then
  echo "$VK_SUMMARY" >&2
  echo 'ERROR: Vulkan no detecta una GPU NVIDIA. No se iniciará ningún worker.' >&2
  exit 2
fi

echo "GPU Vulkan OK. Workers solicitados: $WORKERS"

shopt -s nullglob
FILES=("$WORK_DIR/input"/*.{mp4,mkv,avi,mov,webm,m4v})
shopt -u nullglob

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No hay videos en $WORK_DIR/input"
  exit 0
fi

echo "Videos encontrados: ${#FILES[@]}"

export SCRIPT_DIR WORK_DIR
set +e
printf '%s\0' "${FILES[@]}" | xargs -0 -n1 -P "$WORKERS" bash -c '
  set -e
  input="$1"
  base="$(basename "$input")"
  name="${base%.*}"
  ext="${base##*.}"
  output="$WORK_DIR/output/${name}_4x.${ext}"
  log="$WORK_DIR/logs/${name}.log"
  echo "[$$] Iniciando: $base"
  if "$SCRIPT_DIR/run-video2x.sh" "$input" "$output" > >(tee -a "$log") 2>&1; then
    echo "[$$] Terminado OK: $base"
  else
    rc=$?
    echo "[$$] ERROR ($rc): $base" >&2
    rm -f "$output"
    exit "$rc"
  fi
' _
RC=$?
set -e

if (( RC != 0 )); then
  echo "La cola terminó con uno o más errores (código $RC). Revisa $WORK_DIR/logs/." >&2
  exit "$RC"
fi

echo 'Cola terminada correctamente.'
