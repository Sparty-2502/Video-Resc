# Video-Resc

Automatización para preparar una instancia Ubuntu/Vast.ai con una build optimizada de **Video2X 6.4.0 + Real-ESRGAN NCNN/Vulkan** para reescalado de anime 4x.

## Perfil probado

- GPU: RTX 4090
- Video2X: 6.4.0
- Procesador: `realesrgan`
- Modelo: `realesr-animevideov3`
- Escala: `4x`
- Tile recomendado: `1024`
- Workers recomendados: `3`

En nuestras pruebas, 1 worker rondó ~6 FPS y 3 workers dieron aproximadamente ~12 FPS agregados. 4 workers comenzaron a degradar el rendimiento.

## Uso rápido

```bash
git clone https://github.com/Sparty-2502/Video-Resc.git
cd Video-Resc
chmod +x *.sh
./network-test.sh
TILE_SIZE=1024 ./bootstrap.sh
```

Sube los videos a:

```text
/workspace/video2x/input/
```

Y lanza la cola de 3 workers:

```bash
WORKERS=3 ./run-workers.sh
```

Resultados:

```text
/workspace/video2x/output/
```

Logs:

```text
/workspace/video2x/logs/
```

## Variables útiles

```bash
TILE_SIZE=1024
WORKERS=3
SCALE=4
MODEL=realesr-animevideov3
```

Ejemplo:

```bash
WORKERS=3 SCALE=4 MODEL=realesr-animevideov3 ./run-workers.sh
```

## Notas

- El script de instalación evita clonar recursivamente todo Boost; usa Boost del sistema y solo inicializa los submódulos necesarios de Video2X.
- NVENC puede no estar expuesto correctamente en algunas instancias de Vast.ai incluso si la GPU lo soporta. El flujo por defecto usa `libx264`.
- Antes de gastar tiempo configurando una instancia, ejecuta `./network-test.sh` y haz también una prueba `scp` desde tu PC para medir **tu ruta real de subida**.
- Los videos de entrada no se incluyen en este repositorio.
