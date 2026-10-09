## Index

* [cfg_is_reserved](#cfg_is_reserved)
* [cfg_is_legacy](#cfg_is_legacy)
* [cfg_is_disk_key](#cfg_is_disk_key)
* [cfg_vms](#cfg_vms)
* [cfg_get](#cfg_get)
* [cfg_disk_keys](#cfg_disk_keys)
* [cfg_disk_get](#cfg_disk_get)
* [cfg_disk_size_mb](#cfg_disk_size_mb)
* [cfg_disk_state](#cfg_disk_state)
* [cfg_validate_file](#cfg_validate_file)
* [cfg_validate_name](#cfg_validate_name)
* [cfg_validate_keys](#cfg_validate_keys)
* [cfg_validate_required](#cfg_validate_required)
* [cfg_validate_credentials](#cfg_validate_credentials)
* [cfg_validate_disks](#cfg_validate_disks)
* [cfg_validate](#cfg_validate)
* [cfg_each_vm](#cfg_each_vm)
* [cfg_sync_begin](#cfg_sync_begin)
* [cfg_sync_vm](#cfg_sync_vm)
* [cfg_sync_disk](#cfg_sync_disk)
* [cfg_sync_commit](#cfg_sync_commit)
* [cfg_sync_discard](#cfg_sync_discard)

### cfg_is_reserved

Indica si una clave pertenece al conjunto reservado de vdisk.yml.

#### Arguments

* **$1** (string): Clave a comprobar.

#### Exit codes

* **0**: La clave está reservada.
* **1**: La clave no está reservada.

### cfg_is_legacy

Indica si una clave pertenece al esquema anterior de discos planos.

#### Arguments

* **$1** (string): Clave a comprobar.

#### Exit codes

* **0**: La clave es del esquema antiguo (disk_file, disk_size_mb, ...).
* **1**: La clave no pertenece al esquema antiguo.

### cfg_is_disk_key

Indica si una clave pertenece al conjunto admitido de un disco.

#### Arguments

* **$1** (string): Clave a comprobar.

#### Exit codes

* **0**: La clave es válida dentro del bloque 'disks'.
* **1**: La clave no es válida dentro del bloque 'disks'.

### cfg_vms

Enumera las claves de primer nivel de $VBOXDISK_FILE, es decir,
las vm declaradas en el fichero.

_Function has no arguments._

#### Output on stdout

* Un nombre de vm por línea.

#### See also

* [cfg_each_vm()](#cfg_each_vm)

### cfg_get

Lee una clave de una vm con la precedencia entorno VBOXDISK_* > yml > cadena vacía.
La variable de entorno se forma en mayúsculas (vm_user -> VBOXDISK_VM_USER);
si está definida pero vacía, manda el valor del yml.

#### Example

```bash
cfg_get web vm_user  # imprime VBOXDISK_VM_USER o el valor de vdisk.yml
```

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave a leer (p. ej. vm_user, vm_pass_file).

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* El valor resuelto, sin salto de línea; cadena vacía si no está definida en ninguna parte.

### cfg_disk_keys

Enumera las claves (nombres) de los discos que declara una vm.
Los errores de yq se silencian: un bloque ausente produce salida vacía.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (path): Fichero YAML del que leer (no usa $VBOXDISK_FILE).

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* Un nombre de disco por línea; cadena vacía si no hay discos.

### cfg_disk_get

Lee una clave de un disco concreto de una vm.
No aplica precedencia de variables de entorno, porque la precedencia rige
solo a nivel de máquina.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco dentro de 'disks'.
* **$3** (string): Clave a leer (label, size, fs_type, mount_point, file, state).
* **$4** (path): Fichero YAML; por defecto $VBOXDISK_FILE. El cuarto argumento permite leer un fichero distinto del declarado, que es lo que hace la validación al examinar otro archivo.

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* El valor o cadena vacía si la clave no existe.

### cfg_disk_size_mb

Tamaño de un disco convertido a megabytes.
Admite un entero (megabytes) o una cifra con sufijo m|g|t.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco.

#### Exit codes

* **0**: El tamaño se pudo interpretar.
* **1**: La declaración no es un tamaño legible; no se imprime nada.

#### Output on stdout

* Tamaño entero en MB, sin unidad ni salto de línea.

#### See also

* [size_to_mb()](common.md#size_to_mb)

### cfg_disk_state

Estado deseado de un disco; 'active' si la clave no está declarada.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco.

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* 'active' o el valor declarado en 'state'.

### cfg_validate_file

Comprueba existencia, lectura y sintaxis YAML de un fichero declarativo.
Ninguna de estas comprobaciones toca el hipervisor; se detiene en el primer error.

#### Arguments

* **$1** (path): Fichero YAML a examinar.

#### Exit codes

* **0**: El fichero existe, es legible, es YAML válido y declara alguna vm.
* **1**: Alguna comprobación falló.

#### Output on stderr

* Un log_error por el problema detectado.

### cfg_validate_name

Comprueba la forma admitida de un nombre de vm:
^[A-Za-z_][A-Za-z0-9_-]*$ (letra o guion bajo al inicio; después letras,
dígitos, '_' o '-').

#### Arguments

* **$1** (string): Nombre de la vm a validar.

#### Exit codes

* **0**: Nombre válido.
* **1**: Nombre inválido.

#### Output on stderr

* log_error si el nombre no es válido.

### cfg_validate_keys

Valida que todas las claves del bloque de la vm sean reservadas
y no pertenezcan al esquema anterior de discos planos.
Acumula todos los errores del bloque, sin detenerse en el primero.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (path): Fichero YAML del que leer.

#### Exit codes

* **0**: Todas las claves del bloque son válidas.
* **1**: Hay alguna clave rechazada.

#### Output on stderr

* Un log_error por cada clave antigua o no reservada.

### cfg_validate_required

Valida que las claves obligatorias estén presentes y que 'disks'
sea un mapa de discos.
'disks' puede faltar, venir nulo o ser un mapa vacio: la maquina todavia no
declara ningun disco, que es el caso de un fichero recien creado o de una
maquina a la que se le retiran todos. Solo se rechaza si trae otra cosa que
un mapa (una lista o un valor simple).
Acumula todos los errores del bloque, sin detenerse en el primero.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (path): Fichero YAML del que leer.

#### Exit codes

* **0**: El bloque cumple lo obligatorio.
* **1**: Falta alguna clave obligatoria o 'disks' no es un mapa.

#### Output on stderr

* log_error por cada obligatoria ausente y por 'disks' mal formado.

### cfg_validate_credentials

Valida que exista una credencial declarada y legible: bien en
claro con 'vm_pass' o en fichero con 'vm_pass_file'.
Acumula ambos errores si los hay.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (path): Fichero YAML del que leer.

#### Exit codes

* **0**: Hay una credencial declarada y legible.
* **1**: No hay credencial o 'vm_pass_file' no se puede leer.

#### Output on stderr

* log_error si falta la credencial y/o si 'vm_pass_file' es ilegible.

### cfg_validate_disks

Valida la forma de cada disco declarado por la vm y la unicidad
de etiqueta y de punto de montaje dentro de la máquina.
Revisa nombre de clave, claves admitidas, obligatorias, label (máx. 12
caracteres en xfs, 16 en ext4), size legible, fs_type (ext4|xfs),
mount_point absoluto distinto de '/', file absoluto y state
(active|inactive). Los discos 'inactive' no participan en la unicidad de
montaje. Acumula los errores y sigue con el disco siguiente; si a un disco
le falta una clave obligatoria se omiten el resto de sus comprobaciones.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (path): Fichero YAML del que leer.

#### Exit codes

* **0**: Todos los discos de la vm son válidos.
* **1**: Algún disco tiene defectos.

#### Output on stderr

* Un log_error por cada defecto detectado.

### cfg_validate

Validación completa del fichero declarativo antes de tocar el hipervisor.
Ordena por etapas: primero el fichero como tal (se detiene en su primer
error) y, después, cada vm contra su nombre, sus claves, sus obligatorias,
su credencial y sus discos. Acumula todos los errores del fichero y devuelve
1 si alguno falló, sin detenerse en el primero.

#### Arguments

* **$1** (path): Fichero YAML a validar.

#### Exit codes

* **0**: El fichero pasa todas las comprobaciones.
* **1**: Alguna comprobación falló.

#### Output on stderr

* Todos los errores acumulados, vía log_error.

### cfg_each_vm

Alias de cfg_vms() para recorrer las máquinas declaradas.

_Function has no arguments._

#### Output on stdout

* Un nombre de vm por línea.

#### See also

* [cfg_vms()](#cfg_vms)

### cfg_sync_begin

Prepara la sincronizacion: copia el archivo declarativo a un
hermano temporal y guarda ademas un respaldo del original. La copia es la
unica que se modifica hasta cfg_sync_commit, de modo que un error de
validacion deja el archivo como estaba.

_Function has no arguments._

#### Variables set

* **VBOXDISK_SYNC_TMP** (path): Copia temporal abierta; vacia si no se pudo abrir.

#### Exit codes

* **0**: Copia y respaldo listos.
* **1**: El archivo no existe, no es escribible o no se pudo copiar.

#### Output on stderr

* log_error si el archivo no se puede leer o copiar; log_warn si el respaldo no se pudo guardar.

#### See also

* [cfg_sync_commit()](#cfg_sync_commit)
* [cfg_sync_discard()](#cfg_sync_discard)

### cfg_sync_vm

Declara en la copia temporal el bloque de una vm que el
archivo no contempla, con las credenciales pedidas al usuario. Si el bloque
ya existe no se toca: una maquina declarada conserva su credencial y solo
sus discos se sincronizan.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Usuario declarado.
* **$3** (string): Contrasena en claro; vacia cuando la credencial es un fichero.
* **$4** (path): Fichero con la contrasena; vacio si la contrasena va en claro.

#### Variables set

* **VBOXDISK_SYNC_TMP** (path): Abre la copia temporal si no estaba abierta.

#### Exit codes

* **0**: El bloque quedo declarado (o ya lo estaba).
* **1**: No se pudo declarar.

#### Output on stderr

* log_error si el nombre no esta admitido, falta el usuario o yq falla.

#### See also

* [cfg_sync_begin()](#cfg_sync_begin)

### cfg_sync_disk

Declara en la copia temporal un disco a partir de su registro
en state.lock: label, size, fs_type, mount_point y, si la ultima corrida lo
dejo escrito, file. El estado no se copia: un disco huerfano nunca esta
inactivo, y ese valor lo decide el archivo declarativo.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco.

#### Variables set

* **VBOXDISK_SYNC_TMP** (path): Abre la copia temporal si no estaba abierta.

#### Exit codes

* **0**: El disco quedo declarado.
* **1**: No se pudo declarar.

#### Output on stderr

* log_error si la clave no esta admitida, si el registro no guarda los
  datos obligatorios o si yq falla.

#### See also

* [state_get_disk()](state.md#state_get_disk)

### cfg_sync_commit

Cierra la sincronizacion: valida la copia temporal y, si pasa,
la mueve sobre el archivo declarativo. Cualquier error deja el original
intacto y descarta la copia.

_Function has no arguments._

#### Variables set

* **VBOXDISK_SYNC_TMP** (path): Se vacia al terminar.

#### Exit codes

* **0**: El archivo declarativo quedo reemplazado.
* **1**: La validacion fallo o no se pudo reemplazar; el archivo no cambia.

#### Output on stderr

* Errores de validacion de la copia y motivo del reemplazo fallido.

#### See also

* [cfg_validate()](#cfg_validate)
* [cfg_sync_discard()](#cfg_sync_discard)

### cfg_sync_discard

Descarta la copia temporal de una sincronizacion sin cerrar,
por ejemplo cuando una credencial no se pudo reunir.

_Function has no arguments._

#### Variables set

* **VBOXDISK_SYNC_TMP** (path): Se vacia.

#### Exit codes

* **0**: Siempre.

#### See also

* [cfg_sync_begin()](#cfg_sync_begin)

