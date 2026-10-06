## Index

* [cmd_apply](#cmd_apply)
* [guest_session_open](#guest_session_open)
* [guest_session_close](#guest_session_close)
* [guest_disk_args](#guest_disk_args)
* [guest_run](#guest_run)
* [apply_vm](#apply_vm)

### cmd_apply

Ejecuta la orden apply: valida la configuracion, aplica
--dry-run o recorre las vm una a una y agrega al final el codigo de mayor
severidad de la corrida. Nunca retorna: siempre termina con exit.

_Function has no arguments._

#### Exit codes

* **0**: Corrida sin incidencias o plan de --dry-run mostrado.
* **1**: Configuracion invalida o script invitado ausente (die_cfg).
* **2**: VBOXDISK_E_COMM: fallo de comunicacion con alguna vm.
* **3**: VBOXDISK_E_STORAGE: fallo de almacenamiento o verificacion.
* **4**: VBOXDISK_E_CANCEL: cancelado por el usuario.

#### Output on stdout

* En modo --dry-run, una linea por vm con su plan de cambios.

#### Output on stderr

* Registros de progreso (log_info/log_warn/log_error) y confirmaciones.

#### See also

* [apply_vm()](#apply_vm)

### guest_session_open

Prepara la sesion con el invitado: credenciales, directorio
temporal y copia unica del script invitado para todas las corridas de la
maquina. Deja ademas la vm en VBOXDISK_CURRENT_VM, que es de donde
vbox_guest_cleanup_all toma el destino de la limpieza si la corrida termina
sin cerrar la sesion.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Variables set

* **VBOXDISK_CURRENT_VM** (string): Vm en curso, para vbox_guest_cleanup_all.
* **VBOXDISK_GUEST_USER** (string): Usuario del invitado, para vbox_guest_run.
* **VBOXDISK_GUEST_PASSFILE** (string): Fichero de credenciales, para vbox_guest_run.
* **VBOXDISK_SESSION_DIR** (string): Directorio temporal creado en el invitado.
* **VBOXDISK_SESSION_PASS** (string): Fichero de credenciales en el host.

#### Exit codes

* **0**: Sesion preparada.
* **2**: VBOXDISK_E_COMM: sin sesion del invitado o copia fallida.

#### Output on stderr

* Errores si Guest Control no acepta sesiones o la copia falla.

### guest_session_close

Retira el directorio temporal del invitado; sin sesion abierta
no hace nada.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Variables set

* **VBOXDISK_SESSION_DIR** (string): Se vacia al cerrar la sesion.

#### Exit codes

* **0**: Siempre.

### guest_disk_args

Compone los argumentos del script invitado en la variable
GUEST_ARGS. El origen 'declarado' los lee del archivo declarativo y 'estado'
de state.lock, que es de donde salen los discos registrados y ya ausentes
del archivo.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Nombre del disco.
* **$3** (string): Modo del script invitado: "probe", "release" o "converge".
* **$4** (string): Origen de los datos: "declarado" o "estado"; no vacio.

#### Variables set

* **GUEST_ARGS** (array): Argumentos para guest_run: --mount, --fstype, --label, --size-mb, --device (si hay pista) y el modo.

#### Exit codes

* **0**: Siempre.

### guest_run

Una ejecucion del script invitado dentro de la sesion abierta.
El fichero de credenciales se vuelve a copiar en cada corrida, porque el
script lo destruye al terminar; la salida queda en la bitacora y los campos
GUEST_* analizados para el disco que acaba de correr.

#### Arguments

* **$1** (string): Nombre de la vm.
* **...** (array): Resto de argumentos del script invitado (normalmente GUEST_ARGS); se les agrega --passfile.

#### Variables set

* **GUEST_EXIT** (string): Codigo del script invitado; el resto de campos GUEST_* los rellena storage_parse_guest_output.

#### Exit codes

* **0**: El script invitado termino con la centinela VBOXDISK_EXIT=0.
* **1**: Codigo propio distinto de 0 devuelto por el script invitado (VBOXDISK_EXIT).
* **2**: VBOXDISK_E_COMM: no se copio la credencial o VBoxManage no ejecuto el script.
* **3**: VBOXDISK_E_STORAGE: la salida no contiene la centinela VBOXDISK_EXIT.

#### Output on stderr

* Salida del script invitado linea a linea (salvo con VBOXDISK_GUEST_QUIET) y errores o advertencias.

#### See also

* [storage_parse_guest_output()](storage.md#storage_parse_guest_output)

### apply_vm

Aplica a una vm las cinco etapas de la Subseccion del algoritmo:
verificacion declarativa, disponibilidad, direccion IP, preparacion del
almacenamiento en el invitado y verificacion con registro en state.lock.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Exit codes

* **0**: Sin cambios o convergencia verificada y registrada.
* **1**: Codigo 1 heredado del script invitado (validacion fallida en el invitado).
* **2**: VBOXDISK_E_COMM: encendido, VBoxService, IP o sesion con el invitado fallidos.
* **3**: VBOXDISK_E_STORAGE: fallo de almacenamiento o verificacion.
* **4**: VBOXDISK_E_CANCEL: decision o confirmacion rechazada por el usuario.

#### Output on stderr

* Registro de cada etapa, avisos y preguntas de confirmacion.

#### See also

* [guest_session_open()](#guest_session_open)

