# Video-Resc

Automatización y documentación para preparar un entorno de **Video2X 6.4.0 + Real-ESRGAN NCNN/Vulkan** orientado a reescalado de anime, especialmente 720p -> 4x.

El proyecto nació de pruebas reales con una RX 5700 XT local y varias RTX 4090 rentadas en Vast.ai. El objetivo es que el mismo flujo pueda recrearse de forma rápida tanto en una instancia cloud como en una PC propia con Linux y GPU compatible con Vulkan.

> Este repositorio no incluye videos, modelos con copyright ajeno ni contenido multimedia de terceros. Solo automatiza la instalación/configuración de herramientas de código abierto.

---

## Qué hace este repo

- valida que la GPU NVIDIA esté visible;
- valida que el runtime Vulkan NVIDIA esté realmente disponible;
- mide descarga desde GitHub;
- instala dependencias de compilación y runtime;
- clona Video2X 6.4.0;
- inicializa los submódulos necesarios;
- modifica el tamaño de tile de Real-ESRGAN;
- compila e instala una build propia de Video2X;
- prepara carpetas de entrada, salida y logs;
- procesa un archivo individual;
- procesa una cola completa con varios workers concurrentes.

---

## Perfil probado

Configuración de referencia:

| Componente | Valor probado |
|---|---|
| GPU | NVIDIA RTX 4090 24 GB |
| SO | Ubuntu 24.04 / contenedor Vast.ai |
| Driver NVIDIA | rama 580.x |
| Video2X | 6.4.0 |
| Backend | Real-ESRGAN NCNN/Vulkan |
| Modelo | `realesr-animevideov3` |
| Escala | `4x` |
| Tile recomendado | `1024` |
| Workers recomendados | `3` |
| Encoder por defecto | `libx264` |

Resultados aproximados observados durante las pruebas:

- RX 5700 XT local: ~3.5 FPS en un flujo similar.
- RTX 4090, un worker optimizado: ~5.9-6.1 FPS.
- RTX 4090, dos workers: ~10.3 FPS agregados.
- RTX 4090, tres workers: ~11.8-12 FPS agregados.
- Cuatro workers comenzaron a degradar el rendimiento por proceso y dejaron de ser atractivos.

Estos valores **no son garantía de rendimiento**: dependen del video, resolución de entrada, CPU, driver, host, almacenamiento y configuración.

---

# Requisitos

## Requisitos mínimos de software

El flujo automatizado está pensado principalmente para **Ubuntu 24.04** o un sistema Linux compatible con paquetes Debian/Ubuntu.

El script instala automáticamente:

- `git`
- `curl`
- `python3`
- `build-essential`
- `cmake`
- `ninja-build`
- `pkg-config`
- `ffmpeg`
- `vulkan-tools`
- `libvulkan-dev`
- `glslang-tools`
- `libomp-dev`
- librerías de desarrollo FFmpeg;
- Boost Program Options.

Para uso local fuera de Ubuntu se puede replicar el flujo manualmente, pero `bootstrap.sh` actualmente usa `apt-get`.

## GPU

### NVIDIA

Recomendado para este flujo:

- RTX 30, 40 o 50 Series;
- driver NVIDIA propietario;
- Vulkan funcional;
- al menos 8 GB de VRAM para trabajar cómodamente;
- 16-24 GB o más si se desean varios workers o experimentar con tiles mayores.

Una RTX 4090 de 24 GB es la configuración sobre la que se afinó este repo.

### AMD

Video2X/NCNN puede trabajar mediante Vulkan en GPUs AMD compatibles. El proyecto original se probó también con una RX 5700 XT.

Sin embargo, los scripts de validación actuales están diseñados específicamente para comprobar **NVIDIA + Vulkan**, porque el objetivo inicial fue automatizar instancias RTX en Vast.ai.

Para uso local con AMD puede ser necesario adaptar `network-test.sh` y la validación de `bootstrap.sh`.

## CPU

No hace falta una CPU de gama extrema, pero Video2X también usa CPU para decodificación/codificación y tareas auxiliares.

Para producción se recomienda:

- 8 hilos o más;
- 16+ hilos si se usarán varios workers;
- evitar CPUs muy limitadas si se ejecutarán 3 trabajos simultáneos.

## RAM

Recomendado:

- mínimo práctico: 16 GB;
- recomendado: 32 GB;
- 48-64 GB o más para varios workers y entornos cloud holgados.

## Disco

Necesitas espacio para:

- fuentes;
- build de Video2X;
- modelos;
- archivos de salida 4x;
- logs.

Los videos reescalados pueden crecer considerablemente. Para una temporada completa se recomienda reservar **decenas de GB libres** dependiendo del codec y duración.

SSD/NVMe recomendado.

---

# Requisito crítico: Vulkan

Que `nvidia-smi` funcione **no significa** que Video2X vaya a funcionar.

Real-ESRGAN NCNN usa Vulkan. En varias instancias de Vast.ai encontramos hosts donde CUDA estaba disponible pero faltaban las librerías gráficas/ICD de NVIDIA. En esos casos Video2X falla con mensajes como:

```text
Failed to create Vulkan instance.
Unable to validate Vulkan device ID.
```

La instancia debe tener al menos:

```text
libGLX_nvidia.so.0
libEGL_nvidia.so.0
```

y un ICD NVIDIA, normalmente:

```text
/etc/vulkan/icd.d/nvidia_icd.json
```

Además:

```bash
vulkaninfo --summary
```

debe mostrar explícitamente la GPU NVIDIA.

Por eso **siempre se debe ejecutar `network-test.sh` antes de `bootstrap.sh`**.

---

# Uso en Vast.ai

## 1. Crear instancia

Plantilla recomendada:

```text
NVIDIA CUDA / Ubuntu
SSH habilitado
```

Para producción se recomienda elegir un host con:

- RTX 4090/5090;
- buena confiabilidad;
- duración máxima suficiente;
- almacenamiento NVMe;
- red anunciada decente.

Las cifras de red de Vast.ai son solo orientativas. Hay que medir la ruta real desde tu PC.

## 2. Conectarse por SSH

Ejemplo:

```bash
ssh -p PUERTO root@IP
```

## 3. Clonar y validar la instancia

```bash
cd /workspace
git clone https://github.com/Sparty-2502/Video-Resc.git
cd Video-Resc
chmod +x *.sh
./network-test.sh
```

Una instancia válida debe terminar aproximadamente con:

```text
PASS: Vulkan detecta la GPU NVIDIA.
RESULTADO: APTA para continuar con bootstrap.sh
```

Si indica `NO APTA`, no compiles ni subas la temporada: cambia de host.

## 4. Probar la velocidad PC -> Vast

Desde Windows CMD:

```cmd
scp -i %USERPROFILE%\.ssh\id_ed25519 -P PUERTO "C:\ruta\video_prueba.mp4" root@IP:/workspace/
```

Guía orientativa:

| Subida real | Evaluación |
|---|---|
| < 500 KB/s | Mala para producción |
| 500 KB/s - 2 MB/s | Usable, pero lenta |
| 2-5 MB/s | Buena |
| 5+ MB/s | Muy buena |
| 10+ MB/s | Excelente |

## 5. Instalar/compilar

```bash
cd /workspace/Video-Resc
TILE_SIZE=1024 ./bootstrap.sh
```

El script dejará la instalación en:

```text
/workspace/video2x-custom/
```

y las carpetas de trabajo en:

```text
/workspace/video2x/input/
/workspace/video2x/output/
/workspace/video2x/logs/
```

## 6. Subir los videos

Desde Windows:

```cmd
scp -i %USERPROFILE%\.ssh\id_ed25519 -P PUERTO "C:\ruta\temporada\*.mp4" root@IP:/workspace/video2x/input/
```

## 7. Procesar la cola

```bash
cd /workspace/Video-Resc
WORKERS=3 ./run-workers.sh
```

El script mantiene hasta 3 videos en proceso simultáneamente. Cuando uno termina, toma automáticamente el siguiente archivo.

---

# Uso en una PC propia

El mismo flujo puede ejecutarse localmente en Linux.

## Caso recomendado: Ubuntu 24.04 + NVIDIA

Primero comprueba:

```bash
nvidia-smi
vulkaninfo --summary
```

La salida de Vulkan debe incluir tu GPU.

Luego:

```bash
git clone https://github.com/Sparty-2502/Video-Resc.git
cd Video-Resc
chmod +x *.sh
./network-test.sh
TILE_SIZE=1024 ./bootstrap.sh
```

Por defecto el proyecto usa rutas bajo `/workspace`. En una PC personal puedes conservarlas o cambiar las variables:

```bash
SRC_DIR="$HOME/video2x-src" \
INSTALL_DIR="$HOME/video2x-custom" \
WORK_DIR="$HOME/video2x-work" \
TILE_SIZE=1024 \
./bootstrap.sh
```

Para ejecutar después:

```bash
INSTALL_DIR="$HOME/video2x-custom" \
WORK_DIR="$HOME/video2x-work" \
./run-video2x.sh "$HOME/Videos/episodio.mp4"
```

Para cola:

```bash
WORK_DIR="$HOME/video2x-work" \
INSTALL_DIR="$HOME/video2x-custom" \
WORKERS=3 \
./run-workers.sh
```

> Nota: los scripts se ejecutan como root en Vast.ai. Para uso local el `bootstrap.sh` actual requiere root porque instala paquetes con `apt-get`. Se puede ejecutar con `sudo` o adaptar la fase de dependencias para una instalación sin privilegios.

---

# Estructura de carpetas

```text
/workspace/
├── Video-Resc/              # este repositorio
├── video2x-src/             # código fuente Video2X
├── video2x-custom/          # instalación compilada
│   ├── bin/video2x
│   ├── lib/
│   ├── share/video2x/models/
│   ├── models -> share/video2x/models
│   └── env.sh
└── video2x/
    ├── input/               # videos originales
    ├── output/              # videos 4x
    └── logs/                # logs por archivo
```

---

# Scripts

## `network-test.sh`

Comprueba:

- `nvidia-smi`;
- librerías Vulkan NVIDIA;
- ICD de NVIDIA;
- que `vulkaninfo` detecte la GPU;
- velocidad aproximada de descarga desde GitHub.

No mide la ruta desde tu PC hacia el servidor. Esa debe comprobarse con `scp`.

## `bootstrap.sh`

Automatiza:

1. validación de GPU/Vulkan;
2. instalación de dependencias;
3. clonación de Video2X 6.4.0;
4. inicialización de submódulos;
5. parche del tile Real-ESRGAN;
6. configuración CMake/Ninja;
7. compilación;
8. instalación;
9. preparación de modelos y variables de entorno.

## `run-video2x.sh`

Procesa un solo archivo usando:

```text
processor: realesrgan
model: realesr-animevideov3
scale: 4
```

Uso:

```bash
./run-video2x.sh /ruta/entrada.mp4
```

o:

```bash
./run-video2x.sh /ruta/entrada.mp4 /ruta/salida.mp4
```

## `run-workers.sh`

Procesa todos los videos encontrados en `input/` con concurrencia configurable.

```bash
WORKERS=3 ./run-workers.sh
```

Formatos de entrada contemplados:

- `.mp4`
- `.mkv`
- `.avi`
- `.mov`
- `.webm`
- `.m4v`

---

# Variables configurables

| Variable | Default | Función |
|---|---:|---|
| `VIDEO2X_VERSION` | `6.4.0` | versión/tag de Video2X |
| `TILE_SIZE` | `1024` | tile Real-ESRGAN compilado |
| `SRC_DIR` | `/workspace/video2x-src` | código fuente |
| `INSTALL_DIR` | `/workspace/video2x-custom` | instalación compilada |
| `WORK_DIR` | `/workspace/video2x` | input/output/logs |
| `MODEL` | `realesr-animevideov3` | modelo Real-ESRGAN |
| `SCALE` | `4` | escala |
| `WORKERS` | `3` | concurrencia |

Ejemplo:

```bash
TILE_SIZE=1024 WORKERS=3 SCALE=4 MODEL=realesr-animevideov3 ./run-workers.sh
```

---

# Por qué se modifica el tile

Durante las pruebas se observó que Video2X 6.4.0 utilizaba un tile conservador para Real-ESRGAN. En una RTX 4090 esto dejaba gran parte del hardware desaprovechado.

Se experimentó con distintos valores:

- 200: rendimiento muy pobre en la prueba inicial;
- 512: mejora enorme;
- 1024: mejor equilibrio general;
- 1536: prácticamente sin mejora respecto a 1024 en nuestras pruebas;
- tamaños aún mayores no mostraban una razón clara para producción.

Por estabilidad y concurrencia, el repo usa **1024 como valor recomendado**.

---

# Concurrencia y rendimiento

Una RTX 4090 no quedó completamente saturada con un solo proceso de Video2X/NCNN. Ejecutar varios trabajos aumentó el throughput agregado.

Configuración observada:

```text
1 worker  -> ~6 FPS agregados
2 workers -> ~10.3 FPS agregados
3 workers -> ~11.8-12 FPS agregados
4 workers -> rendimiento marginal/degradación
```

Por eso el valor recomendado es:

```bash
WORKERS=3
```

En otras GPUs el punto óptimo puede ser distinto.

---

# Encoder y NVENC

El flujo por defecto usa `libx264`.

Se probó `libx264` con preset `ultrafast` y no produjo una mejora importante en el throughput de Real-ESRGAN, lo que indicó que el encoder CPU no era el principal cuello de botella en ese entorno.

También se intentó usar:

```text
h264_nvenc
hevc_nvenc
```

pero algunas instancias Vast.ai exponían CUDA/Vulkan sin permitir correctamente sesiones NVENC, mostrando errores como:

```text
OpenEncodeSessionEx failed: unsupported device (2)
No capable devices found
```

Por eso NVENC no está activado por defecto.

---

# Monitoreo

Procesos activos:

```bash
watch -n 2 "ps aux | grep '[v]ideo2x'"
```

GPU:

```bash
watch -n 1 nvidia-smi
```

Archivos de salida:

```bash
watch -n 5 "ls -lh /workspace/video2x/output/"
```

Log de un episodio:

```bash
tail -f "/workspace/video2x/logs/NOMBRE.log"
```

---

# Transferencia de archivos

## Subir desde Windows

```cmd
scp -i %USERPROFILE%\.ssh\id_ed25519 -P PUERTO "C:\Videos\*.mp4" root@IP:/workspace/video2x/input/
```

## Descargar resultados

```cmd
scp -i %USERPROFILE%\.ssh\id_ed25519 -P PUERTO root@IP:/workspace/video2x/output/*.mp4 "C:\Videos\Upscaled\"
```

Para videos ya comprimidos no suele aportar mucho usar compresión SSH (`scp -C`).

---

# Solución de problemas

## `Failed to create Vulkan instance`

Comprueba:

```bash
ldconfig -p | grep -E 'libGLX_nvidia|libEGL_nvidia'
find /etc/vulkan/icd.d /usr/share/vulkan/icd.d -iname '*nvidia*.json' 2>/dev/null
vulkaninfo --summary
```

Si las librerías NVIDIA/ICD no existen en un contenedor cloud, normalmente es mejor cambiar de host que intentar reparar el runtime dentro del contenedor.

## `libvideo2x.so: cannot open shared object file`

```bash
export LD_LIBRARY_PATH=/workspace/video2x-custom/lib:$LD_LIBRARY_PATH
```

El bootstrap genera también:

```bash
source /workspace/video2x-custom/env.sh
```

## Modelos Real-ESRGAN no encontrados

La instalación queda en:

```text
/workspace/video2x-custom/share/video2x/models/
```

El bootstrap crea:

```text
/workspace/video2x-custom/models -> share/video2x/models
```

## Worker falla instantáneamente

Revisa el log correspondiente:

```bash
cat "/workspace/video2x/logs/NOMBRE.log"
```

`run-workers.sh` devuelve error si alguno de los trabajos falla y elimina archivos de salida incompletos.

---

# Recomendaciones para producción

1. Ejecuta `network-test.sh` antes de hacer cualquier instalación costosa.
2. En cloud, valida además una subida real con `scp` desde tu PC.
3. Usa `TILE_SIZE=1024` como punto de partida.
4. Usa `WORKERS=3` en RTX 4090 como punto de partida.
5. Procesa primero 1-3 videos completos antes de soltar una temporada completa en una GPU distinta.
6. Vigila espacio libre antes de procesar lotes grandes.
7. Conserva los archivos originales hasta validar las salidas.
8. No destruyas una instancia cloud hasta haber descargado resultados que quieras conservar.

---

# Alcance y limitaciones

Este repo no intenta ser un reemplazo general de Video2X. Es un **perfil de despliegue reproducible** basado en una configuración concreta para Real-ESRGAN/NCNN/Vulkan.

No garantiza:

- el mismo rendimiento en otras GPUs;
- compatibilidad con todos los drivers;
- NVENC en todos los proveedores cloud;
- que un upscale 4x siempre mejore perceptualmente una fuente;
- que el archivo resultante tenga exactamente resolución UHD 3840x2160: una escala 4x multiplica las dimensiones originales. Por ejemplo, 1280x720 -> 5120x2880.

Si se desea específicamente 3840x2160, debe utilizarse un flujo que establezca dimensiones objetivo o una etapa adicional de resize.

---

# Créditos y licencias

Este proyecto automatiza y configura herramientas de terceros. Consulta sus repositorios/licencias originales, especialmente:

- Video2X
- Real-ESRGAN / Real-ESRGAN NCNN Vulkan
- NCNN
- FFmpeg
- Vulkan

Video-Resc no redistribuye contenido multimedia de terceros.
