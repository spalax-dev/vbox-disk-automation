## Index

* [usage](#usage)
* [die_cfg](#die_cfg)
* [validate_hypervisor](#validate_hypervisor)
* [validate_config](#validate_config)
* [cli_parse](#cli_parse)

### usage

Ayuda de la interfaz: sale por stdout, que quien invoca
redirige a stderr cuando la orden falta.

_Function has no arguments._

#### Output on stdout

* Texto de ayuda con ordenes, opciones y codigos de salida.

### die_cfg

Termina con un error de uso o de configuracion siempre con el codigo 1.

#### Arguments

* **$1** (string): Mensaje de error (varios argumentos se unen en uno solo).

#### Exit codes

* **1**: VBOXDISK_E_CONFIG; nunca retorna.

#### Output on stderr

* El mensaje, con sello de tiempo y nivel ERROR.

### validate_hypervisor

Comprueba que cada vm declarada existe en el hipervisor.
Consulta de solo lectura; no enciende ni modifica maquina alguna.

_Function has no arguments._

#### Exit codes

* **0**: Todas las vm declaradas existen.
* **1**: Alguna vm no existe o falta una dependencia (vbox_require).

#### Output on stderr

* Mensaje de la vm inexistente, con sello de tiempo y nivel ERROR.

### validate_config

Validacion previa a actuar: comprueba la dependencia yq y el
archivo declarativo y, cuando el comando lo pide, la existencia de cada vm
en el hipervisor.

#### Arguments

* **$1** (string): "1" para comprobar ademas el hipervisor, "0" para no hacerlo; no vacio.

#### Exit codes

* **0**: Configuracion valida.
* **1**: Falta yq, el archivo declarativo no supera la validacion o una vm no existe.

#### Output on stderr

* Motivo de la invalidacion, con sello de tiempo y nivel ERROR.

#### See also

* [validate_hypervisor()](#validate_hypervisor)

### cli_parse

Analiza la linea de comandos completa. Deja la orden en CMD y
sus opciones en las variables globales; una orden desconocida o una bandera
invalida terminan con el codigo de uso. Los argumentos posicionales son la
orden (apply, status o ld) y, para ld, el nombre de la vm.

#### Options

* **-f** | **--file**

  FILE Archivo declarativo (por defecto ./vdisk.yml).

* **--dry-run**

  Muestra el plan de cambios sin modificar nada; solo con la orden apply.

* **-y** | **--yes**

  Omite las confirmaciones; ante un disco registrado y ausente del archivo elige eliminarlo.

* **-h** | **--help**

  Muestra la ayuda y termina.

* **--version**

  Muestra la version instalada y termina.

#### Variables set

* **CMD** (string): Orden recibida: apply, status o ld.
* **VBOXDISK_FILE** (path): Archivo declarativo (por defecto ./vdisk.yml).
* **DRY_RUN** (int): 1 con --dry-run, 0 en caso contrario.
* **VBOXDISK_ASSUME_YES** (int): 1 con -y/--yes, 0 en caso contrario.
* **LD_NAME** (string): Nombre de la vm que recibe la orden ld.

#### Exit codes

* **0**: Con -h/--help o --version.
* **1**: VBOXDISK_E_CONFIG: orden o bandera invalida; nunca retorna en error.

#### Output on stdout

* Texto de ayuda con -h/--help y la version con --version.

#### Output on stderr

* Mensajes de error y, cuando falta la orden, el aviso previo a la ayuda.

