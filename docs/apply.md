## Index

* [cmd_apply](#cmd_apply)
* [guest_session_open](#guest_session_open)
* [guest_session_close](#guest_session_close)
* [guest_credentials_ask](#guest_credentials_ask)
* [guest_disk_args](#guest_disk_args)
* [guest_run](#guest_run)
* [guest_emit_raw](#guest_emit_raw)
* [record_medium_size](#record_medium_size)
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
sin cerrar la sesion. Las credenciales pedidas a la terminal por
guest_credentials_ask mandan sobre las del archivo, porque solo existen
cuando ese archivo ya no declara la maquina.

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
* **2**: VBOXDISK_E_COMM: sin credenciales, sin sesion del invitado o copia fallida.

#### Output on stderr

* Errores si faltan las credenciales, Guest Control no acepta sesiones o la copia falla.

#### See also

* [guest_credentials_ask()](#guest_credentials_ask)

### guest_session_close

Retira el directorio temporal del invitado; sin sesion abierta
no hace nada.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Variables set

* **VBOXDISK_SESSION_DIR** (string): Se vacia al cerrar la sesion.

#### Exit codes

* **0**: Siempre.

### guest_credentials_ask

Resuelve con que credencial abrir sesion con el invitado de una
vm que el archivo declarativo ya no declara. state.lock no guarda secretos y
el bloque de la vm desaparecio del fichero, de modo que, si ni el archivo ni
el entorno ofrecen ninguna, se piden al usuario con la misma consulta que
usa la sincronizacion, pero sin escribir el archivo: valen para la corrida en
curso.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Variables set

* **VBOXDISK_CRED_USER** (string): Usuario con el que abrir la sesion; vacio si manda el archivo.
* **VBOXDISK_CRED_PASS** (string): Contrasena en claro; vacia cuando la credencial es un fichero.
* **VBOXDISK_CRED_PASSFILE** (string): Ruta del fichero con la contrasena; vacia si se pidio en claro.

#### Exit codes

* **0**: Credencial resuelta: la del archivo, la del entorno o la pedida al usuario.
* **4**: Cancelada: sin terminal, lectura interrumpida (VBOXDISK_E_CANCEL).

#### Output on stderr

* El prompt de cada dato y los registros de respuestas incompletas.

#### See also

* [sync_credentials()](common.md#sync_credentials)
* [guest_session_open()](#guest_session_open)

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
script lo destruye al terminar; la salida queda siempre en la bitacora y los
campos GUEST_* analizados para el disco que acaba de correr. En pantalla solo
pasan las notas "guest_ensure: " del propio script: el volcado clave=valor de
emit_state y la salida de las herramientas (sfdisk, partx, resize2fs) se
quedan registrados, y se imprimen completos cuando algo fallo, para que el
motivo se vea sin abrir la bitacora. Con VBOXDISK_GUEST_QUIET no sale nada,
como antes.

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

* Las notas guest_ensure de la corrida; con fallo, la salida cruda completa; y siempre los errores o advertencias.

#### See also

* [storage_parse_guest_output()](storage.md#storage_parse_guest_output)
* [guest_emit_raw()](#guest_emit_raw)

### guest_emit_raw

Pasa al terminal la salida cruda retenida de una corrida del
invitado, la de emit_state y la de las herramientas, que en una corrida
correcta solo se queda en la bitacora. Las notas "guest_ensure: " ya
pasaron al leerla y no se repiten; con la salida retenida no imprime nada.

#### Arguments

* **$1** (string): Salida completa de la corrida, multilinea.

#### Exit codes

* **0**: Siempre.

#### Output on stderr

* La salida con salto de linea, sin las notas guest_ensure.

#### See also

* [guest_run()](#guest_run)

### record_medium_size

Corrige en state.lock el tamano registrado de un disco cuando el
hipervisor reporta otro. El registro describe el medio y no la intencion de la
ultima corrida: una ampliacion deja de ser cierta en cuanto se produce y una
falla posterior en la corrida no vuelve a escribirlo, de modo que el tamano
guardado deja de existir. Ese tamano es ademas el que la sincronizacion
importa al archivo declarativo, y declarar uno menor que el medio no se puede
aplicar: VirtualBox rechaza reducir un medio. Se corrige en cuanto se observa
la capacidad, y no al final de la corrida, para que ninguna falla conserve un
registro que contradiga al hipervisor.

#### Arguments

* **$1** (string): Nombre de la vm.
* **$2** (string): Clave del disco.
* **$3** (path): Fichero del medio en el host.

#### Exit codes

* **0**: Siempre: sin lectura posible el registro se conserva como esta.

#### Output on stderr

* log_info cuando el registro cambia; el resto de los casos son mudos.

#### See also

* [storage_medium_capacity()](storage.md#storage_medium_capacity)
* [state_update_vm()](state.md#state_update_vm)

### apply_vm

Aplica a una vm las cinco etapas de la Subseccion del algoritmo:
verificacion declarativa, disponibilidad, direccion IP, preparacion del
almacenamiento en el invitado y verificacion con registro en state.lock.
Discos registrados ausentes del archivo se resuelven antes de la primera
etapa con [e]liminar, [i]nactivar, [s]incronizar (el archivo vuelve a
recoger lo que el estado registra, con las credenciales que se pidan) u
[o]mitir. Las decisiones que retiran el montaje necesitan entrar en el
invitado, y como una vm ausente ya no declara credenciales, se piden en la
misma etapa con guest_credentials_ask.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Exit codes

* **0**: Sin cambios o convergencia verificada y registrada.
* **1**: VBOXDISK_E_CONFIG: validacion fallida en el invitado o sincronizacion invalida.
* **2**: VBOXDISK_E_COMM: encendido, VBoxService, IP o sesion con el invitado fallidos.
* **3**: VBOXDISK_E_STORAGE: fallo de almacenamiento o verificacion.
* **4**: VBOXDISK_E_CANCEL: decision o confirmacion rechazada por el usuario.

#### Output on stderr

* Registro de cada etapa, avisos y preguntas de confirmacion.

#### See also

* [guest_session_open()](#guest_session_open)
* [guest_credentials_ask()](#guest_credentials_ask)
* [confirm_choice()](common.md#confirm_choice)
* [cfg_sync_commit()](config.md#cfg_sync_commit)
* [storage_disk_changes()](storage.md#storage_disk_changes)

