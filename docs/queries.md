## Index

* [vm_sync_status](#vm_sync_status)
* [vm_status_disks](#vm_status_disks)
* [plural](#plural)
* [vm_status_ip](#vm_status_ip)
* [cmd_status](#cmd_status)
* [cmd_ld](#cmd_ld)
* [ld_live](#ld_live)

### vm_sync_status

Estado de sincronización de la vm contra el archivo declarativo,
según la huella registrada en state.lock.

#### Example

```bash
  vm_sync_status web01  # imprime: sincronizada
@see storage_desired_hash()
```

#### Arguments

* **$1** (string): Nombre de la vm.

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* Una de estas tres cadenas, sin salto de línea: "sin estado" (sin
  registro previo), "sincronizada" o "desincronizada".

### vm_status_disks

Resumen por disco para la columna DISCOS de status: cuántos
están activos, cuántos inactivos, cuántos declarados sin registrar y cuántos
registrados quedaron pendientes de decisión (discos huérfanos).

#### Arguments

* **$1** (string): Nombre de la vm.

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* Recuento con plural y comas, p. ej. "2 activo, 1 inactivo"; la
  cadena "(sin discos)" si no hay nada que contar, sin salto de línea.

#### See also

* [plural()](#plural)

### plural

Devuelve la palabra en plural (le añade una s final) cuando la
cantidad no es uno; tal cual si es uno.

#### Example

```bash
plural 1 activo  # activo
plural 3 activo  # activos
```

#### Arguments

* **$1** (int): Cantidad.
* **$2** (string): Palabra en singular.

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* La palabra singular o pluralizada, sin salto de línea.

### vm_status_ip

Dirección IP para la tabla de status. Si la vm está encendida se
consulta en tiempo de ejecución (un único intento, sin esperar); si no, se
muestra la registrada en state.lock y se advierte que la máquina está
apagada.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Exit codes

* **0**: Siempre.

#### Output on stdout

* Con la vm encendida, la IP o "(no disponible)"; con la vm apagada,
  la IP registrada con el sufijo " (apagada)" y, si no la hay,
  "(sin registro) (apagada)". Sin salto de línea.

#### See also

* [vbox_detect_ip()](vbox.md#vbox_detect_ip)

### cmd_status

Tabla de sincronización, discos e IP por vm, de solo lectura:
ninguna vm se enciende ni se modifica.

_Function has no arguments._

#### Exit codes

* **0**: Tabla impresa.
* **1**: La validación de la configuración o del hipervisor falló (VBOXDISK_E_CONFIG): sale del proceso.

#### Output on stdout

* Cabecera MAQUINA, ESTADO, DISCOS y DIRECCION_IP y una fila por vm
  declarada en el archivo.

#### Output on stderr

* log_error si falta yq, el archivo no es válido, una vm declarada no
  existe en el hipervisor o faltan dependencias del host.

#### See also

* [vm_sync_status()](#vm_sync_status)

### cmd_ld

Última corrida registrada y tabla de particiones de cada disco
con registro en state.lock. Sin registro previo, consulta la tabla real a la
vm si está encendida (ld_live) y, si no lo está, explica cómo se genera.

#### Arguments

* **$1** (string): Nombre de la vm; debe estar declarada en $VBOXDISK_FILE.

#### Exit codes

* **0**: Consulta mostrada.
* **1**: La configuración no es válida o la vm no está declarada en el archivo (die_cfg); con consulta en vivo, también si la vm está apagada.
* **2**: Solo con consulta en vivo: fallo de comunicación con el invitado (VBOXDISK_E_COMM).

#### Output on stdout

* Encabezado "registro de <vm>: <fecha>", un bloque por disco con su
  estado, tamaño, sistema de ficheros, etiqueta, punto de montaje y tabla de
  particiones, o el aviso de que no la hay.

#### Output on stderr

* log_error cuando la configuración es inválida o la vm no está
  declarada; con consulta en vivo, los mensajes y la barra de ld_live.

#### See also

* [ld_live()](#ld_live)

### ld_live

Sin registro previo, lee la tabla real de los discos declarados
abriendo una sesión de Guest Control contra la vm encendida. La consulta es
de sola lectura y jamás enciende la máquina: si está apagada, se explica que
el registro se genera con apply. Los discos declarados inactivos se omiten.

#### Arguments

* **$1** (string): Nombre de la vm.

#### Variables set

* **VBOXDISK_GUEST_QUIET** (int): Se fija a 1 durante la consulta para retener la salida cruda del invitado y se retira (unset) al terminar.

#### Exit codes

* **0**: Consulta completada, aunque algún disco no esté presente.
* **1**: La vm no está encendida o faltan dependencias del host (die_cfg / vbox_require): sale del proceso.
* **2**: No se pudo abrir la sesión con el invitado o ningún disco pudo consultarse (VBOXDISK_E_COMM): sale del proceso.

#### Output on stdout

* Cabecera con la fecha de la consulta y, por cada disco presente, su
  bloque de particiones o el aviso de que no tiene tabla; si ningún disco está
  presente, un aviso final para ejecutar apply.

#### Output on stderr

* Registros y refrescos de la barra de progreso.

#### See also

* [cmd_ld()](#cmd_ld)

