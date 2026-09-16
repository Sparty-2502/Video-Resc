#!/usr/bin/env bash
set -euo pipefail

echo '== GPU =='
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader || echo 'nvidia-smi no disponible'

echo
echo '== Vulkan =='
if command -v vulkaninfo >/dev/null 2>&1; then
  vulkaninfo --summary 2>/dev/null | sed -n '/Devices:/,$p' | head -20
else
  echo 'vulkaninfo no instalado (bootstrap.sh lo instalará).'
fi

echo
echo '== Descarga GitHub =='
URL='https://github.com/k4yt3x/video2x/archive/refs/tags/6.4.0.tar.gz'
SPEED=$(curl -L -o /dev/null -s -w '%{speed_download}' "$URL" || true)
if [[ -n "${SPEED:-}" && "$SPEED" != "0" ]]; then
  awk -v s="$SPEED" 'BEGIN {printf "%.2f MB/s\n", s/1024/1024}'
else
  echo 'No se pudo medir.'
fi

echo
echo 'IMPORTANTE: este test no mide la ruta PC -> Vast.'
echo 'Haz un SCP de ~100 MB desde tu PC antes de quedarte con la instancia.'
