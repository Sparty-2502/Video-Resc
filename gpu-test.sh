#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/workspace/video2x-custom}"
EXPECTED_GPUS="${EXPECTED_GPUS:-0}"
VIDEO2X_BIN="${VIDEO2X_BIN:-$INSTALL_DIR/bin/video2x}"
ENV_FILE="${ENV_FILE:-$INSTALL_DIR/env.sh}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [[ ! -x "$VIDEO2X_BIN" ]]; then
  echo "ERROR: no se encontró Video2X en $VIDEO2X_BIN" >&2
  exit 2
fi

echo '== nvidia-smi =='
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader
NVIDIA_COUNT="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l | tr -d ' ')"

echo
echo '== Vulkan =='
VK_SUMMARY="$(vulkaninfo --summary 2>&1 || true)"
echo "$VK_SUMMARY" | sed -n '/Devices:/,$p' | head -80
VULKAN_COUNT="$(printf '%s\n' "$VK_SUMMARY" | grep -ciE 'deviceName.*NVIDIA|deviceName.*GeForce RTX' || true)"

echo
echo '== Video2X -l =='
GPU_LIST="$($VIDEO2X_BIN -l 2>&1 || true)"
echo "$GPU_LIST"
VIDEO2X_COUNT="$(printf '%s\n' "$GPU_LIST" | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p' | wc -l | tr -d ' ')"

echo
echo '== Resumen =='
echo "nvidia-smi: $NVIDIA_COUNT GPU(s)"
echo "Vulkan:     $VULKAN_COUNT GPU(s) NVIDIA"
echo "Video2X:    $VIDEO2X_COUNT dispositivo(s) Vulkan"

if (( NVIDIA_COUNT < 1 || VULKAN_COUNT < 1 || VIDEO2X_COUNT < 1 )); then
  echo 'FAIL: el entorno no tiene una GPU utilizable por Video2X.' >&2
  exit 2
fi

if (( VULKAN_COUNT < NVIDIA_COUNT || VIDEO2X_COUNT < NVIDIA_COUNT )); then
  echo 'FAIL: no todas las GPUs visibles por nvidia-smi están expuestas a Vulkan/Video2X.' >&2
  exit 2
fi

if [[ "$EXPECTED_GPUS" =~ ^[0-9]+$ ]] && (( EXPECTED_GPUS > 0 )); then
  if (( NVIDIA_COUNT != EXPECTED_GPUS || VULKAN_COUNT < EXPECTED_GPUS || VIDEO2X_COUNT < EXPECTED_GPUS )); then
    echo "FAIL: se esperaban $EXPECTED_GPUS GPU(s) completamente utilizables." >&2
    exit 2
  fi
fi

echo 'PASS: todas las GPUs NVIDIA visibles están disponibles para Video2X.'
echo
if (( VIDEO2X_COUNT == 1 )); then
  echo 'Producción recomendada inicial:'
  echo '  WORKERS_PER_GPU=3 ./run-workers.sh'
else
  echo 'Producción multi-GPU recomendada inicial:'
  echo '  GPUS=auto WORKERS_PER_GPU=3 ./run-workers.sh'
  echo "  Concurrencia total esperada: $((VIDEO2X_COUNT * 3)) workers"
fi
