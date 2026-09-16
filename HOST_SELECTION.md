# Selección y calificación de hosts Vast.ai

Las especificaciones anunciadas por un marketplace cloud no garantizan el rendimiento real del workload. Para Video2X + Real-ESRGAN NCNN/Vulkan se han observado hosts con RTX 4090, CPU abundante y Vulkan funcional que, aun así, rinden muy por debajo de otros hosts aparentemente equivalentes.

Por eso este repositorio usa dos filtros: **selección visual antes de rentar** y **benchmark real después de rentar**.

## 1. Qué priorizar antes de rentar

Para una RTX 4090 individual:

- GPU: RTX 4090 24 GB.
- Verified: preferible.
- Reliability: idealmente >= 99%.
- Max duration: suficiente para toda la sesión de trabajo.
- CPU: 16+ hilos asignados es suficiente para comenzar; más CPU no garantiza más FPS.
- RAM: 32 GB o más.
- Almacenamiento: 30-50 GB libres recomendados si no se usa limpieza por lotes.
- Red anunciada: preferiblemente >= 500 Mbit/s en ambas direcciones.
- Precio: comparar contra throughput real, no solo $/h.

DLPerf, TFLOPS, CPU, RAM y la velocidad anunciada son filtros iniciales, no una garantía.

## 2. Preflight barato

Nada más rentar:

```bash
cd /workspace
git clone https://github.com/Sparty-2502/Video-Resc.git
cd Video-Resc
chmod +x *.sh
EXPECTED_GPUS=1 ./network-test.sh
```

Si falla GPU/Vulkan, descarta el host sin compilar.

## 3. Calificación automática

`host-qualification.sh` mide:

- GPU, VRAM, driver y power limit;
- cantidad de GPUs esperadas;
- CPU, RAM y disco;
- runtime Vulkan;
- speedtest del servidor (orientativo);
- visibilidad de la GPU desde Video2X;
- velocidad Drive -> host cuando se usa `BENCHMARK_REMOTE`;
- resolución del input de benchmark;
- benchmark real Video2X con **1 worker** durante un periodo corto;
- FPS promedio al final del benchmark;
- utilización, potencia y clocks medios de la GPU.

### Preflight sin compilar

```bash
EXPECTED_GPUS=1 ./host-qualification.sh
```

Si Video2X todavía no está instalado y todo lo barato pasa, termina con estado `PREFLIGHT APROBADO; FALTA BENCHMARK VIDEO2X`.

### Preflight + bootstrap + benchmark desde Drive

Una vez que `gdrive:` esté configurado en rclone:

```bash
EXPECTED_GPUS=1 \
AUTO_BOOTSTRAP=1 \
BENCHMARK_REMOTE="gdrive:Video2X/DXD/2temp/[AnimeKCD] High School DxD New 01.mp4" \
./host-qualification.sh
```

Por defecto usa:

- benchmark: 120 s;
- resolución esperada: 1280x720;
- escala: 4x;
- modelo: `realesr-animevideov3`;
- GPU: 0;
- mínimo: 5.0 FPS;
- excelente: 6.0 FPS;
- Drive mínimo: 2 MiB/s.

### Benchmark con archivo local

```bash
EXPECTED_GPUS=1 \
BENCHMARK_INPUT="/workspace/benchmark.mp4" \
./host-qualification.sh
```

## 4. Semáforo práctico RTX 4090

Con material 1280x720 y la configuración probada del repo:

| 1 worker | Decisión |
|---|---|
| >= 6.0 FPS | Excelente |
| 5.0-6.0 FPS | Apto para producción |
| 4.0-5.0 FPS | Mediocre; comparar costo |
| < 4.0 FPS | Descartar |
| ~3 FPS o menos | Descartar inmediatamente |

El umbral se puede cambiar:

```bash
MIN_VIDEO2X_FPS=5.5 ./host-qualification.sh
```

## 5. Por qué el benchmark real es obligatorio

Una RTX 4090 puede aparecer correctamente en:

```text
nvidia-smi
vulkaninfo --summary
video2x -l
```

sin rendir bien en NCNN/Vulkan. Entre hosts pueden cambiar:

- driver NVIDIA;
- virtualización y passthrough;
- límites o comportamiento de energía;
- topología PCIe/NUMA;
- CPU efectiva disponible;
- almacenamiento;
- contención con otros clientes del host;
- routing de red;
- configuración del proveedor.

Por eso el criterio definitivo es **FPS real con el mismo archivo y la misma build**, no el número anunciado por el marketplace.

## 6. Red

La prueba `speedtest-cli` del servidor es orientativa. Si se usa el pipeline con Google Drive, la métrica más útil es la descarga real del benchmark por rclone, que `host-qualification.sh` calcula automáticamente.

Si se piensa usar SCP directamente desde casa, hacer también una transferencia real de ~100 MB. La velocidad anunciada por Vast no mide la ruta concreta entre el usuario y el host.

## 7. Decisión de producción

Solo iniciar `run-workers.sh` o `run-drive-queue.sh` cuando `host-qualification.sh` termine con:

```text
APTO PARA PRODUCCIÓN
```

Si termina con:

```text
DESCARTAR HOST
```

no conviene gastar saldo intentando compensar con más workers: un host lento con 1 worker normalmente empeora al aumentar concurrencia.
