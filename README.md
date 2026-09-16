# Video-Resc

Automatización y documentación para preparar un entorno de **Video2X 6.4.0 + Real-ESRGAN NCNN/Vulkan** orientado a reescalado de anime, especialmente 720p -> 4x.

El proyecto nació de pruebas reales con una RX 5700 XT local y varias RTX 4090 rentadas en Vast.ai. El objetivo es que el mismo flujo pueda recrearse tanto en una sola GPU como en hosts multi-GPU.

> Este repositorio no incluye videos ni contenido multimedia de terceros. Solo automatiza instalación, validación y ejecución de herramientas de código abierto.

---

## Perfil probado

Configuración base afinada:

| Componente | Valor |
|---|---|
| Video2X | 6.4.0 |
| Backend | Real-ESRGAN NCNN/Vulkan |
| Modelo | `realesr-animevideov3` |
| Escala | `4x` |
| Tile recomendado | `1024` |
| Workers recomendados RTX 4090 | `3 por GPU` |
| Encoder | `libx264` |
| GPU principal probada | RTX 4090 24 GB |

Resultados observados en pruebas de una RTX 4090:

- 1 worker: ~5.9-6.1 FPS;
- 2 workers: ~10 FPS agregados;
- 3 workers: mejor throughput observado;
- 4 workers: degradación suficiente como para no recomendarlo inicialmente.

Los números dependen del host, CPU, driver, almacenamiento, resolución, duración y contenido del video.

---

# Requisitos

## GPU

El requisito crítico no es CUDA sino **Vulkan funcional**.

Para NVIDIA se recomienda:

- RTX 30/40/50 Series;
- driver propietario NVIDIA;
- `nvidia-smi` funcional;
- `libGLX_nvidia.so` o `libEGL_nvidia.so` visibles;
- ICD Vulkan NVIDIA presente;
- `vulkaninfo --summary` mostrando la GPU;
- Video2X mostrando la GPU mediante `video2x --list-gpus`.

En multi-GPU, las dos o más GPUs deben aparecer en **los tres niveles**:

```text
nvidia-smi
vulkaninfo --summary
video2x --list-gpus
```

Que `nvidia-smi` muestre dos GPUs no garantiza que Vulkan exponga ambas.

## CPU y RAM

Para 1 GPU / 3 workers:

- 8+ hilos CPU recomendados;
- 16-32 GB RAM recomendados.

Para 2 GPUs / 6 workers:

- 16+ hilos CPU recomendados;
- 32 GB RAM mínimo práctico;
- 64 GB recomendado si el host tiene recursos suficientes.

La codificación `libx264` también consume CPU. Un host multi-GPU con CPU débil puede impedir escalar linealmente.

## Almacenamiento

Se recomienda NVMe y espacio suficiente para:

- videos originales;
- build de Video2X;
- archivos temporales en `processing/`;
- resultados completos en `output/`;
- logs.

Los resultados 4x pueden ser varias veces más grandes que el material original.

---

# Scripts

## `network-test.sh`

Preflight **antes de compilar o subir videos**.

Comprueba:

- GPUs visibles por `nvidia-smi`;
- librerías gráficas NVIDIA;
- ICD Vulkan NVIDIA;
- cuántas GPUs NVIDIA ve Vulkan;
- que todas las GPUs anunciadas estén expuestas a Vulkan;
- descarga aproximada desde GitHub.

Uso normal:

```bash
./network-test.sh
```

Para validar específicamente una oferta de 2 GPUs:

```bash
EXPECTED_GPUS=2 ./network-test.sh
```

Si el script falla, no ejecutes `bootstrap.sh` ni subas una temporada completa.

## `bootstrap.sh`

Instala dependencias, clona Video2X 6.4.0, inicializa submódulos, aplica el tile configurado, compila e instala una build propia.

Una GPU:

```bash
TILE_SIZE=1024 ./bootstrap.sh
```

Dos GPUs esperadas:

```bash
EXPECTED_GPUS=2 TILE_SIZE=1024 ./bootstrap.sh
```

Al final valida `video2x --list-gpus` y falla si Video2X no ve todas las GPUs NVIDIA expuestas.

## `gpu-test.sh`

Validación posterior al build.

Compara el número de GPUs detectadas por:

```text
nvidia-smi
Vulkan
Video2X
```

Una GPU:

```bash
./gpu-test.sh
```

Dos GPUs:

```bash
EXPECTED_GPUS=2 ./gpu-test.sh
```

## `run-video2x.sh`

Procesa un único video. Soporta selección explícita de GPU mediante `GPU_ID`.

GPU 0:

```bash
GPU_ID=0 ./run-video2x.sh /ruta/episodio.mp4
```

GPU 1:

```bash
GPU_ID=1 ./run-video2x.sh /ruta/episodio.mp4
```

Internamente pasa `-g GPU_ID` a Video2X.

## `run-workers.sh`

Scheduler de producción con soporte automático para 1 o varias GPUs.

Características:

- detecta GPUs con `video2x --list-gpus`;
- `GPUS=auto` usa todas las GPUs disponibles;
- limita concurrencia por GPU;
- distribuye trabajos entre GPUs disponibles;
- no vuelve a procesar salidas ya completas;
- escribe temporalmente en `processing/`;
- mueve el archivo a `output/` solo cuando Video2X termina correctamente;
- elimina temporales de trabajos fallidos.

Esto evita confundir un MP4 todavía abierto con un resultado completo.

---

# Uso rápido en Vast.ai

## 1. Clonar y validar

```bash
cd /workspace
git clone https://github.com/Sparty-2502/Video-Resc.git
cd Video-Resc
chmod +x *.sh
./network-test.sh
```

Para una oferta de 2x RTX 4090:

```bash
EXPECTED_GPUS=2 ./network-test.sh
```

Una salida válida debe indicar que Vulkan detecta correctamente ambas GPUs.

## 2. Medir PC -> servidor

Desde Windows CMD:

```cmd
scp -i %USERPROFILE%\.ssh\id_ed25519 -P PUERTO "C:\ruta\benchmark.mp4" root@IP:/workspace/
```

La cifra anunciada por Vast no sustituye esta prueba.

## 3. Compilar

Una GPU:

```bash
TILE_SIZE=1024 ./bootstrap.sh
```

Dos GPUs:

```bash
EXPECTED_GPUS=2 TILE_SIZE=1024 ./bootstrap.sh
```

## 4. Validar Video2X

```bash
./gpu-test.sh
```

o para dos GPUs:

```bash
EXPECTED_GPUS=2 ./gpu-test.sh
```

Deberías ver algo similar a:

```text
0. NVIDIA GeForce RTX 4090
1. NVIDIA GeForce RTX 4090
```

## 5. Subir videos

```cmd
scp -i %USERPROFILE%\.ssh\id_ed25519 -P PUERTO "C:\ruta\temporada\*.mp4" root@IP:/workspace/video2x/input/
```

## 6. Producción

### Una GPU

```bash
GPUS=auto WORKERS_PER_GPU=3 ./run-workers.sh
```

Con una sola GPU disponible, el total será 3 workers.

También se conserva compatibilidad con:

```bash
WORKERS=3 ./run-workers.sh
```

`WORKERS` funciona como alias de `WORKERS_PER_GPU`.

### Dos GPUs

```bash
GPUS=auto WORKERS_PER_GPU=3 ./run-workers.sh
```

Con dos GPUs detectadas:

```text
GPU 0 -> hasta 3 workers
GPU 1 -> hasta 3 workers
Total -> hasta 6 workers
```

También puedes seleccionar GPUs explícitamente:

```bash
GPUS=0,1 WORKERS_PER_GPU=3 ./run-workers.sh
```

O usar solo una GPU de un host multi-GPU:

```bash
GPUS=1 WORKERS_PER_GPU=3 ./run-workers.sh
```

---

# Estructura de trabajo

```text
/workspace/
├── Video-Resc/
├── video2x-src/
├── video2x-custom/
│   ├── bin/video2x
│   ├── lib/
│   ├── share/video2x/models/
│   ├── models -> share/video2x/models
│   └── env.sh
└── video2x/
    ├── input/        # originales
    ├── processing/   # archivos todavía en proceso; NO descargar
    ├── output/       # únicamente trabajos terminados correctamente
    └── logs/
```

**Solo descarga archivos desde `output/`.**

Los archivos de `processing/` pueden estar incompletos y no reproducirse todavía.

---

# Variables configurables

| Variable | Default | Función |
|---|---:|---|
| `VIDEO2X_VERSION` | `6.4.0` | tag de Video2X |
| `TILE_SIZE` | `1024` | tile Real-ESRGAN compilado |
| `SRC_DIR` | `/workspace/video2x-src` | fuentes |
| `INSTALL_DIR` | `/workspace/video2x-custom` | instalación |
| `WORK_DIR` | `/workspace/video2x` | trabajo |
| `MODEL` | `realesr-animevideov3` | modelo Real-ESRGAN |
| `SCALE` | `4` | factor de escala |
| `GPU_ID` | `0` | GPU para un trabajo individual |
| `GPUS` | `auto` | GPUs usadas por la cola, ej. `0,1` |
| `WORKERS_PER_GPU` | `3` | concurrencia por GPU |
| `WORKERS` | `3` | alias compatible de `WORKERS_PER_GPU` |
| `EXPECTED_GPUS` | `0` | cantidad esperada; `0` desactiva comprobación exacta |

---

# Multi-GPU: cómo funciona

Video2X permite listar GPUs con:

```bash
video2x --list-gpus
```

y seleccionar una GPU con:

```bash
video2x ... -g 1
```

El scheduler aprovecha esto asignando cada proceso a un ID de GPU específico.

No intenta dividir un mismo episodio entre dos GPUs. El paralelismo es por archivo:

```text
GPU 0: episodio A, B, C
GPU 1: episodio D, E, F
```

Cuando queda una ranura libre, el scheduler inicia otro episodio en esa GPU sin superar `WORKERS_PER_GPU`.

Este enfoque funciona igual con una GPU: simplemente existe un único pool de workers.

---

# Por qué tile 1024

Video2X 6.4.0 utilizaba un tile conservador para Real-ESRGAN. En RTX 4090 se probó aumentar el valor.

Resultados cualitativos de las pruebas:

- `200`: demasiado conservador;
- `512`: mejora grande;
- `1024`: mejor equilibrio;
- `1536`: prácticamente sin ganancia relevante frente a 1024.

Por eso `1024` es el punto recomendado inicial.

Más VRAM libre no significa automáticamente más FPS: el límite puede estar en cómputo, sincronización, CPU, memoria o el propio pipeline NCNN/Vulkan.

---

# Monitoreo

GPUs:

```bash
watch -n 1 nvidia-smi
```

Procesos:

```bash
watch -n 2 "ps aux | grep '[v]ideo2x'"
```

Resultados terminados:

```bash
watch -n 5 "ls -lh /workspace/video2x/output/"
```

Trabajos todavía en proceso:

```bash
watch -n 5 "ls -lh /workspace/video2x/processing/"
```

Logs:

```bash
tail -f "/workspace/video2x/logs/NOMBRE.log"
```

En multi-GPU, `nvidia-smi` debe mostrar carga en ambas GPUs durante una cola suficientemente grande.

---

# Reanudar después de una interrupción

`run-workers.sh` omite archivos cuyo resultado ya existe y tiene contenido en `output/`.

Por tanto, después de un reinicio:

```bash
GPUS=auto WORKERS_PER_GPU=3 ./run-workers.sh
```

Los episodios terminados no se reprocesan.

Los archivos que estaban a medio procesar permanecen en `processing/` o se reemplazan al reiniciar el trabajo correspondiente.

---

# Uso local

El flujo principal automatizado está pensado para Ubuntu/Debian porque `bootstrap.sh` usa `apt-get`.

En una PC personal puedes cambiar las rutas:

```bash
SRC_DIR="$HOME/video2x-src" \
INSTALL_DIR="$HOME/video2x-custom" \
WORK_DIR="$HOME/video2x-work" \
TILE_SIZE=1024 \
./bootstrap.sh
```

Después:

```bash
INSTALL_DIR="$HOME/video2x-custom" \
WORK_DIR="$HOME/video2x-work" \
GPUS=auto \
WORKERS_PER_GPU=3 \
./run-workers.sh
```

En distribuciones como Gentoo hay que reemplazar la fase de instalación de paquetes de `apt-get` por los paquetes equivalentes del sistema. El resto del pipeline puede seguir siendo válido si Vulkan y Video2X funcionan correctamente.

---

# NVENC

El flujo usa `libx264` por defecto.

En algunas instancias cloud CUDA y Vulkan funcionan mientras NVENC no está expuesto correctamente. Durante pruebas se observaron errores como:

```text
OpenEncodeSessionEx failed: unsupported device (2)
No capable devices found
```

Por eso NVENC no forma parte del flujo recomendado inicial.

---

# Diagnóstico rápido para 2 GPUs

Si una instancia anuncia 2 GPUs, ejecuta en este orden:

```bash
EXPECTED_GPUS=2 ./network-test.sh
EXPECTED_GPUS=2 TILE_SIZE=1024 ./bootstrap.sh
EXPECTED_GPUS=2 ./gpu-test.sh
```

Solo después sube la colección completa y ejecuta:

```bash
GPUS=auto WORKERS_PER_GPU=3 ./run-workers.sh
```

Si cualquiera de las tres validaciones muestra menos GPUs de las esperadas, no asumas que el host podrá aprovechar ambas.
