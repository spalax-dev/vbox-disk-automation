## Index

* [state_dir](#state_dir)
* [state_lock_file](#state_lock_file)
* [state_log_dir](#state_log_dir)
* [state_init_dirs](#state_init_dirs)
* [state_get](#state_get)
* [state_get_disk](#state_get_disk)
* [state_disk_keys](#state_disk_keys)
* [state_vms](#state_vms)
* [state_set_vm](#state_set_vm)
* [state_update_vm](#state_update_vm)
* [state_remove_prefix](#state_remove_prefix)
* [state_remove_disk](#state_remove_disk)
* [state_remove_vm](#state_remove_vm)
* [state_table_b64](#state_table_b64)
* [state_encode_table](#state_encode_table)
* [state_open_log](#state_open_log)

### state_dir

Directorio de estado de vboxdisk.
Precedencia: VBOXDISK_STATE_DIR (usado en pruebas) > $XDG_DATA_HOME/vboxdisk
> ~/.local/share/vboxdisk.

_Function has no arguments._

#### Output on stdout

* La ruta, sin salto de línea.

### state_lock_file

Ruta completa del fichero de bloqueo state.lock (una entrada por vm).

_Function has no arguments._

#### Output on stdout

* La ruta, sin salto de línea.

#### See also

* [state_dir()](#state_dir)

### state_log_dir

Directorio de las bitácoras por ejecución de apply.

_Function has no arguments._

#### Output on stdout

* La ruta, sin salto de línea.

#### See also

* [state_dir()](#state_dir)

### state_init_dirs

Crea el directorio de estado y el de bitácoras si aún no existen.

_Function has no arguments._

#### Exit codes

* **0**: Directorios creados o ya existentes.
* **1**: mkdir no pudo crearlos.

### state_get

Lee una clave de la sección de una vm en state.lock.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave; las anidadas se escriben con puntos (p. ej. disks.data0.size).

#### Exit codes

* **0**: La clave existe.
* **1**: La clave no existe o no hay state.lock.

#### Output on stdout

* El valor de la clave, sin salto de línea.

#### See also

* [state_get_disk()](#state_get_disk)

### state_get_disk

Lee una clave anidada de un disco: disks.<disco>.<clave>.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco.
* **$3** (string): Clave dentro del disco (p. ej. size, table_b64).

#### Exit codes

* **0**: La clave existe.
* **1**: La clave no existe o no hay state.lock.

#### Output on stdout

* El valor de la clave, sin salto de línea.

#### See also

* [state_get()](#state_get)

### state_disk_keys

Enumera los discos registrados de la vm, en orden de registro.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* Un nombre de disco por línea; vacío si no hay state.lock ni discos.

### state_vms

Enumera las máquinas con sección en state.lock, en orden de registro.

_Function has no arguments._

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* Un nombre de vm por línea; vacío si no hay state.lock.

### state_set_vm

Reescribe o crea la sección completa de una vm en state.lock con
las claves recibidas.
La sección anterior se elimina por completo: las claves no incluidas se
pierden. Si la vm no tenía sección, esta se añade al final del fichero.

#### Arguments

* **$1** (string): Nombre de la vm.
* **...** (string): Pares 'clave=valor' que compondrán la sección, desde $2.

#### Exit codes

* **0**: Sección reescrita.

#### See also

* [state_update_vm()](#state_update_vm)

### state_update_vm

Fusiona claves en la sección de una vm sin tocar el resto.
Las claves recibidas se actualizan o se añaden al final; las ya existentes
conservan su posición original y el resto de la sección se conserva tal
cual, de modo que los discos no afectados por la corrida no pierden su
registro. Difiere de state_set_vm(), que reescribe la sección entera.

#### Arguments

* **$1** (string): Nombre de la vm.
* **...** (string): Pares 'clave=valor' a fusionar, desde $2; los que no contienen '=' se ignoran.

#### Exit codes

* **0**: Sección actualizada.

#### See also

* [state_set_vm()](#state_set_vm)

### state_remove_prefix

Retira de la sección de la vm todas las claves que empiezan por
un prefijo; una sección que queda vacía se borra por completo.
Si no hay state.lock no hace nada.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Prefijo de las claves a eliminar (p. ej. disks.data0.).

#### Exit codes

* **0**: Operación completada.

#### See also

* [state_remove_disk()](#state_remove_disk)

### state_remove_disk

Retira el registro completo de un disco de la vm.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco.

#### Exit codes

* **0**: Operación completada.

#### See also

* [state_remove_prefix()](#state_remove_prefix)

### state_remove_vm

Retira la sección completa de la vm de state.lock.
Si la vm no tiene sección o no hay state.lock, no hace nada.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Exit codes

* **0**: Operación completada.

### state_table_b64

Devuelve ya decodificada la tabla de particiones registrada de un disco.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco.

#### Exit codes

* **0**: La tabla se decodificó.
* **1**: El disco no tiene tabla registrada o el base64 no es válido.

#### Output on stdout

* La tabla de particiones en texto plano, con sus saltos de línea.

#### See also

* [state_encode_table()](#state_encode_table)

### state_encode_table

Codifica una tabla en base64 sin saltos de línea, para guardarla
como una sola clave del lock.

#### Arguments

* **$1** (string): Tabla de particiones en texto plano.

#### Output on stdout

* La tabla en base64, en una sola línea.

#### See also

* [state_table_b64()](#state_table_b64)

### state_open_log

Crea y abre una bitácora plana por ejecución de apply, con el
directorio de bitácoras creado si falta.
El nombre del fichero es la fecha y hora local con formato
AAAAmmdd-HHMMSS.log. Después escribe la cabecera de la corrida.

_Function has no arguments._

#### Variables set

* **VBOXDISK_LOG_FILE** (string): Ruta del fichero de bitácora recién creado.

#### Exit codes

* **0**: Bitácora creada y registrada.
* **1**: No se pudo crear el fichero de bitácora.

#### Output on stderr

* log_error si la bitácora no se pudo crear; después las cabeceras con log_info.

