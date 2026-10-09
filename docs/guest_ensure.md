## Index

* [usage](cli.md#usage)
* [finish](#finish)
* [validate_args](#validate_args)
* [emit_state](#emit_state)
* [fail](#fail)
* [assert_not_system_disk](#assert_not_system_disk)
* [device_from_label](#device_from_label)
* [device_hint_ok](#device_hint_ok)
* [detect_by_size](#detect_by_size)
* [device_from_serial](#device_from_serial)
* [detect_device](#detect_device)
* [collect](#collect)
* [wait_for_partition](#wait_for_partition)
* [ensure_label](#ensure_label)
* [ensure_growth](#ensure_growth)
* [ensure_fstab](#ensure_fstab)
* [remove_fstab_entries](#remove_fstab_entries)
* [release_mount](#release_mount)
* [converge](#converge)

### usage

Texto de uso del script invitado; quien invoca lo redirige a
stderr cuando reporta un argumento invalido.

_Function has no arguments._

#### Output on stdout

* Una linea con el uso y sus opciones obligatorias y opcionales.

### finish

Destruye el fichero de credenciales, emite la centinela
VBOXDISK_EXIT=<codigo> por stdout y termina con ese mismo codigo.

#### Arguments

* **$1** (int): Codigo de salida: 0 ok, 1 validacion o elevacion, 3 almacenamiento.

#### Exit codes

* **0**: Terminacion correcta.
* **1**: Argumentos invalidos o elevacion con sudo fallida.
* **3**: Fallo de almacenamiento (codigo por defecto de fail).

#### Output on stdout

* La centinela VBOXDISK_EXIT=<codigo>.

### validate_args

Validacion de los argumentos obligatorios antes de cualquier
accion. Cada comprobacion reporta su propio motivo de rechazo y termina con
la centinela; ninguna toca el sistema de archivos.

#### Options

* **--probe** | **--release**

  Modos incompatibles entre si.

* **--mount**

  /ruta Punto de montaje obligatorio, absoluto y distinto de /.

* **--size-mb**

  N Tamano en MB obligatorio, salvo en --release.

* **--fstype**

  ext4|xfs Tipo de sistema de archivos obligatorio, salvo en --release.

* **--label**

  ETIQUETA Obligatoria salvo en --release; [A-Za-z0-9._-], hasta 16 caracteres en ext4 y 12 en xfs.

#### Exit codes

* **0**: Argumentos validos.
* **1**: Argumentos invalidos: termina via finish con la centinela.

#### Output on stderr

* Motivo del rechazo o el texto de uso.

### emit_state

Vuelca el estado observado en pares clave=valor por stdout,
terminando con la tabla de lsblk como lineas TABLE_LINE=.

_Function has no arguments._

#### Output on stdout

* DEVICE, SIZE_MB, TABLE, PART, FSTYPE, UUID, MOUNTED, MOUNTPOINT y FSTAB, y luego TABLE_LINE=<linea> por cada renglon de lsblk.

### fail

Mensaje de error en stderr y fin con la centinela (codigo 3,
almacenamiento, si no se indica otro).

#### Arguments

* **$1** (string): Mensaje del fallo; se antepone "guest_ensure: ".
* **$2** (int): Codigo de salida opcional; por defecto 3.

#### Exit codes

* **3**: Codigo por defecto cuando no se indica otro.
* **1**: Codigo explicito en $2 (el unico que se pasa en este script).

#### Output on stderr

* El mensaje del fallo con el prefijo "guest_ensure: ".

#### See also

* [finish()](#finish)

### assert_not_system_disk

El destino nunca es el disco que contiene la raiz; si lo es,
la corrida se detiene sin tocar nada.

#### Arguments

* **$1** (string): Dispositivo objetivo; si esta vacio o no es de bloque no hace nada.

#### Exit codes

* **0**: El destino no es el disco del sistema (o no es de bloque).
* **1**: Termina via fail cuando el destino es o contiene la raiz.

#### Output on stderr

* Mensaje de rechazo cuando el destino es el disco del sistema.

### device_from_label

Disco que contiene el sistema de archivos con esa etiqueta; la
particion se eleva a su disco contenedor, porque las guardas se aplican
siempre sobre el disco completo.

#### Arguments

* **$1** (string): Etiqueta del sistema de archivos.

#### Exit codes

* **0**: Encontro el disco.
* **1**: No hay ningun dispositivo de bloque con esa etiqueta.

#### Output on stdout

* El dispositivo (/dev/sdX) sin salto de linea.

### device_hint_ok

La pista del host solo vale si el dispositivo existe y su
tamano coincide con el declarado en SIZE_MB (tolerancia de 1 MB); en
cualquier otro caso la deteccion sigue por el tamano.

#### Arguments

* **$1** (string): Dispositivo sugerido por el host, p. ej. /dev/sdb.

#### Exit codes

* **0**: El dispositivo existe y su tamano difiere 1 MB o menos.
* **1**: No es un dispositivo de bloque o el tamano difiere mas de 1 MB.

### detect_by_size

El disco cuyo tamano coincide con el declarado (SIZE_MB,
tolerancia de 1 MB), siempre que no tenga etiqueta (esa se identifica por su
etiqueta), ni montajes, ni la raiz; dos candidatos iguales no se desempatan
a ciegas.

_Function has no arguments._

#### Variables set

* **G_DEV** (string): Disco identificado.

#### Exit codes

* **0**: Un unico candidato; deja el disco en G_DEV.
* **1**: Ningun candidato o varios candidatos sin desempatar.

#### Output on stderr

* Explica la ambiguedad o la ausencia de candidatos.

### device_from_serial

El disco que el hipervisor identifica con el numero de serie
que publica en el invitado para el medio declarado. VirtualBox lo compone
como "VB" mas los ocho primeros caracteres del UUID del medio y un sufijo
de control, y el host conoce ese UUID: con varios discos recien creados del
mismo tamano, sin etiqueta y sin montar, el numero de serie los desempata
sin arriesgarse a formatear otro disco.

_Function has no arguments._

#### Variables set

* **G_DEV** (string): Disco identificado.

#### Exit codes

* **0**: Un unico disco con ese numero de serie; deja el disco en G_DEV.
* **1**: Sin --serial o sin coincidencia.

#### Output on stderr

* No avisa; la ambiguedad o la ausencia las reporta detect_device.

### detect_device

La etiqueta declarada, y si el disco aun no la tiene, el numero
de serie del medio, la pista del host y despues el tamano. Devuelve 1 sin
tocar el sistema; quien decide si el fallo detiene la corrida es el flujo
principal.

_Function has no arguments._

#### Variables set

* **G_DEV** (string): Disco identificado.

#### Exit codes

* **0**: Disco identificado.
* **1**: Ningun metodo identifico el disco.

#### See also

* [device_from_label()](#device_from_label)
* [device_from_serial()](#device_from_serial)
* [device_hint_ok()](#device_hint_ok)

### collect

Observa el dispositivo actual sin modificarlo y rellena las
variables G_* (tabla, particion, fs, UUID, montaje y fstab).

_Function has no arguments._

#### Variables set

* **G_PART** (string): Primera particion del disco, o la que lleva la etiqueta declarada si pertenece a el; vacia si no hay.
* **G_TABLE** (string): Tipo de tabla de particiones (gpt, dos) o none.
* **G_FSTYPE** (string): Sistema de archivos de la particion, vacio si no existe.
* **G_UUID** (string): UUID de la particion, vacio si no existe.
* **G_MOUNTED** (string): "yes" si MOUNT esta montado, "no" en caso contrario.
* **G_FSTAB** (string): "yes" si /etc/fstab ya declara el UUID, "no" en caso contrario.
* **G_SIZE_MB** (int): Tamano del disco en MB; 0 si el dispositivo no existe.

#### Exit codes

* **0**: Siempre.

### wait_for_partition

Aguarda hasta 15 s a que udev publique la particion recien
creada por sfdisk.

_Function has no arguments._

#### Variables set

* **G_PART** (string): Particion publicada por el kernel.

#### Exit codes

* **0**: La particion aparecio en el plazo.
* **1**: No aparecio tras 15 segundos.

### ensure_label

Aplica la etiqueta declarada si difiere de la actual (e2label en
ext4, xfs_admin en xfs); no hace nada sin etiqueta declarada ni sin particion.

_Function has no arguments._

#### Exit codes

* **0**: Siempre; un fallo de la herramienta no detiene la corrida.

### ensure_growth

Amplia la particion hasta el final del medio cuando el anfitrion
crecio el disco declarado, y con ella el sistema de archivos. Solo se actua si
la particion no alcanza el tamano declarado, de modo que una corrida sin
crecimiento no vuelve a tocar nada. Se invoca con el montaje ya resuelto,
porque xfs solo crece sobre un punto de montaje.

_Function has no arguments._

#### Exit codes

* **0**: Sin crecimiento pendiente o crecimiento concluido.
* **3**: El medio no crecio, no se localizo la particion, el kernel no tomo

#### Output on stderr

* Nota de ampliacion y la salida de sfdisk, partx, resize2fs o xfs_growfs.

#### See also

* [collect()](#collect)
* [fail()](#fail)

### ensure_fstab

Anade la entrada UUID a /etc/fstab al montar solo si aun no
existe; pass 0 en xfs y 2 en ext4, segun la convencion de fsck.

_Function has no arguments._

#### Exit codes

* **0**: Siempre; sin entrada que agregar tambien.

#### Output on stderr

* Confirma la entrada agregada.

### remove_fstab_entries

Retira de /etc/fstab las lineas que declaran el punto de
montaje (o la etiqueta, si se conoce); no cambia los permisos del fichero
porque el contenido se reescribe sobre el mismo inode.

_Function has no arguments._

#### Exit codes

* **0**: Siempre; sin entrada que retirar tambien.

#### Output on stderr

* Confirma la entrada retirada para el punto de montaje.

### release_mount

El retiro total de un disco inactivo o eliminado: desmonta el
punto declarado y borra su entrada persistente, sin modificar el disco.

_Function has no arguments._

#### Exit codes

* **0**: Desmontaje y fstab resueltos (o ya resueltos).
* **3**: Termina via fail si el desmontaje no se pudo completar.

#### Output on stderr

* Avisa del desmontaje o de que el punto no estaba montado.

### converge

Aplicacion de las tres guardas en orden (tabla de particiones,
sistema de archivos, montaje y fstab), cada una tras comprobar que su
condicion aun no se cumple.

_Function has no arguments._

#### Exit codes

* **0**: Las tres guardas quedaron satisfechas.
* **3**: Termina via fail ante cualquier guarda fallida.

#### Output on stderr

* Progreso de cada guarda, avisos de montaje y el resumen con df -h.

