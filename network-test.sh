#!/usr/bin/env bash
set -euo pipefail

FAIL=0
EXPECTED_GPUS="${EXPECTED_GPUS:-0}"

echo '== GPU NVIDIA =='
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader
else
  echo 'FAIL: nvidia-smi no disponible.'
  exit 2
fi

NVIDIA_GPU_COUNT="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l | tr -d ' ')"
echo "GPUs NVIDIA detectadas por nvidia-smi: $NVIDIA_GPU_COUNT"

if [[ "$EXPECTED_GPUS" =~ ^[0-9]+$ ]] && (( EXPECTED_GPUS > 0 )) && (( NVIDIA_GPU_COUNT != EXPECTED_GPUS )); then
  echo "FAIL: se esperaban $EXPECTED_GPUS GPU(s), pero nvidia-smi detectó $NVIDIA_GPU_COUNT."
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

if (( FAIL != 0 )); then
  echo
echo 'RESULTADO: NO APTA para Video2X Real-ESRGAN/Vulkan.'
  echo 'No ejecutes bootstrap.sh ni subas videos todavía.'
  exit 2
fi

echo
echo '== Vulkan =='
if ! command -v vulkaninfo >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    echo 'vulkaninfo no está instalado; instalando vulkan-tools para validar la instancia...'
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vulkan-tools >/dev/null
  else
    echo 'FAIL: vulkaninfo no está instalado y este sistema no usa apt-get.'
    echo 'Instala vulkan-tools con el gestor de paquetes de tu distribución y repite la prueba.'
    exit 2
  fi
fi

VK_SUMMARY="$(vulkaninfo --summary 2>&1 || true)"
echo "$VK_SUMMARY" | sed -n '/Devices:/,$p' | head -80

VULKAN_NVIDIA_COUNT="$(printf '%s\n' "$VK_SUMMARY" | grep -ciE 'deviceName.*NVIDIA|deviceName.*GeForce RTX' || true)"
echo "GPUs NVIDIA detectadas por Vulkan: $VULKAN_NVIDIA_COUNT"

if (( VULKAN_NVIDIA_COUNT < 1 )); then
  echo 'FAIL: Vulkan NO detecta ninguna GPU NVIDIA.'
  exit 2
fi

if (( VULKAN_NVIDIA_COUNT < NVIDIA_GPU_COUNT )); then
  echo "FAIL: nvidia-smi ve $NVIDIA_GPU_COUNT GPU(s), pero Vulkan solo ve $VULKAN_NVIDIA_COUNT."
  echo 'Para una instancia multi-GPU necesitamos que Vulkan exponga todas las GPUs que se usarán.'
  exit 2
fi

if [[ "$EXPECTED_GPUS" =~ ^[0-9]+$ ]] && (( EXPECTED_GPUS > 0 )) && (( VULKAN_NVIDIA_COUNT < EXPECTED_GPUS )); then
  echo "FAIL: se esperaban $EXPECTED_GPUS GPU(s) disponibles en Vulkan."
  exit 2
fi

echo "PASS: Vulkan detecta correctamente $VULKAN_NVIDIA_COUNT GPU(s) NVIDIA."

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
echo 'IMPORTANTE: este test no mide la ruta PC -> servidor.'
echo 'Haz un SCP de ~100 MB desde tu PC antes de quedarte con la instancia.'
echo
echo "RESULTADO: APTA con $VULKAN_NVIDIA_COUNT GPU(s) NVIDIA para continuar con bootstrap.sh."
