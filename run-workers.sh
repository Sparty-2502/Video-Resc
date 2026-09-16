#!/usr/bin/env bash
set -euo pipefail

WORKERS_PER_GPU="${WORKERS_PER_GPU:-${WORKERS:-3}}"
GPUS="${GPUS:-auto}"
WORK_DIR="${WORK_DIR:-/workspace/video2x}"
INSTALL_DIR="${INSTALL_DIR:-/workspace/video2x-custom}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$INSTALL_DIR/env.sh}"
VIDEO2X_BIN="${VIDEO2X_BIN:-$INSTALL_DIR/bin/video2x}"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

mkdir -p "$WORK_DIR/input" "$WORK_DIR/output" "$WORK_DIR/processing" "$WORK_DIR/logs"

if [[ ! -x "$VIDEO2X_BIN" ]]; then
  echo "ERROR: no se encontró Video2X ejecutable en $VIDEO2X_BIN" >&2
  echo 'Ejecuta bootstrap.sh primero.' >&2
  exit 2
fi

if ! [[ "$WORKERS_PER_GPU" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: WORKERS_PER_GPU debe ser un entero mayor a 0 (recibido: $WORKERS_PER_GPU)." >&2
  exit 2
fi

echo '== Dispositivos Vulkan visibles para Video2X =='
GPU_LIST="$($VIDEO2X_BIN -l 2>&1 || true)"
echo "$GPU_LIST"
mapfile -t AVAILABLE_GPU_IDS < <(printf '%s\n' "$GPU_LIST" | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p')

if [[ ${#AVAILABLE_GPU_IDS[@]} -eq 0 ]]; then
  echo 'ERROR: Video2X no detectó ningún dispositivo Vulkan.' >&2
  exit 2
fi

if [[ "$GPUS" == "auto" ]]; then
  GPU_IDS=("${AVAILABLE_GPU_IDS[@]}")
else
  IFS=',' read -r -a GPU_IDS <<< "$GPUS"
fi

if [[ ${#GPU_IDS[@]} -eq 0 ]]; then
  echo 'ERROR: no se seleccionó ninguna GPU.' >&2
  exit 2
fi

for gpu in "${GPU_IDS[@]}"; do
  found=0
  for available in "${AVAILABLE_GPU_IDS[@]}"; do
    if [[ "$gpu" == "$available" ]]; then
      found=1
      break
    fi
  done
  if (( found == 0 )); then
    echo "ERROR: GPU $gpu no aparece en video2x -l." >&2
    exit 2
  fi
done

TOTAL_WORKERS=$(( ${#GPU_IDS[@]} * WORKERS_PER_GPU ))
echo "GPUs seleccionadas: ${GPU_IDS[*]}"
echo "Workers por GPU: $WORKERS_PER_GPU"
echo "Concurrencia máxima total: $TOTAL_WORKERS"

shopt -s nullglob
FILES=("$WORK_DIR/input"/*.{mp4,mkv,avi,mov,webm,m4v})
shopt -u nullglob

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No hay videos en $WORK_DIR/input"
  exit 0
fi

is_valid_output() {
  local file="$1"
  [[ -s "$file" ]] || return 1
  if command -v ffprobe >/dev/null 2>&1; then
    ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" >/dev/null 2>&1
  else
    return 0
  fi
}

PENDING=()
SKIPPED=0
for input in "${FILES[@]}"; do
  base="$(basename "$input")"
  name="${base%.*}"
  ext="${base##*.}"
  final="$WORK_DIR/output/${name}_4x.${ext}"

  if is_valid_output "$final"; then
    echo "SKIP: salida válida ya existente: $(basename "$final")"
    ((SKIPPED+=1))
  else
    if [[ -e "$final" ]]; then
      echo "WARN: salida previa incompleta/no válida; se reprocesará: $(basename "$final")"
      rm -f "$final"
    fi
    PENDING+=("$input")
  fi
done

echo "Videos encontrados: ${#FILES[@]}"
echo "Ya terminados: $SKIPPED"
echo "Pendientes: ${#PENDING[@]}"

if [[ ${#PENDING[@]} -eq 0 ]]; then
  echo 'No hay trabajos pendientes.'
  exit 0
fi

declare -A ACTIVE=()
declare -A PID_GPU=()
declare -A PID_FILE=()
for gpu in "${GPU_IDS[@]}"; do
  ACTIVE[$gpu]=0
done

FAIL=0
NEXT=0

cleanup() {
  echo
  echo 'Interrupción detectada; deteniendo workers activos...' >&2
  for pid in "${!PID_GPU[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit 130
}
trap cleanup INT TERM

launch_job() {
  local input="$1"
  local gpu="$2"
  local base name ext final temp
  base="$(basename "$input")"
  name="${base%.*}"
  ext="${base##*.}"
  final="$WORK_DIR/output/${name}_4x.${ext}"
  temp="$WORK_DIR/processing/${name}_4x.${ext}"

  (
    set -e
    rm -f "$temp"
    echo "[$$] GPU $gpu -> Iniciando: $base"
    if GPU_ID="$gpu" INSTALL_DIR="$INSTALL_DIR" WORK_DIR="$WORK_DIR" \
      "$SCRIPT_DIR/run-video2x.sh" "$input" "$temp"; then
      if command -v ffprobe >/dev/null 2>&1 && ! ffprobe -v error "$temp" >/dev/null 2>&1; then
        echo "[$$] GPU $gpu -> ERROR: ffprobe no valida la salida: $base" >&2
        rm -f "$temp"
        exit 3
      fi
      mv -f "$temp" "$final"
      echo "[$$] GPU $gpu -> Terminado OK: $base"
    else
      rc=$?
      echo "[$$] GPU $gpu -> ERROR ($rc): $base" >&2
      rm -f "$temp"
      exit "$rc"
    fi
  ) &

  local pid=$!
  ACTIVE[$gpu]=$(( ACTIVE[$gpu] + 1 ))
  PID_GPU[$pid]="$gpu"
  PID_FILE[$pid]="$base"
}

reap_finished() {
  local pid gpu rc
  for pid in "${!PID_GPU[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      gpu="${PID_GPU[$pid]}"
      set +e
      wait "$pid"
      rc=$?
      set -e
      ACTIVE[$gpu]=$(( ACTIVE[$gpu] - 1 ))
      if (( rc != 0 )); then
        FAIL=1
        echo "Worker falló: ${PID_FILE[$pid]} (GPU $gpu, código $rc)" >&2
      fi
      unset "PID_GPU[$pid]"
      unset "PID_FILE[$pid]"
    fi
  done
}

while (( NEXT < ${#PENDING[@]} )) || (( ${#PID_GPU[@]} > 0 )); do
  reap_finished
  launched=0

  if (( NEXT < ${#PENDING[@]} )); then
    for gpu in "${GPU_IDS[@]}"; do
      while (( ACTIVE[$gpu] < WORKERS_PER_GPU )) && (( NEXT < ${#PENDING[@]} )); do
        launch_job "${PENDING[$NEXT]}" "$gpu"
        ((NEXT+=1))
        launched=1
      done
    done
  fi

  if (( launched == 0 )); then
    sleep 2
  fi
done

trap - INT TERM

if (( FAIL != 0 )); then
  echo "La cola terminó con uno o más errores. Revisa $WORK_DIR/logs/." >&2
  exit 1
fi

echo 'Cola terminada correctamente.'
