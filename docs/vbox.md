## Index

* [vbox_require](#vbox_require)
* [vbox_vm_exists](#vbox_vm_exists)
* [vbox_info](#vbox_info)
* [vbox_power_state](#vbox_power_state)
* [vbox_start](#vbox_start)
* [vbox_stop](#vbox_stop)
* [vbox_guest_ready](#vbox_guest_ready)
* [vbox_wait_ready](#vbox_wait_ready)
* [vbox_guestproperty_ip](#vbox_guestproperty_ip)
* [vbox_mac](#vbox_mac)
* [vbox_arp_ip](#vbox_arp_ip)
* [vbox_detect_ip](#vbox_detect_ip)
* [vbox_gc](#vbox_gc)
* [vbox_guest_mktemp_dir](#vbox_guest_mktemp_dir)
* [vbox_guest_copy_to](#vbox_guest_copy_to)
* [vbox_guest_run](#vbox_guest_run)
* [vbox_guest_rm](#vbox_guest_rm)
* [vbox_guest_track_dir](#vbox_guest_track_dir)
* [vbox_guest_untrack_dir](#vbox_guest_untrack_dir)
* [vbox_guest_cleanup_all](#vbox_guest_cleanup_all)
* [vbox_vm_dir](#vbox_vm_dir)

### vbox_require

Comprueba las dependencias de ejecución en el host (VBoxManage,
yq e ip); si falta alguna, termina la corrida.

_Function has no arguments._

#### Exit codes

* **0**: Las tres dependencias están disponibles.
* **1**: Faltan dependencias (VBOXDISK_E_CONFIG): sale del proceso.

#### Output on stderr

* log_error con el nombre de la dependencia que falte.

### vbox_vm_exists

Indica si el nombre figura en la salida de VBoxManage list vms,
con comparación exacta del nombre entre comillas.

#### Arguments

* **$1** (string): Nombre exacto de la máquina virtual.

#### Exit codes

* **0**: La máquina existe en el hipervisor.
* **1**: La máquina no existe o la lista no se pudo leer.

### vbox_info

Lee una clave de la salida --machinereadable de VBoxManage
showvminfo.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.
* **$2** (string): Clave a leer (p. ej. VMState, CfgFile, macaddress1).

#### Exit codes

* **0**: La clave aparece en la salida.
* **1**: La clave no aparece o la máquina no se pudo consultar.

#### Output on stdout

* Valor de la clave, sin las comillas que lo rodean, con salto de línea.

### vbox_power_state

Estado de encendido de la máquina, leído de la clave VMState.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.

#### Exit codes

* **0**: Estado leído.
* **1**: No se pudo leer el estado (máquina desconocida).

#### Output on stdout

* El estado con salto de línea (p. ej. running, poweroff, aborted,
  saved, paused, starting, stuck).

#### See also

* [vbox_info()](#vbox_info)

### vbox_start

Enciende la máquina en modo headless si aún no lo está y aguarda
a que alcance el estado running. Si ya está running no hace nada; si está
arrancando, solo aguarda.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.

#### Exit codes

* **0**: La máquina quedó en running (o ya lo estaba).
* **2**: No arrancó en 30 s, VBoxManage startvm falló o el estado actual lo impide (VBOXDISK_E_COMM).

#### Output on stderr

* log_info al iniciar, log_error si el estado impide el arranque o si
  no se alcanza running, y refrescos de la barra de progreso.

### vbox_stop

Apaga la máquina de forma ordenada con el botón ACPI y, si no
responde en 60 s, fuerza el apagado con controlvm poweroff.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.

#### Exit codes

* **0**: Siempre: tanto si el apagado ACPI respondió como si hubo que forzarlo.

#### Output on stderr

* log_warn cuando hay que forzar el apagado, y refrescos de la barra
  de progreso.

### vbox_guest_ready

Indica si Guest Additions ya publicó su versión como propiedad
del invitado. VBox 7.2 usa /VirtualBox/GuestAdd/Version y otros empaquetados
publican /VirtualBox/GuestAdditions/Version; se acepta cualquiera de las dos
para no depender del nombre que elija cada empaquetado.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.

#### Exit codes

* **0**: Guest Additions publica su versión.
* **1**: Ninguna de las dos propiedades tiene valor.

### vbox_wait_ready

Aguarda a que VBoxService publique las propiedades de Guest
Additions, comprobando cada 2 s hasta agotar el tiempo.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.
* **$2** (int): Segundos máximos de espera; por defecto 120 s.

#### Exit codes

* **0**: Guest Additions publicó su versión a tiempo.
* **1**: Se agotó el tiempo de espera.

#### Output on stderr

* Refrescos de la barra de progreso.

#### See also

* [vbox_guest_ready()](#vbox_guest_ready)

### vbox_guestproperty_ip

Devuelve la propiedad Net/0/V4/IP de Guest Additions cuando es
una IPv4 con el formato válido (cuatro octetos separados por punto).

#### Arguments

* **$1** (string): Nombre de la máquina virtual.

#### Exit codes

* **0**: La propiedad contiene una IPv4 válida.
* **1**: La propiedad está vacía o no tiene formato IPv4.

#### Output on stdout

* La IPv4, sin salto de línea.

#### See also

* [vbox_detect_ip()](#vbox_detect_ip)

### vbox_mac

MAC del adaptador 1 de la máquina en el formato que espera la
tabla ARP: dos puntos como separador y letras en minúsculas.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.

#### Exit codes

* **0**: MAC leída.
* **1**: La máquina no informa macaddress1.

#### Output on stdout

* La MAC con dos puntos en minúsculas, sin salto de línea.

### vbox_arp_ip

Busca la IP asociada a una MAC en la tabla ARP de la red en
puente (ip neigh show), como respaldo cuando Guest Additions no informa la
IP. La comparación no distingue mayúsculas.

#### Arguments

* **$1** (string): MAC con dos puntos en minúsculas.

#### Exit codes

* **0**: La MAC figura en la tabla ARP.
* **1**: La MAC no figura o la tabla no arrojó ninguna IP.

#### Output on stdout

* La IP encontrada, sin salto de línea.

#### See also

* [vbox_detect_ip()](#vbox_detect_ip)

### vbox_detect_ip

Detecta la IP de la máquina reintentando cada 2 s hasta agotar
el tiempo: primero lee la propiedad de Guest Additions y, si no está, recurre
a la tabla ARP con la MAC del adaptador 1.

#### Example

```bash
  ip="$(vbox_detect_ip web60)" || echo "sin IP"
@see vbox_guestproperty_ip()
```

#### Arguments

* **$1** (string): Nombre de la máquina virtual.
* **$2** (int): Segundos máximos de espera; por defecto 60 s.

#### Exit codes

* **0**: IP detectada.
* **1**: Se agotó el tiempo sin obtener ninguna IP.

#### Output on stdout

* La IP detectada, sin salto de línea.

#### Output on stderr

* Refrescos de la barra de progreso.

### vbox_gc

Ejecuta una suborden de VBoxManage guestcontrol con el usuario y
el fichero de credenciales de la sesión con el invitado, que prepara
guest_session_open antes de llamar a esta biblioteca.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.
* **...** (string): Argumentos de la suborden (mktemp, copyto, run, ...), desde $2, pasados tal cual a VBoxManage.

#### Exit codes

* **0**: La suborden terminó sin errores; si falla, se propaga el código que devuelve VBoxManage.

#### See also

* [guest_session_open()](apply.md#guest_session_open)

### vbox_guest_mktemp_dir

Crea un directorio temporal en el invitado (bajo /tmp con la
plantilla vboxdisk.XXXXXX) y devuelve su ruta. La salida
"Directory name: <ruta>" se reduce a la ruta absoluta.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.

#### Exit codes

* **0**: Directorio creado y ruta devuelta.
* **1**: La respuesta del invitado no es una ruta absoluta; si mktemp falló, se propaga el código de vbox_gc.

#### Output on stdout

* La ruta absoluta del directorio, sin salto de línea.

#### See also

* [vbox_guest_rm()](#vbox_guest_rm)

### vbox_guest_copy_to

Copia un fichero del host al directorio indicado del invitado,
en silencio. El destino lleva barra final: sin ella, VBoxManage 7.2 toma
--target-directory como la ruta del fichero de destino y falla contra un
directorio existente con el mismo nombre. La salida del hipervisor se
captura para no empujar la barra ni pegarla a los registros de la etapa, y
se conserva en la bitácora.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.
* **$2** (path): Directorio de destino en el invitado; se le añade la barra final si no termina en ella.
* **$3** (path): Fichero de origen en el host.

#### Exit codes

* **0**: Copia completada; si falla, se propaga el código de VBoxManage.

### vbox_guest_run

Ejecuta un script del invitado con /bin/bash a través de
guestcontrol. El programa va justo después de --, de modo que bash recibe
el script como operando y sus argumentos tal cual.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.
* **$2** (path): Directorio de trabajo del proceso en el invitado (--cwd).
* **$3** (int): Tiempo límite en segundos; guestcontrol lo recibe en milisegundos.
* **$4** (path): Ruta del script en el invitado.
* **...** (string): Argumentos del script, desde $5, pasados tal cual.

#### Exit codes

* **0**: El programa terminó sin errores; si falla, se propaga el código que devuelve VBoxManage.

### vbox_guest_rm

Borra un directorio del invitado con /bin/rm -rf usando la misma
sesión: la suborden rm solo acepta ficheros individuales, así que para el
directorio temporal completo se despacha rm. Es mejor esfuerzo con un tope
de 15 s; los fallos se descartan.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.
* **$2** (path): Ruta del directorio a borrar en el invitado.

#### Exit codes

* **0**: Siempre: cualquier fallo o timeout se ignora.

### vbox_guest_track_dir

Añade un directorio temporal del invitado a la lista de
pendientes de limpieza, para que la trampa de salida lo borre.

#### Arguments

* **$1** (path): Ruta del directorio en el invitado.

#### Variables set

* **VBOXDISK_GUEST_DIRS** (array): Registra el directorio como pendiente.

#### See also

* [vbox_guest_cleanup_all()](#vbox_guest_cleanup_all)

### vbox_guest_untrack_dir

Retira de la lista de pendientes un directorio que ya fue
borrado; si la ruta no está registrada, no hace nada.

#### Arguments

* **$1** (path): Ruta del directorio en el invitado.

#### Variables set

* **VBOXDISK_GUEST_DIRS** (array): Elimina la entrada que coincida con la ruta.

#### Exit codes

* **0**: Siempre, haya coincidido o no.

#### See also

* [vbox_guest_track_dir()](#vbox_guest_track_dir)

### vbox_guest_cleanup_all

Mejor esfuerzo en la trampa de salida: borra del invitado cada
directorio registrado con vbox_guest_track_dir. No hace nada si no hay una
máquina en curso (VBOXDISK_CURRENT_VM vacía).

_Function has no arguments._

#### Variables set

* **VBOXDISK_GUEST_DIRS** (array): Queda vacía al terminar.

#### Exit codes

* **0**: Siempre.

#### See also

* [vbox_guest_rm()](#vbox_guest_rm)

### vbox_vm_dir

Directorio de la máquina en el host, tomado de la clave CfgFile
de showvminfo; de ahí salen los discos por defecto cuando el archivo
declarativo no fija un fichero concreto.

#### Arguments

* **$1** (string): Nombre de la máquina virtual.

#### Exit codes

* **0**: Directorio resuelto.
* **1**: CfgFile ausente o no es una ruta absoluta.

#### Output on stdout

* Ruta del directorio que contiene el fichero .vbox, con salto de línea.

