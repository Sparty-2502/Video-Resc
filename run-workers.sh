#!/usr/bin/env bash
set -euo pipefail

WORKERS="${WORKERS:-3}"
WORK_DIR="${WORK_DIR:-/workspace/video2x}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$WORK_DIR/input" "$WORK_DIR/output" "$WORK_DIR/logs"

shopt -s nullglob
FILES=("$WORK_DIR/input"/*.{mp4,mkv,avi,mov,webm,m4v})
shopt -u nullglob

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No hay videos en $WORK_DIR/input"
  exit 0
fi

echo "Videos encontrados: ${#FILES[@]}"
echo "Workers: $WORKERS"

printf '%s\n' "${FILES[@]}" | xargs -0 2>/dev/null || true

export SCRIPT_DIR WORK_DIR
printf '%s\0' "${FILES[@]}" | xargs -0 -n1 -P "$WORKERS" bash -c '
  input="$1"
  base="$(basename "$input")"
  name="${base%.*}"
  ext="${base##*.}"
  output="$WORK_DIR/output/${name}_4x.${ext}"
  echo "[$$] Iniciando: $base"
  "$SCRIPT_DIR/run-video2x.sh" "$input" "$output"
  echo "[$$] Terminado: $base"
' _

echo 'Cola terminada.'
