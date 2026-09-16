#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-status}"
WORK_DIR="${WORK_DIR:-/workspace/video2x}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/workspace/rclone.conf}"
DRIVE_INPUT_DIR="${DRIVE_INPUT_DIR:-Video2X/DXD/incoming}"
DRIVE_OUTPUT_DIR="${DRIVE_OUTPUT_DIR:-Video2X/DXD/output}"
RCLONE_TRANSFERS="${RCLONE_TRANSFERS:-2}"
RCLONE_CHECKERS="${RCLONE_CHECKERS:-4}"

mkdir -p "$WORK_DIR/input" "$WORK_DIR/output" "$WORK_DIR/processing" "$WORK_DIR/logs"

if ! command -v rclone >/dev/null 2>&1; then
  echo 'ERROR: rclone no está instalado. Ejecuta bootstrap.sh.' >&2
  exit 2
fi

RCLONE_ARGS=()
if [[ -f "$RCLONE_CONFIG_FILE" ]]; then
  RCLONE_ARGS+=(--config "$RCLONE_CONFIG_FILE")
fi

if ! rclone "${RCLONE_ARGS[@]}" listremotes | grep -qx "${RCLONE_REMOTE}:"; then
  echo "ERROR: no existe el remote '${RCLONE_REMOTE}:' en rclone." >&2
  if [[ ! -f "$RCLONE_CONFIG_FILE" ]]; then
    echo "No existe $RCLONE_CONFIG_FILE y tampoco se encontró el remote en la configuración por defecto." >&2
  fi
  exit 2
fi

remote_in="${RCLONE_REMOTE}:${DRIVE_INPUT_DIR}"
remote_out="${RCLONE_REMOTE}:${DRIVE_OUTPUT_DIR}"

case "$MODE" in
  pull)
    echo "== Drive -> input =="
    echo "Origen:  $remote_in"
    echo "Destino: $WORK_DIR/input"
    rclone "${RCLONE_ARGS[@]}" copy "$remote_in" "$WORK_DIR/input" \
      --include '*.mp4' \
      --include '*.mkv' \
      --include '*.avi' \
      --include '*.mov' \
      --include '*.webm' \
      --include '*.m4v' \
      --transfers "$RCLONE_TRANSFERS" \
      --checkers "$RCLONE_CHECKERS" \
      --progress
    ;;

  push)
    echo "== output -> Drive =="
    echo "Origen:  $WORK_DIR/output"
    echo "Destino: $remote_out"
    rclone "${RCLONE_ARGS[@]}" copy "$WORK_DIR/output" "$remote_out" \
      --include '*_4x.mp4' \
      --include '*_4x.mkv' \
      --include '*_4x.avi' \
      --include '*_4x.mov' \
      --include '*_4x.webm' \
      --include '*_4x.m4v' \
      --transfers "$RCLONE_TRANSFERS" \
      --checkers "$RCLONE_CHECKERS" \
      --progress
    ;;

  status)
    echo '== rclone =='
    rclone version | head -1
    echo
    echo "Remote: $RCLONE_REMOTE"
    echo "Entrada Drive: $remote_in"
    echo "Salida Drive:  $remote_out"
    echo "Config:        ${RCLONE_CONFIG_FILE}"
    echo
    echo '== Incoming remoto =='
    rclone "${RCLONE_ARGS[@]}" lsf "$remote_in" --files-only 2>/dev/null || true
    echo
    echo '== Output remoto =='
    rclone "${RCLONE_ARGS[@]}" lsf "$remote_out" --files-only 2>/dev/null || true
    echo
    echo '== Input local =='
    find "$WORK_DIR/input" -maxdepth 1 -type f -printf '%f\n' | sort
    echo
    echo '== Output local =='
    find "$WORK_DIR/output" -maxdepth 1 -type f -printf '%f\n' | sort
    ;;

  *)
    echo "Uso: $0 {pull|push|status}" >&2
    exit 2
    ;;
esac
