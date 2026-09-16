#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_GPUS="${EXPECTED_GPUS:-1}"
REQUIRED_GPU_REGEX="${REQUIRED_GPU_REGEX:-RTX 4090}"
INSTALL_DIR="${INSTALL_DIR:-/workspace/video2x-custom}"
WORK_DIR="${WORK_DIR:-/workspace/video2x}"
VIDEO2X_BIN="${VIDEO2X_BIN:-$INSTALL_DIR/bin/video2x}"
AUTO_BOOTSTRAP="${AUTO_BOOTSTRAP:-0}"
TILE_SIZE="${TILE_SIZE:-1024}"
BENCHMARK_SECONDS="${BENCHMARK_SECONDS:-120}"
BENCHMARK_INPUT="${BENCHMARK_INPUT:-}"
BENCHMARK_REMOTE="${BENCHMARK_REMOTE:-}"
RCLONE_CONFIG_FILE="${RCLONE_CONFIG_FILE:-/workspace/rclone.conf}"
GPU_ID="${GPU_ID:-0}"
MODEL="${MODEL:-realesr-animevideov3}"
SCALE="${SCALE:-4}"
EXPECTED_WIDTH="${EXPECTED_WIDTH:-1280}"
EXPECTED_HEIGHT="${EXPECTED_HEIGHT:-720}"
MIN_VIDEO2X_FPS="${MIN_VIDEO2X_FPS:-5.0}"
EXCELLENT_VIDEO2X_FPS="${EXCELLENT_VIDEO2X_FPS:-6.0}"
MIN_DRIVE_MIB_S="${MIN_DRIVE_MIB_S:-2.0}"
MIN_SERVER_NET_MBIT="${MIN_SERVER_NET_MBIT:-50}"

FAIL=0
INCOMPLETE=0
TMP_ROOT="${TMPDIR:-/tmp}/video2x-host-qualification.$$"
GPU_MON_PID=""
DOWNLOADED_BENCHMARK=0
mkdir -p "$TMP_ROOT" "$WORK_DIR/benchmark"

cleanup() {
  if [[ -n "${GPU_MON_PID:-}" ]] && kill -0 "$GPU_MON_PID" 2>/dev/null; then
    kill "$GPU_MON_PID" 2>/dev/null || true
    wait "$GPU_MON_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

pass() { printf 'PASS  %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAIL=1; }
info() { printf 'INFO  %s\n' "$*"; }

num_ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a+0 >= b+0) }'; }

printf '%s\n' '============================================================'
printf '%s\n' ' Video2X Host Qualification'
printf '%s\n' '============================================================'
echo "Expected GPUs:       $EXPECTED_GPUS"
echo "Required GPU regex:  ${REQUIRED_GPU_REGEX:-<any>}"
echo "Video2X min FPS:     $MIN_VIDEO2X_FPS"
echo "Benchmark duration:  ${BENCHMARK_SECONDS}s"
echo "Benchmark expected:  ${EXPECTED_WIDTH}x${EXPECTED_HEIGHT}"
echo

# ---------------------------------------------------------------------------
# 1. GPU / driver / power
# ---------------------------------------------------------------------------
echo '== 1. GPU / Driver =='
if ! command -v nvidia-smi >/dev/null 2>&1; then
  fail 'nvidia-smi no está disponible.'
else
  GPU_CSV="$(nvidia-smi --query-gpu=index,name,memory.total,driver_version,power.limit --format=csv,noheader,nounits 2>&1 || true)"
  echo "$GPU_CSV"
  GPU_COUNT="$(printf '%s\n' "$GPU_CSV" | grep -c '^[0-9]' || true)"

  if [[ "$GPU_COUNT" == "$EXPECTED_GPUS" ]]; then
    pass "$GPU_COUNT GPU(s) NVIDIA visibles."
  else
    fail "Se esperaban $EXPECTED_GPUS GPU(s), nvidia-smi reporta $GPU_COUNT."
  fi

  if [[ -n "$REQUIRED_GPU_REGEX" ]]; then
    MATCHED="$(printf '%s\n' "$GPU_CSV" | grep -Ec "$REQUIRED_GPU_REGEX" || true)"
    if (( MATCHED >= EXPECTED_GPUS )); then
      pass "GPU coincide con /$REQUIRED_GPU_REGEX/."
    else
      fail "La GPU anunciada no coincide con /$REQUIRED_GPU_REGEX/."
    fi
  fi
fi

echo

# ---------------------------------------------------------------------------
# 2. Recursos base
# ---------------------------------------------------------------------------
echo '== 2. CPU / RAM / Disco =='
CPU_COUNT="$(nproc 2>/dev/null || echo 0)"
RAM_GIB="$(free -b 2>/dev/null | awk '/^Mem:/ {printf "%.1f", $2/1024/1024/1024}' || echo 0)"
DISK_AVAIL_GIB="$(df -B1 "$WORK_DIR" 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024/1024}' || true)"
if [[ -z "$DISK_AVAIL_GIB" ]]; then
  DISK_AVAIL_GIB="$(df -B1 /workspace 2>/dev/null | awk 'NR==2 {printf "%.1f", $4/1024/1024/1024}' || echo 0)"
fi

echo "CPU threads:  $CPU_COUNT"
echo "RAM total:    ${RAM_GIB} GiB"
echo "Disk free:    ${DISK_AVAIL_GIB} GiB"

if (( CPU_COUNT >= 8 )); then pass 'CPU base suficiente.'; else warn 'Menos de 8 hilos CPU.'; fi
if num_ge "$RAM_GIB" 16; then pass 'RAM base suficiente.'; else fail 'Menos de 16 GiB RAM.'; fi
if num_ge "$DISK_AVAIL_GIB" 12; then pass 'Espacio libre mínimo disponible.'; else fail 'Menos de 12 GiB libres para benchmark/producción.'; fi

echo

# ---------------------------------------------------------------------------
# 3. Vulkan preflight
# ---------------------------------------------------------------------------
echo '== 3. Vulkan preflight =='
if [[ -x "$SCRIPT_DIR/network-test.sh" ]]; then
  set +e
  EXPECTED_GPUS="$EXPECTED_GPUS" "$SCRIPT_DIR/network-test.sh"
  PRE_RC=$?
  set -e
  if (( PRE_RC == 0 )); then
    pass 'nvidia-smi + Vulkan preflight.'
  else
    fail "network-test.sh falló (rc=$PRE_RC)."
  fi
else
  fail 'No existe network-test.sh.'
fi

echo

# ---------------------------------------------------------------------------
# 4. Red del servidor (orientativa)
# ---------------------------------------------------------------------------
echo '== 4. Red del servidor =='
SERVER_DL=""
SERVER_UL=""
if ! command -v speedtest-cli >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    echo 'Instalando speedtest-cli para prueba orientativa...'
    apt-get update -qq >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq speedtest-cli >/dev/null 2>&1 || true
  fi
fi

if command -v speedtest-cli >/dev/null 2>&1; then
  SPEEDTEST_OUT="$(speedtest-cli --simple 2>&1 || true)"
  echo "$SPEEDTEST_OUT"
  SERVER_DL="$(printf '%s\n' "$SPEEDTEST_OUT" | awk '/Download:/ {print $2; exit}')"
  SERVER_UL="$(printf '%s\n' "$SPEEDTEST_OUT" | awk '/Upload:/ {print $2; exit}')"
  if [[ -n "$SERVER_DL" && -n "$SERVER_UL" ]]; then
    if num_ge "$SERVER_DL" "$MIN_SERVER_NET_MBIT" && num_ge "$SERVER_UL" "$MIN_SERVER_NET_MBIT"; then
      pass "Speedtest >= ${MIN_SERVER_NET_MBIT} Mbit/s en ambos sentidos."
    else
      warn "Speedtest por debajo de ${MIN_SERVER_NET_MBIT} Mbit/s; es orientativo. Drive/transferencia real decide."
    fi
  else
    warn 'speedtest-cli no devolvió métricas utilizables.'
  fi
else
  warn 'speedtest-cli no disponible.'
fi

echo

# No gastamos tiempo compilando una instancia que ya falló lo básico.
if (( FAIL != 0 )); then
  echo 'RESULTADO PRELIMINAR: DESCARTAR HOST'
  echo 'Falló una validación barata antes del benchmark Video2X.'
  exit 2
fi

# ---------------------------------------------------------------------------
# 5. Build / Video2X
# ---------------------------------------------------------------------------
echo '== 5. Video2X build =='
if [[ ! -x "$VIDEO2X_BIN" ]]; then
  if [[ "$AUTO_BOOTSTRAP" == "1" ]]; then
    info 'Video2X no está instalado. AUTO_BOOTSTRAP=1: compilando...'
    if EXPECTED_GPUS="$EXPECTED_GPUS" TILE_SIZE="$TILE_SIZE" "$SCRIPT_DIR/bootstrap.sh"; then
      pass 'bootstrap.sh terminó correctamente.'
    else
      fail 'bootstrap.sh falló.'
    fi
  else
    warn "Video2X no está instalado en $VIDEO2X_BIN."
    echo 'Para continuar automáticamente:'
    echo '  AUTO_BOOTSTRAP=1 BENCHMARK_REMOTE="gdrive:ruta/video.mp4" ./host-qualification.sh'
    echo 'O ejecuta bootstrap.sh y vuelve a lanzar este script.'
    INCOMPLETE=1
  fi
fi

if (( FAIL != 0 )); then
  echo 'RESULTADO: DESCARTAR HOST'
  exit 2
fi
if (( INCOMPLETE != 0 )); then
  echo 'RESULTADO: PREFLIGHT APROBADO; FALTA BENCHMARK VIDEO2X'
  exit 3
fi

export LD_LIBRARY_PATH="$INSTALL_DIR/lib:${LD_LIBRARY_PATH:-}"
GPU_LIST="$("$VIDEO2X_BIN" -l 2>&1 || true)"
echo "$GPU_LIST"
VIDEO2X_GPU_COUNT="$(printf '%s\n' "$GPU_LIST" | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p' | wc -l | tr -d ' ')"
if (( VIDEO2X_GPU_COUNT >= EXPECTED_GPUS )); then
  pass "Video2X ve $VIDEO2X_GPU_COUNT dispositivo(s) Vulkan."
else
  fail "Video2X ve $VIDEO2X_GPU_COUNT, se esperaban $EXPECTED_GPUS."
fi

echo
if (( FAIL != 0 )); then
  echo 'RESULTADO: DESCARTAR HOST'
  exit 2
fi

# ---------------------------------------------------------------------------
# 6. Adquirir input de benchmark
# ---------------------------------------------------------------------------
echo '== 6. Input benchmark =='
BENCH_FILE=""
DRIVE_SPEED=""

if [[ -n "$BENCHMARK_INPUT" && -f "$BENCHMARK_INPUT" ]]; then
  BENCH_FILE="$BENCHMARK_INPUT"
  pass "Benchmark local: $BENCH_FILE"
elif [[ -n "$BENCHMARK_REMOTE" ]]; then
  if ! command -v rclone >/dev/null 2>&1; then
    fail 'BENCHMARK_REMOTE requiere rclone.'
  else
    RCLONE_ARGS=()
    if [[ -f "$RCLONE_CONFIG_FILE" ]]; then
      RCLONE_ARGS+=(--config "$RCLONE_CONFIG_FILE")
    fi

    EXT="${BENCHMARK_REMOTE##*.}"
    [[ "$EXT" == "$BENCHMARK_REMOTE" ]] && EXT="mp4"
    BENCH_FILE="$WORK_DIR/benchmark/host-qualification-input.$EXT"
    rm -f -- "$BENCH_FILE"

    echo "Descargando benchmark: $BENCHMARK_REMOTE"
    START_NS="$(date +%s%N)"
    if rclone "${RCLONE_ARGS[@]}" copyto "$BENCHMARK_REMOTE" "$BENCH_FILE" --transfers 1 --checkers 2 --progress; then
      END_NS="$(date +%s%N)"
      SIZE_BYTES="$(stat -c '%s' "$BENCH_FILE")"
      DRIVE_SPEED="$(awk -v b="$SIZE_BYTES" -v a="$START_NS" -v z="$END_NS" 'BEGIN {s=(z-a)/1000000000; if (s>0) printf "%.2f", b/s/1024/1024; else print 0}')"
      echo "Drive -> host: ${DRIVE_SPEED} MiB/s"
      if num_ge "$DRIVE_SPEED" "$MIN_DRIVE_MIB_S"; then
        pass "Drive >= ${MIN_DRIVE_MIB_S} MiB/s."
      else
        fail "Drive demasiado lento (${DRIVE_SPEED} MiB/s < ${MIN_DRIVE_MIB_S})."
      fi
      DOWNLOADED_BENCHMARK=1
    else
      fail 'No se pudo descargar BENCHMARK_REMOTE.'
    fi
  fi
else
  # Conveniencia: si ya hay un input, usar el primero.
  shopt -s nullglob
  EXISTING=("$WORK_DIR/input"/*.{mp4,mkv,avi,mov,webm,m4v})
  shopt -u nullglob
  if [[ ${#EXISTING[@]} -gt 0 ]]; then
    BENCH_FILE="${EXISTING[0]}"
    warn "BENCHMARK_INPUT/REMOTE no indicado; usando ${BENCH_FILE}."
  else
    warn 'No hay archivo de benchmark.'
    echo 'Ejemplo con Drive:'
    echo '  BENCHMARK_REMOTE="gdrive:Video2X/DXD/2temp/episodio.mp4" ./host-qualification.sh'
    INCOMPLETE=1
  fi
fi

if (( FAIL != 0 )); then
  echo 'RESULTADO: DESCARTAR HOST'
  exit 2
fi
if (( INCOMPLETE != 0 )); then
  echo 'RESULTADO: HOST BASE APROBADO; FALTA INPUT PARA BENCHMARK'
  exit 3
fi

if command -v ffprobe >/dev/null 2>&1; then
  RES="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0:s=x "$BENCH_FILE" 2>/dev/null | head -1)"
  echo "Resolución benchmark: ${RES:-desconocida}"
  if [[ "$RES" == "${EXPECTED_WIDTH}x${EXPECTED_HEIGHT}" ]]; then
    pass "Benchmark comparable (${EXPECTED_WIDTH}x${EXPECTED_HEIGHT})."
  else
    fail "Benchmark no comparable: ${RES:-?}; esperado ${EXPECTED_WIDTH}x${EXPECTED_HEIGHT}."
  fi
else
  warn 'ffprobe no disponible; no se pudo validar resolución.'
fi

echo
if (( FAIL != 0 )); then
  echo 'RESULTADO: DESCARTAR/REPETIR CON INPUT COMPARABLE'
  exit 2
fi

# ---------------------------------------------------------------------------
# 7. Benchmark real Video2X (1 worker)
# ---------------------------------------------------------------------------
echo '== 7. Benchmark Video2X real =='
BENCH_OUT="$WORK_DIR/benchmark/host-qualification-output.mp4"
BENCH_LOG="$WORK_DIR/benchmark/host-qualification-video2x.log"
GPU_LOG="$WORK_DIR/benchmark/host-qualification-gpu.csv"
rm -f -- "$BENCH_OUT" "$BENCH_LOG" "$GPU_LOG"

echo "Ejecutando 1 worker durante ${BENCHMARK_SECONDS}s..."
(
  while true; do
    nvidia-smi --id="$GPU_ID" --query-gpu=utilization.gpu,power.draw,clocks.sm,memory.used --format=csv,noheader,nounits 2>/dev/null || true
    sleep 2
  done
) > "$GPU_LOG" &
GPU_MON_PID=$!

set +e
(
  cd "$INSTALL_DIR" || exit 1
  timeout --signal=INT --kill-after=10s "${BENCHMARK_SECONDS}s" \
    "$VIDEO2X_BIN" \
      -i "$BENCH_FILE" \
      -o "$BENCH_OUT" \
      -s "$SCALE" \
      -p realesrgan \
      --realesrgan-model "$MODEL" \
      -d "$GPU_ID"
) > "$BENCH_LOG" 2>&1
BENCH_RC=$?
set -e

if kill -0 "$GPU_MON_PID" 2>/dev/null; then
  kill "$GPU_MON_PID" 2>/dev/null || true
  wait "$GPU_MON_PID" 2>/dev/null || true
fi
GPU_MON_PID=""

# timeout suele devolver 124; 0 significa que terminó antes del límite.
if [[ "$BENCH_RC" != "0" && "$BENCH_RC" != "124" && "$BENCH_RC" != "130" && "$BENCH_RC" != "137" ]]; then
  echo '--- Últimas líneas Video2X ---'
  tail -40 "$BENCH_LOG" || true
  fail "Video2X benchmark terminó con rc=$BENCH_RC."
fi

FPS_STATS="$(python3 - "$BENCH_LOG" <<'PY'
import re, statistics, sys
p=sys.argv[1]
text=open(p,'r',errors='replace').read().replace('\r','\n')
vals=[float(x) for x in re.findall(r'fps=([0-9]+(?:\.[0-9]+)?)', text)]
vals=[v for v in vals if v>0]
if not vals:
    print('0 0 0')
else:
    tail=vals[-20:]
    print(f'{statistics.mean(tail):.3f} {vals[-1]:.3f} {len(vals)}')
PY
)"
read -r AVG_FPS LAST_FPS FPS_SAMPLES <<< "$FPS_STATS"

GPU_STATS="$(awk -F',' '
  {for(i=1;i<=NF;i++) gsub(/^[ \t]+|[ \t]+$/, "", $i); if ($1 ~ /^[0-9.]+$/) {u+=$1; p+=$2; c+=$3; n++}}
  END {if(n) printf "%.1f %.1f %.0f %d",u/n,p/n,c/n,n; else print "0 0 0 0"}
' "$GPU_LOG")"
read -r AVG_GPU_UTIL AVG_POWER AVG_CLOCK GPU_SAMPLES <<< "$GPU_STATS"

echo "Video2X FPS (media últimas muestras): $AVG_FPS"
echo "Video2X FPS (última):                $LAST_FPS"
echo "GPU util media:                      ${AVG_GPU_UTIL}%"
echo "GPU power media:                     ${AVG_POWER} W"
echo "GPU clock media:                     ${AVG_CLOCK} MHz"

if num_ge "$AVG_FPS" "$EXCELLENT_VIDEO2X_FPS"; then
  pass "Video2X excelente: ${AVG_FPS} FPS >= ${EXCELLENT_VIDEO2X_FPS}."
elif num_ge "$AVG_FPS" "$MIN_VIDEO2X_FPS"; then
  pass "Video2X apto: ${AVG_FPS} FPS >= ${MIN_VIDEO2X_FPS}."
else
  fail "Video2X lento: ${AVG_FPS} FPS < ${MIN_VIDEO2X_FPS}."
fi

if num_ge "$AVG_GPU_UTIL" 50; then
  pass "GPU tuvo carga útil media (${AVG_GPU_UTIL}%)."
else
  warn "GPU util media baja (${AVG_GPU_UTIL}%); puede indicar host/pipeline problemático."
fi

rm -f -- "$BENCH_OUT"
if (( DOWNLOADED_BENCHMARK == 1 )); then
  rm -f -- "$BENCH_FILE"
fi

echo
printf '%s\n' '============================================================'
printf '%s\n' ' RESULTADO FINAL'
printf '%s\n' '============================================================'
echo "GPU(s):          ${GPU_COUNT:-?}"
echo "Server DL/UL:    ${SERVER_DL:-?}/${SERVER_UL:-?} Mbit/s"
echo "Drive -> host:   ${DRIVE_SPEED:-no medido} MiB/s"
echo "Video2X:         ${AVG_FPS:-0} FPS"
echo "GPU util media:  ${AVG_GPU_UTIL:-0}%"
echo "GPU power media: ${AVG_POWER:-0} W"

if (( FAIL == 0 )); then
  echo
  echo 'APTO PARA PRODUCCIÓN'
  echo "Sugerencia RTX 4090: WORKERS_PER_GPU=3"
  exit 0
else
  echo
  echo 'DESCARTAR HOST'
  echo 'No inicies una temporada completa en esta instancia.'
  exit 2
fi
