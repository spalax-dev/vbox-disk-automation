## Index

* [storage_desired_hash](#storage_desired_hash)
* [storage_disk_desired_hash](#storage_disk_desired_hash)
* [storage_disk_file](#storage_disk_file)
* [storage_fingerprint](#storage_fingerprint)
* [storage_disk_fingerprint](#storage_disk_fingerprint)
* [storage_disk_attached](#storage_disk_attached)
* [storage_attachment](#storage_attachment)
* [storage_medium_uuid](#storage_medium_uuid)
* [storage_ctl_index](#storage_ctl_index)
* [storage_ctl_field](#storage_ctl_field)
* [storage_pick_port](#storage_pick_port)
* [storage_ensure_portcount](#storage_ensure_portcount)
* [storage_require_space](#storage_require_space)
* [storage_ensure_medium](#storage_ensure_medium)
* [storage_ensure_detached](#storage_ensure_detached)
* [storage_delete_medium](#storage_delete_medium)
* [storage_orphan_disks](#storage_orphan_disks)
* [storage_plan_vm](#storage_plan_vm)
* [guest_snapshot](#guest_snapshot)
* [guest_restore](#guest_restore)
* [storage_parse_guest_output](#storage_parse_guest_output)
* [storage_drift](#storage_drift)
* [storage_require_exit](#storage_require_exit)
* [storage_require_mounted](#storage_require_mounted)
* [storage_require_fstab](#storage_require_fstab)
* [storage_require_fstype](#storage_require_fstype)
* [storage_require_mountpoint](#storage_require_mountpoint)
* [storage_verify_guest](#storage_verify_guest)

### storage_desired_hash

sha256 del bloque declarado de la vm convertido a JSON: la
referencia contra la que se compara el estado registrado en state.lock.

#### Arguments

* **$1** (string): Nombre de la vm en el archivo declarativo.

#### Output on stdout

* sha256 en hexadecimal de 64 caracteres, con salto de linea.

### storage_disk_desired_hash

sha256 del bloque de un disco declarado, para comparar ese disco
concreto con su registro en state.lock.

#### Arguments

* **$1** (string): Nombre de la vm en el archivo declarativo.
* **$2** (string): Clave del disco bajo la vm (nombre del nodo en 'disks').

#### Output on stdout

* sha256 en hexadecimal de 64 caracteres, con salto de linea.

### storage_disk_file

Fichero .vdi de un disco declarado. Si el archivo no fija 'file',
el nombre sale del directorio de la maquina y de la clave del disco.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco declarado.

#### Exit codes

* **0**: Ruta resuelta (propia o derivada de la maquina).
* **1**: No se pudo resolver la ruta.

#### Output on stdout

* Ruta del fichero .vdi, sin salto de linea.

#### Output on stderr

* log_error si no se pudo derivar el fichero.

### storage_fingerprint

Huella fisica de toda la configuracion de almacenamiento de la
maquina: controladores y MAC reportados por showvminfo, mas el fichero y la
adjuncion de cada disco declarado (sin VMState, para que la huella de una vm
apagada coincida con la registrada). Un disco sin fichero se aporta como
"<disco> sin fichero".

#### Arguments

* **$1** (string): Nombre de la vm en el hipervisor.

#### Output on stdout

* sha256 en hexadecimal de 64 caracteres, con salto de linea.

### storage_disk_fingerprint

Huella fisica de un disco: estado del fichero en el host (mtime y
tamano), su ruta y la linea de adjuncion en showvminfo.

#### Arguments

* **$1** (string): Nombre de la vm en el hipervisor.
* **$2** (path): Ruta del fichero .vdi; si no existe se huella como "ausente".

#### Output on stdout

* sha256 en hexadecimal de 64 caracteres, con salto de linea.

### storage_disk_attached

Indica si showvminfo ya menciona el fichero, es decir, si el
disco esta adjunto a la maquina.

#### Arguments

* **$1** (string): Nombre de la vm en el hipervisor.
* **$2** (path): Ruta del fichero .vdi.

#### Exit codes

* **0**: El disco figura adjunto.
* **1**: El disco no figura adjunto o no se pudo consultar la vm.

### storage_attachment

Imprime donde esta adjunto el fichero. En el formato legible por
maquina la linea de adjuncion es "CTL-N-0"="<fichero>": la clave lleva
comillas, por lo que el fichero es el cuarto campo.

#### Arguments

* **$1** (string): Nombre de la vm en el hipervisor.
* **$2** (path): Ruta del fichero .vdi.

#### Output on stdout

* "<controlador> <puerto>" sin salto de linea; sin adjuncion no imprime nada.

### storage_medium_uuid

Identificador del medio en el hipervisor (ImageUUID del puerto
donde esta adjunto el fichero).

#### Arguments

* **$1** (string): Nombre de la vm en el hipervisor.
* **$2** (path): Ruta del fichero .vdi, que debe figurar adjunto.

#### Exit codes

* **0**: UUID impreso.
* **1**: El fichero no figura adjunto o no se pudo consultar la vm.

#### Output on stdout

* UUID del medio con salto de linea.

### storage_ctl_index

Indice numerico del controlador en las claves
storagecontroller<campo><indice> de showvminfo.

#### Arguments

* **$1** (string): Salida completa de VBoxManage showvminfo --machinereadable.
* **$2** (string): Nombre del controlador, tal como aparece en storagecontrollername<indice>.

#### Output on stdout

* El indice (p. ej. "0") con salto de linea; vacio si no figura.

### storage_ctl_field

Valor de la clave storagecontroller<campo><indice> de showvminfo.

#### Arguments

* **$1** (string): Salida completa de VBoxManage showvminfo --machinereadable.
* **$2** (string): Campo de la clave, p. ej. "portcount" o "maxportcount".
* **$3** (int): Indice del controlador, tal como lo devuelve storage_ctl_index().

#### Output on stdout

* Valor de la clave con salto de linea; vacio si no existe.

### storage_pick_port

Imprime un puerto libre del controlador preferido de la maquina.
La pertenencia de un puerto se decide sobre las lineas "CTL-N-0"="medio" de
showvminfo: la clave va entre comillas, y una linea con valor none marca un
puerto existente sin medio, que por tanto esta libre. El limite superior es el
maxportcount del controlador, no el portcount vigente, porque un puerto aun no
ampliado sigue siendo un destino valido. Prefiere cualquier controlador
distinto de IDE.

#### Arguments

* **$1** (string): Nombre de la vm en el hipervisor.

#### Exit codes

* **0**: Puerto libre encontrado.
* **3**: VBOXDISK_E_STORAGE: showvminfo fallo, la vm no tiene controladores o no hay puertos libres.

#### Output on stdout

* "<controlador> <puerto>" sin salto de linea.

#### Output on stderr

* log_error si la vm no tiene controladores o no queda ningun puerto libre.

#### See also

* [storage_ctl_index()](#storage_ctl_index)
* [storage_ctl_field()](#storage_ctl_field)

### storage_ensure_portcount

Amplia el PortCount del controlador cuando el puerto elegido queda
fuera del rango vigente; el hipervisor rechaza la adjuncion en un puerto
inexistente. Sin dato legible no se toca nada y la adjuncion decide.

#### Arguments

* **$1** (string): Nombre de la vm en el hipervisor.
* **$2** (string): Nombre del controlador.
* **$3** (int): Puerto elegido (base 0) que debe quedar dentro del portcount.

#### Exit codes

* **0**: El puerto ya esta en rango, el controlador no es consultable o quedo ampliado.
* **3**: VBOXDISK_E_STORAGE: no se pudo leer showvminfo ni ampliar el controlador.

#### Output on stderr

* log_error si falla la ampliacion, log_info al ampliar y la salida cruda de VBoxManage.

### storage_require_space

Comprueba que el ancestro mas profundo existente del fichero
declarado tiene espacio para el disco que se va a crear. Se comprueba antes de
createmedium, para no dejar un medio a medias.

#### Arguments

* **$1** (path): Ruta declarada del disco .vdi; los directorios inexistentes se remontan al ancestral existente.
* **$2** (int): Tamano del disco en MB (se convierte a bytes: MB * 1024 * 1024).

#### Exit codes

* **0**: Hay espacio suficiente o no se pudo medir.
* **1**: Espacio insuficiente (codigo propio, no VBOXDISK_E_STORAGE).

#### Output on stderr

* log_warn si no se pudo medir el espacio (se continua sin esa comprobacion); log_error si falta espacio.

### storage_ensure_medium

Crea y adjunta el disco declarativo. Si el fichero ya existe solo
se adjunta; si la vm esta encendida exige confirmacion, porque la adjuncion
implica detener la maquina (el llamador la vuelve a encender despues).

#### Arguments

* **$1** (string): Nombre de la vm en el hipervisor.
* **$2** (path): Ruta del fichero .vdi a crear y adjuntar.
* **$3** (int): Tamano del disco en MB, usado solo si hay que crearlo.

#### Exit codes

* **0**: El disco ya estaba adjunto o quedo creado y adjunto.
* **2**: VBOXDISK_E_COMM: no se pudo detener la maquina para adjuntar.
* **3**: VBOXDISK_E_STORAGE: sin espacio, sin puerto, fallo al crear o al adjuntar.
* **4**: VBOXDISK_E_CANCEL: el usuario rechazo la confirmacion.

#### Output on stderr

* log_info, log_warn y log_error, mas la salida cruda de VBoxManage.

#### See also

* [confirm()](common.md#confirm)
* [storage_pick_port()](#storage_pick_port)

### storage_ensure_detached

Retira el disco del hipervisor sin borrarlo. En una maquina
encendida se intenta primero el desprendimiento en caliente y, si el
hipervisor lo rechaza, se apaga y se reintenta.

#### Arguments

* **$1** (string): Nombre de la vm en el hipervisor.
* **$2** (path): Ruta del fichero .vdi a desprender.

#### Exit codes

* **0**: El disco quedo desprendido (o ya estaba desprendido).
* **3**: VBOXDISK_E_STORAGE: no se localizo el controlador o el desprendimiento fallo.

#### Output on stderr

* log_info, log_warn y log_error, mas la salida cruda de VBoxManage.

### storage_delete_medium

Elimina del hipervisor y del host un disco de datos ya desprendido.
Nunca se toca un medio todavia adjunto ni nada que no sea un fichero .vdi de
datos, de modo que el disco del sistema queda fuera del alcance de la orden.
Si el fichero ya no existe en el host solo se cierra el medio.

#### Arguments

* **$1** (string): Nombre de la vm, para los mensajes de error.
* **$2** (path): Ruta del fichero .vdi; debe terminar en ".vdi".

#### Exit codes

* **0**: Medio cerrado y fichero borrado (o el fichero ya no existia).
* **3**: VBOXDISK_E_STORAGE: fichero no admitido, sigue adjunto, es la configuracion de la vm o fallo al eliminar.

#### Output on stderr

* log_info y log_error, mas la salida cruda de VBoxManage.

### storage_orphan_disks

Lista los discos registrados en state.lock que el archivo
declarativo ya no menciona y que siguen pendientes de decision; los que
quedaron inactivos se consideran resueltos.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Output on stdout

* Una clave de disco por linea, en orden de registro; nada si no hay huerfanos.

### storage_plan_vm

Plan de la verificacion declarativa en el host, sin tocar la
maquina (usado por --dry-run). No escribe en state.lock.

#### Arguments

* **$1** (string): Nombre de la vm, declarada o no en el archivo declarativo.

#### Output on stdout

* Una unica linea "<vm>: <plan> (estado actual: <potencia>)"; el plan lleva entre parentesis el detalle de los discos cuando lo hay.

### guest_snapshot

Conserva los campos GUEST_* de la ultima corrida del disco en las
copias por disco, para verificar cada uno en la etapa final aunque despues se
hayan ejecutado otras corridas invitado.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco; la copia se guarda bajo la clave "<vm>/<disco>".

#### Variables set

* **GUEST_S_EXIT** (array): Copia de GUEST_EXIT para "<vm>/<disco>".
* **GUEST_S_DEVICE** (array): Copia de GUEST_DEVICE para "<vm>/<disco>".
* **GUEST_S_TABLE** (array): Copia de GUEST_TABLE para "<vm>/<disco>".
* **GUEST_S_FSTYPE** (array): Copia de GUEST_FSTYPE para "<vm>/<disco>".
* **GUEST_S_UUID** (array): Copia de GUEST_UUID para "<vm>/<disco>".
* **GUEST_S_MOUNTED** (array): Copia de GUEST_MOUNTED para "<vm>/<disco>".
* **GUEST_S_MOUNTPOINT** (array): Copia de GUEST_MOUNTPOINT para "<vm>/<disco>".
* **GUEST_S_FSTAB** (array): Copia de GUEST_FSTAB para "<vm>/<disco>".
* **GUEST_S_LINES** (array): Copia de GUEST_TABLE_LINES para "<vm>/<disco>".

#### See also

* [guest_restore()](#guest_restore)

### guest_restore

Recarga en GUEST_* la copia conservada del disco; sin copia previa
los campos quedan vacios.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco; la copia se lee de la clave "<vm>/<disco>".

#### Variables set

* **GUEST_EXIT** (string): Restaurada desde GUEST_S_EXIT.
* **GUEST_DEVICE** (string): Restaurada desde GUEST_S_DEVICE.
* **GUEST_TABLE** (string): Restaurada desde GUEST_S_TABLE.
* **GUEST_FSTYPE** (string): Restaurada desde GUEST_S_FSTYPE.
* **GUEST_UUID** (string): Restaurada desde GUEST_S_UUID.
* **GUEST_MOUNTED** (string): Restaurada desde GUEST_S_MOUNTED.
* **GUEST_MOUNTPOINT** (string): Restaurada desde GUEST_S_MOUNTPOINT.
* **GUEST_FSTAB** (string): Restaurada desde GUEST_S_FSTAB.
* **GUEST_TABLE_LINES** (string): Restaurada desde GUEST_S_LINES.

#### See also

* [guest_snapshot()](#guest_snapshot)

### storage_parse_guest_output

Extrae los pares clave=valor y la tabla de la salida del script
invitado (emit_state) y los deja en los globales GUEST_*. Cada corrida
sustituye a la anterior: los campos ausentes quedan vacios.

#### Arguments

* **$1** (string): Salida completa del script invitado, multilinea.

#### Variables set

* **GUEST_EXIT** (string): Valor de VBOXDISK_EXIT (codigo de salida del invitado).
* **GUEST_DEVICE** (string): Valor de DEVICE.
* **GUEST_TABLE** (string): Valor de TABLE.
* **GUEST_FSTYPE** (string): Valor de FSTYPE.
* **GUEST_UUID** (string): Valor de UUID.
* **GUEST_MOUNTED** (string): Valor de MOUNTED ("yes" cuando quedo montado).
* **GUEST_MOUNTPOINT** (string): Valor de MOUNTPOINT.
* **GUEST_FSTAB** (string): Valor de FSTAB ("yes" cuando quedo en fstab).
* **GUEST_TABLE_LINES** (string): Todas las TABLE_LINE concatenadas con saltos de linea.
* **GUEST_NOTE** (string): Ultima nota "guest_ensure: " emitida por el invitado.

### storage_drift

Detecta modificacion externa: compara los campos actuales de
GUEST_* con el ultimo registro conocido en state.lock (kv_device, kv_table,
kv_fstype, kv_uuid, kv_mounted, kv_fstab). Las claves sin registro previo no
generan deriva.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco.

#### Exit codes

* **0**: Sin deriva: todo coincide o no hay registro previo.
* **1**: Al menos una clave difiere del registro.

#### Output on stderr

* log_warn por cada clave con deriva, con el valor registrado y el actual.

### storage_require_exit

Comprueba que el script invitado termino con exito.

#### Arguments

* **$1** (string): Identificador "<vm>/<disco>" que encabeza el mensaje de error.

#### Exit codes

* **0**: GUEST_EXIT vale 0.
* **1**: El invitado fallo o su codigo no quedo registrado.

#### Output on stderr

* log_error si el invitado no termino con 0.

### storage_require_mounted

Comprueba que el punto de montaje quedo montado en el invitado.

#### Arguments

* **$1** (string): Identificador "<vm>/<disco>" que encabeza el mensaje de error.
* **$2** (path): Punto de montaje declarado, citado en el mensaje de error.

#### Exit codes

* **0**: GUEST_MOUNTED vale "yes".
* **1**: GUEST_MOUNTED es distinto de "yes".

#### Output on stderr

* log_error si no quedo montado.

### storage_require_fstab

Comprueba que el montaje quedo declarado en /etc/fstab.

#### Arguments

* **$1** (string): Identificador "<vm>/<disco>" que encabeza el mensaje de error.
* **$2** (path): Entrada declarada en fstab, citada en el mensaje de error.

#### Exit codes

* **0**: GUEST_FSTAB vale "yes".
* **1**: GUEST_FSTAB es distinto de "yes".

#### Output on stderr

* log_error si no quedo declarado.

### storage_require_fstype

Comprueba que el sistema de archivos instalado es el declarado.

#### Arguments

* **$1** (string): Identificador "<vm>/<disco>" que encabeza el mensaje de error.
* **$2** (string): Tipo de filesystem declarado (p. ej. ext4).

#### Exit codes

* **0**: GUEST_FSTYPE coincide con lo declarado.
* **1**: GUEST_FSTYPE difiere de lo declarado.

#### Output on stderr

* log_error si el tipo instalado difiere del declarado.

### storage_require_mountpoint

Comprueba que el volumen quedo montado en la ruta declarada.

#### Arguments

* **$1** (string): Identificador "<vm>/<disco>" que encabeza el mensaje de error.
* **$2** (path): Ruta de montaje declarada.

#### Exit codes

* **0**: GUEST_MOUNTPOINT coincide con lo declarado.
* **1**: GUEST_MOUNTPOINT difiere de lo declarado.

#### Output on stderr

* log_error si el volumen quedo montado en otra ruta.

### storage_verify_guest

Orquesta la comprobacion final de la convergencia de un disco;
en cuanto alguna propiedad esperada no se cumple, devuelve el codigo de
almacenamiento y detiene la corrida de la vm. Traduce cualquier fallo de las
comprobaciones al codigo 3.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco; lee fs_type y mount_point del archivo declarativo.

#### Exit codes

* **0**: Todas las propiedades del invitado coinciden con lo declarado.
* **3**: VBOXDISK_E_STORAGE: alguna propiedad no coincide.

#### Output on stderr

* Mensajes de log_error de la comprobacion que falle.

#### See also

* [storage_require_exit()](#storage_require_exit)
* [storage_require_mounted()](#storage_require_mounted)
* [storage_require_fstab()](#storage_require_fstab)
* [storage_require_fstype()](#storage_require_fstype)
* [storage_require_mountpoint()](#storage_require_mountpoint)

