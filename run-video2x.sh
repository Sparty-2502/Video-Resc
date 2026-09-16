#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/workspace/video2x-custom}"
WORK_DIR="${WORK_DIR:-/workspace/video2x}"
MODEL="${MODEL:-realesr-animevideov3}"
SCALE="${SCALE:-4}"
GPU_ID="${GPU_ID:-0}"

if [[ $# -lt 1 ]]; then
  echo "Uso: $0 <archivo-entrada> [archivo-salida]" >&2
  exit 1
fi

INPUT="$1"
if [[ ! -f "$INPUT" ]]; then
  if [[ -f "$WORK_DIR/input/$INPUT" ]]; then
    INPUT="$WORK_DIR/input/$INPUT"
  else
    echo "No existe: $1" >&2
    exit 1
  fi
fi

BASE="$(basename "$INPUT")"
NAME="${BASE%.*}"
EXT="${BASE##*.}"
OUTPUT="${2:-$WORK_DIR/output/${NAME}_4x.${EXT}}"
LOG="$WORK_DIR/logs/${NAME}.log"

mkdir -p "$(dirname "$OUTPUT")" "$WORK_DIR/logs"
export LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"

cd "$INSTALL_DIR"

echo "Entrada:  $INPUT"
echo "Salida:   $OUTPUT"
echo "Log:      $LOG"
echo "GPU:      $GPU_ID"
echo "Modelo:   $MODEL"
echo "Escala:   ${SCALE}x"

time "$INSTALL_DIR/bin/video2x" \
  -i "$INPUT" \
  -o "$OUTPUT" \
  -s "$SCALE" \
  -p realesrgan \
  --realesrgan-model "$MODEL" \
  -g "$GPU_ID" 2>&1 | tee "$LOG"
