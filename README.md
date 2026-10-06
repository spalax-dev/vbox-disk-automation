# vboxdisk

Automatiza la preparación de discos de datos en máquinas virtuales de VirtualBox
desde el host: crea el disco virtual, lo adjunta, lo particiona, formatea,
monta y deja el montaje persistente en `/etc/fstab` - sin tocar el teclado.

La solución es declarativa: describes el estado deseado en `vdisk.yml` y
ejecutas `vboxdisk apply` tantas veces como quieras. Si ya todo está como debe,
no hace nada.

```bash
vboxdisk apply          # converge todas las vm del archivo
vboxdisk status         # qué hay en cada vm y en sus discos
vboxdisk ld VM1         # tabla de particiones de VM1 (registrada o en vivo)
```

## Características

- **Declarativo y reproducible**: `vdisk.yml` es la única fuente de verdad;
  la misma corrida siempre lleva al mismo estado final.
- **Multi-vm y multi-disco**: cada vm declara una lista `disks`, con tamaño,
  sistema de archivos (`ext4`/`xfs`), punto de montaje y etiqueta por disco.
- **Idempotente**: cada acción destructiva (`sfdisk`, `mkfs`, `mount`) está
  precedida de una guarda de solo lectura; re-ejecutar no reformatea ni duplica
  entradas en `fstab`.
- **No destructivo sin confirmar**: `--dry-run` muestra el plan sin tocar nada;
  el retiro de discos registrados pregunta antes (o elige con `-y`).
- **Interacción acotada**: solo los caminos peligrosos preguntan, y la respuesta
  se escribe en la terminal, incluso si la entrada estándar está redirigida; sin
  terminal no hay a quien preguntar y la corrida se detiene con código 4. Las
  contraseñas nunca se piden por la terminal: viajan en ficheros temporales que
  se destruyen al salir, en el host y en el invitado.
- **Códigos de salida distintos** por tipo de fallo, para usar en scripts.
- **Pruebas con doble de VirtualBox**: 76 pruebas BATS corren sin hipervisor.

## Requisitos

**Host**

| Dependencia | Para qué |
|---|---|
| `bash` 4+ | la solución en sí |
| `VBoxManage` | hipervisor (probado con VirtualBox 7.2) |
| `yq` | leer `vdisk.yml` |
| `ip` | respaldo de la búsqueda de dirección IP |
| `make`, `shellcheck`, `bats` | solo para desarrollar (`checkdeps`, `lint`, `test`) |

**Invitado (cada vm)**

- Guest Additions con `VBoxService` corriendo - en Debian: `virtualbox-guest-utils`
  (instalado desde Fast Track en Debian 13).
- util-linux (con `sfdisk`), `sudo`, y las utilidades de `ext4` (`e2fsprogs`) o
  `xfsprogs` según declares.
- Un disco de datos **nuevo y vacío** por disco declarado (los `.vdi` recién
  creados cumplen esto); el disco del sistema nunca se toca.

## Instalación

```bash
make checkdeps   # comprueba dependencias sin instalar nada
make lint        # shellcheck
make test        # pruebas BATS
make install     # encadena las tres y solo entonces instala
make uninstall   # retira ejecutable y librerías (no toca tu perfil)
```

`make install` no necesita privilegios: copia el ejecutable en `~/.local/bin`,
las bibliotecas en `~/.local/share/vboxdisk/` y, si hace falta, añade un bloque
delimitado a `~/.bashrc`/`~/.zshrc` con ese directorio en el `PATH`. Abre una
sesión nueva después de instalar. `make uninstall` retira el ejecutable y las
bibliotecas, pero no vuelve a modificar `~/.bashrc` ni `~/.zshrc`: retirar ese
bloque queda en tus manos.

También puedes ejecutarlo sin instalar desde el repositorio:

```bash
./src/vboxdisk --help
```

## Inicio rápido

```bash
cp vdisk.yml.example vdisk.yml   # y edítalo con tus vm reales
vboxdisk apply --dry-run         # qué haría, sin hacer nada
vboxdisk apply                   # converger
echo $?                          # 0 = todo correcto
```

### `vdisk.yml`

```yaml
VM1:
  vm_user: debian
  vm_pass: "cambia-esta-clave"     # o vm_pass_file: /ruta/al/fichero
  disks:
    disk1:
      size: 4g                     # megabytes o sufijo m/g/t
      fs_type: ext4
      mount_point: /mnt/datos
      label: datos-vm1
      # file: /ruta/opcional.vdi   # si se omite, se deriva del nombre de la vm
      # state: active              # active (defecto) | inactive
    disk2:
      size: 1024
      fs_type: ext4
      mount_point: /mnt/respaldo
      label: respaldo-vm1
```

- **Nivel vm**: `vm_user` y `disks` son obligatorios; de `vm_pass` y
  `vm_pass_file` se exige al menos una.
- **Nivel disco**: `label`, `size`, `fs_type` y `mount_point` son obligatorios;
  `file` y `state` son opcionales. Dentro de una vm, etiquetas y puntos de
  montaje deben ser únicos.
- Cualquier clave desconocida detiene la validación con código 1, incluido el
  esquema plano antiguo (`disk_file`, `disk_size_mb`, …).
- Precedencia de valores: variables de entorno `VBOXDISK_*` > `vdisk.yml` >
  valores por defecto.

### Opciones

```
vboxdisk <orden> [opciones]

  apply            converge todas las vm de ./vdisk.yml (única orden que modifica)
  status           lista las vm con su sincronización, sus discos y su IP
  ld <nombre>      tabla de particiones de los discos: la registrada o, sin
                   registro, la de la vm encendida (nunca la enciende)

  -f, --file FILE  archivo declarativo (por defecto ./vdisk.yml)
  --dry-run        muestra el plan de cambios sin modificar nada (apply)
  -y, --yes        omite confirmaciones; ante un disco registrado y ausente
                   del archivo elige eliminarlo
  -h, --help       esta ayuda
```

### Códigos de salida

| Código | Significado |
|---|---|
| 0 | convergido, o sin cambios que aplicar |
| 1 | uso o configuración (orden, archivo, vm inexistente) |
| 2 | comunicación con la vm (`VBoxService` sin responder, sin IP) |
| 3 | almacenamiento o verificación (disco no identificable, sin espacio, `mkfs`/`mount` falló) |
| 4 | cancelado por el usuario, o consulta sin terminal disponible |

### Variables de entorno

| Variable | Efecto |
|---|---|
| `VBOXDISK_<CLAVE>` | sobrescribe la clave de nivel vm (`VBOXDISK_VM_USER`, …) |
| `VBOXDISK_READY_TIMEOUT` | espera de `VBoxService` en segundos (120) |
| `VBOXDISK_IP_TIMEOUT` | espera de dirección IP (60) |
| `VBOXDISK_GUEST_TIMEOUT` | tiempo máximo del script invitado (300) |
| `VBOXDISK_STATE_DIR` | cambia la raíz de estado (útil en pruebas) |

## Estado y bitácoras

Todo vive bajo `~/.local/share/vboxdisk/` (o `$XDG_DATA_HOME/vboxdisk/`):

```
state.lock              estado por vm y por disco; no se instala ni se borra
state/<fecha>.log       una bitácora por corrida de apply
```

La bitácora recibe la misma línea que sale por `stderr`, con marca de tiempo y
nivel, más la salida cruda del script invitado:

```bash
tail -f "$(ls -t ~/.local/share/vboxdisk/state/*.log | head -1)"
```

`status` y `ld` son de solo lectura y no escriben bitácora. `make uninstall`
conserva estado, bitácoras, `vdisk.yml` y el perfil del usuario.

## Desarrollo

```bash
make lint      # shellcheck sobre src/vboxdisk y src/lib/*.sh
make test      # bats tests/  (usa un doble de VBoxManage en tests/bin)
```

```
src/vboxdisk            punto de entrada: solo orquesta y despacha
src/lib/common.sh       registro, cronómetros, etapas, confirmaciones, códigos
src/lib/cli.sh          análisis de argumentos y ayuda
src/lib/config.sh       lectura y validación de vdisk.yml con yq
src/lib/state.sh        state.lock y bitácoras (rutas XDG)
src/lib/vbox.sh         todas las llamadas a VBoxManage
src/lib/storage.sh      discos en el host: huellas, plan, creación, retiro
src/lib/guest_ensure.sh único fichero que corre dentro de la vm (3 guardas)
src/lib/apply.sh        las cinco etapas de apply
src/lib/queries.sh      órdenes de solo lectura status y ld
tests/                  BATS + fixtures + doble de VBoxManage
documento/              informe LaTeX y diagramas PlantUML
```

Las pruebas se aíslan con `VBOXDISK_STATE_DIR` y el doble de `VBoxManage`
registra sus invocaciones, así que corren sin vm ni privilegios.

## Licencia

Apache License 2.0 - ver [`LICENSE`](LICENSE).
