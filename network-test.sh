#!/usr/bin/env bash
set -euo pipefail

FAIL=0

echo '== GPU =='
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader
else
  echo 'FAIL: nvidia-smi no disponible.'
  FAIL=1
fi

echo
echo '== NVIDIA Vulkan runtime =='
if ldconfig -p 2>/dev/null | grep -Eq 'lib(GLX|EGL)_nvidia\.so'; then
  ldconfig -p | grep -E 'lib(GLX|EGL)_nvidia\.so' | head -4
else
  echo 'FAIL: no aparecen libGLX_nvidia.so/libEGL_nvidia.so en el contenedor.'
  FAIL=1
fi

if compgen -G '/etc/vulkan/icd.d/*nvidia*.json' >/dev/null || \
   compgen -G '/usr/share/vulkan/icd.d/*nvidia*.json' >/dev/null; then
  echo 'ICD NVIDIA encontrado:'
  find /etc/vulkan/icd.d /usr/share/vulkan/icd.d -maxdepth 1 -type f -iname '*nvidia*.json' 2>/dev/null || true
else
  echo 'FAIL: no se encontró un ICD JSON de NVIDIA para Vulkan.'
  FAIL=1
fi

echo
echo '== Vulkan =='
if ! command -v vulkaninfo >/dev/null 2>&1; then
  echo 'vulkaninfo no está instalado; instalando vulkan-tools para validar la instancia...'
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vulkan-tools >/dev/null
fi

VK_SUMMARY="$(vulkaninfo --summary 2>&1 || true)"
echo "$VK_SUMMARY" | sed -n '/Devices:/,$p' | head -24
if echo "$VK_SUMMARY" | grep -qiE 'deviceName.*NVIDIA|NVIDIA GeForce RTX'; then
  echo 'PASS: Vulkan detecta la GPU NVIDIA.'
else
  echo 'FAIL: Vulkan NO detecta la GPU NVIDIA. Descarta esta instancia antes de bootstrap/procesamiento.'
  FAIL=1
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

if (( FAIL != 0 )); then
  echo
echo 'RESULTADO: NO APTA para Video2X Real-ESRGAN/Vulkan.'
  exit 2
fi

echo
echo 'RESULTADO: APTA para continuar con bootstrap.sh (falta validar SCP desde tu PC).'
