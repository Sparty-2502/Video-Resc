#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${WORK_DIR:-/workspace/video2x}"
WORKERS_PER_GPU="${WORKERS_PER_GPU:-3}"
GPUS="${GPUS:-auto}"
BATCH_SIZE="${BATCH_SIZE:-3}"
PREFETCH_SIZE="${PREFETCH_SIZE:-$BATCH_SIZE}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/workspace/rclone.conf}"
DRIVE_INPUT_DIR="${DRIVE_INPUT_DIR:-Video2X/DXD/incoming}"
DRIVE_OUTPUT_DIR="${DRIVE_OUTPUT_DIR:-Video2X/DXD/output}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-4}"
CLEAN_LOCAL_AFTER_UPLOAD="${CLEAN_LOCAL_AFTER_UPLOAD:-1}"

if ! [[ "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: BATCH_SIZE debe ser un entero mayor a 0." >&2
  exit 2
fi
if ! [[ "$PREFETCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: PREFETCH_SIZE debe ser un entero mayor a 0." >&2
  exit 2
fi

if ! command -v rclone >/dev/null 2>&1; then
  echo 'ERROR: rclone no está instalado. Ejecuta bootstrap.sh.' >&2
  exit 2
fi

if [[ ! -x "$SCRIPT_DIR/run-workers.sh" ]]; then
  echo "ERROR: falta $SCRIPT_DIR/run-workers.sh" >&2
  exit 2
fi

mkdir -p "$WORK_DIR/input" "$WORK_DIR/output" "$WORK_DIR/processing" "$WORK_DIR/logs" "$WORK_DIR/prefetch"
PREFETCH_DIR="$WORK_DIR/prefetch"
PREFETCH_LOG="$WORK_DIR/logs/drive-prefetch.log"

RCLONE_ARGS=()
if [[ -f "$RCLONE_CONFIG_FILE" ]]; then
  RCLONE_ARGS+=(--config "$RCLONE_CONFIG_FILE")
fi

if ! rclone "${RCLONE_ARGS[@]}" listremotes | grep -qx "${RCLONE_REMOTE}:"; then
  echo "ERROR: no existe el remote '${RCLONE_REMOTE}:' en rclone." >&2
  echo "Config esperada: $RCLONE_CONFIG_FILE" >&2
  exit 2
fi

REMOTE_IN="${RCLONE_REMOTE}:${DRIVE_INPUT_DIR}"
REMOTE_OUT="${RCLONE_REMOTE}:${DRIVE_OUTPUT_DIR}"

is_video_name() {
  case "${1,,}" in
    *.mp4|*.mkv|*.avi|*.mov|*.webm|*.m4v) return 0 ;;
    *) return 1 ;;
  esac
}

expected_output_name() {
  local f="$1"
  local base="${f%.*}"
  local ext="${f##*.}"
  printf '%s_4x.%s\n' "$base" "$ext"
}

remote_output_exists() {
  local out="$1"
  rclone "${RCLONE_ARGS[@]}" lsjson "$REMOTE_OUT/$out" --stat >/dev/null 2>&1
}

validate_video() {
  local file="$1"
  [[ -s "$file" ]] || return 1
  if command -v ffprobe >/dev/null 2>&1; then
    ffprobe -v error "$file" >/dev/null 2>&1
  fi
}

download_input() {
  local file="$1"
  local target_dir="$2"
  local target="$target_dir/$file"
  local tmp="$target.part"

  mkdir -p "$target_dir"

  if validate_video "$target"; then
    echo "Ya descargado y válido: $file"
    return 0
  fi

  rm -f -- "$target" "$tmp"
  echo "Descargando: $file"
  rclone "${RCLONE_ARGS[@]}" copyto "$REMOTE_IN/$file" "$tmp" \
    --transfers 1 \
    --checkers "$RCLONE_CHECKERS" \
    --progress

  if ! validate_video "$tmp"; then
    echo "ERROR: ffprobe rechazó el input descargado: $file" >&2
    rm -f -- "$tmp"
    return 1
  fi

  mv -f -- "$tmp" "$target"
}

prefetch_batch() {
  local files=("$@")
  : > "$PREFETCH_LOG"
  {
    echo "[$(date '+%F %T')] Prefetch iniciado (${#files[@]} archivo(s))"
    for file in "${files[@]}"; do
      echo "[$(date '+%F %T')] Prefetch: $file"
      download_input "$file" "$PREFETCH_DIR"
    done
    echo "[$(date '+%F %T')] Prefetch terminado"
  } >> "$PREFETCH_LOG" 2>&1
}

stage_current_batch() {
  local files=("$@")

  find "$WORK_DIR/input" -maxdepth 1 -type f -delete

  for file in "${files[@]}"; do
    if validate_video "$PREFETCH_DIR/$file"; then
      echo "Usando prefetched: $file"
      mv -f -- "$PREFETCH_DIR/$file" "$WORK_DIR/input/$file"
    else
      rm -f -- "$PREFETCH_DIR/$file" "$PREFETCH_DIR/$file.part"
      download_input "$file" "$WORK_DIR/input"
    fi
  done
}

upload_output_to_drive() {
  local input_name="$1"
  local output_name
  output_name="$(expected_output_name "$input_name")"
  local local_output="$WORK_DIR/output/$output_name"

  if ! validate_video "$local_output"; then
    echo "ERROR: no existe salida local válida: $local_output" >&2
    return 1
  fi

  echo "Subiendo a Drive: $output_name"
  rclone "${RCLONE_ARGS[@]}" copyto "$local_output" "$REMOTE_OUT/$output_name" \
    --transfers 1 \
    --checkers "$RCLONE_CHECKERS" \
    --progress

  local local_size remote_size
  local_size="$(stat -c '%s' "$local_output")"
  remote_size="$(rclone "${RCLONE_ARGS[@]}" lsjson "$REMOTE_OUT/$output_name" --stat | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Size",0))')"

  if [[ "$remote_size" != "$local_size" ]]; then
    echo "ERROR: tamaño remoto ($remote_size) != local ($local_size): $output_name" >&2
    return 1
  fi

  echo "Upload verificado: $output_name"

  if [[ "$CLEAN_LOCAL_AFTER_UPLOAD" == "1" ]]; then
    rm -f -- "$local_output" "$WORK_DIR/input/$input_name"
    echo "Limpieza local OK: $input_name / $output_name"
  fi
}

cleanup_prefetch_pid=""
cleanup() {
  if [[ -n "$cleanup_prefetch_pid" ]] && kill -0 "$cleanup_prefetch_pid" 2>/dev/null; then
    kill "$cleanup_prefetch_pid" 2>/dev/null || true
    wait "$cleanup_prefetch_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

echo '=== Video2X Drive Queue + Prefetch ==='
echo "Remote entrada: $REMOTE_IN"
echo "Remote salida:  $REMOTE_OUT"
echo "Work dir:       $WORK_DIR"
echo "Batch size:     $BATCH_SIZE"
echo "Prefetch size:  $PREFETCH_SIZE"
echo "Workers/GPU:    $WORKERS_PER_GPU"
echo "GPUs:           $GPUS"
echo "Limpiar local:  $CLEAN_LOCAL_AFTER_UPLOAD"
echo "Prefetch log:   $PREFETCH_LOG"
echo

while true; do
  echo '== Escaneando Drive =='

  mapfile -t ALL_REMOTE < <(
    rclone "${RCLONE_ARGS[@]}" lsf "$REMOTE_IN" --files-only | sort
  )

  PENDING=()
  for file in "${ALL_REMOTE[@]}"; do
    [[ -z "$file" ]] && continue
    is_video_name "$file" || continue
    out="$(expected_output_name "$file")"
    if remote_output_exists "$out"; then
      echo "SKIP remoto terminado: $file -> $out"
    else
      PENDING+=("$file")
    fi
  done

  if [[ ${#PENDING[@]} -eq 0 ]]; then
    echo 'No quedan episodios pendientes en Drive.'
    break
  fi

  BATCH=("${PENDING[@]:0:BATCH_SIZE}")
  NEXT_BATCH=("${PENDING[@]:BATCH_SIZE:PREFETCH_SIZE}")

  echo "Pendientes totales: ${#PENDING[@]}"
  echo "Tanda actual (${#BATCH[@]}):"
  printf '  - %s\n' "${BATCH[@]}"

  stage_current_batch "${BATCH[@]}"

  cleanup_prefetch_pid=""
  if [[ ${#NEXT_BATCH[@]} -gt 0 ]]; then
    echo
    echo "Prefetch siguiente tanda (${#NEXT_BATCH[@]}) en segundo plano:"
    printf '  - %s\n' "${NEXT_BATCH[@]}"
    echo "Progreso detallado: tail -f '$PREFETCH_LOG'"
    prefetch_batch "${NEXT_BATCH[@]}" &
    cleanup_prefetch_pid=$!
    echo "Prefetch PID: $cleanup_prefetch_pid"
  fi

  echo
  echo '== Procesando tanda =='
  GPUS="$GPUS" WORKERS_PER_GPU="$WORKERS_PER_GPU" WORK_DIR="$WORK_DIR" \
    "$SCRIPT_DIR/run-workers.sh"

  echo
  echo '== Subiendo resultados =='
  for file in "${BATCH[@]}"; do
    upload_output_to_drive "$file"
  done

  if [[ -n "$cleanup_prefetch_pid" ]]; then
    if kill -0 "$cleanup_prefetch_pid" 2>/dev/null; then
      echo
      echo 'Esperando a que termine el prefetch...'
    fi
    if ! wait "$cleanup_prefetch_pid"; then
      echo "ERROR: falló el prefetch. Revisa $PREFETCH_LOG" >&2
      exit 1
    fi
    cleanup_prefetch_pid=""
    echo 'Prefetch listo para la siguiente tanda.'
  fi

  echo
  echo 'Tanda completada. Continuando sin esperar nuevas descargas...'
  echo
done

echo 'Cola de Drive terminada correctamente.'
