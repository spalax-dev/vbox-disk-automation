#!/usr/bin/env bash
# Copyright 2026 spalax-dev
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# cli.sh: interfaz de usuario. Texto de ayuda, analisis y validacion de la
# linea de comandos, y validacion previa del archivo declarativo frente al
# hipervisor. Se carga desde el punto de entrada src/vboxdisk.

# Orden y opciones recibidas por cli_parse; se comparten con las demas
# bibliotecas y con el despacho del punto de entrada.
# shellcheck disable=SC2034
CMD=""
VBOXDISK_FILE="./vdisk.yml"
DRY_RUN=0
# shellcheck disable=SC2034  # la lee confirm() de common.sh.
VBOXDISK_ASSUME_YES=0
LD_NAME=""

# @description Ayuda de la interfaz: sale por stdout, que quien invoca
# redirige a stderr cuando la orden falta.
# @noargs
# @stdout Texto de ayuda con ordenes, opciones y codigos de salida.
usage() {
    cat <<'EOF'
Uso: vboxdisk <orden> [opciones]

Ordenes:
  apply            Converge todas las vm de ./vdisk.yml (unico caso que modifica)
  status           Lista las vm con su sincronizacion, sus discos y su direccion IP
  ld <nombre>      Tabla de particiones de los discos: la registrada o, sin
                   registro, la de la vm encendida (nunca la enciende)

Opciones:
  -f, --file FILE  Archivo declarativo (por defecto ./vdisk.yml)
  --dry-run        Muestra el plan de cambios sin modificar nada (apply)
  -y, --yes        Omite las confirmaciones; ante un disco registrado y ausente
                   del archivo elige eliminarlo
  -h, --help       Muestra esta ayuda y termina
  --version        Muestra la version instalada y termina

Codigos de salida: 0 convergido | 1 uso o configuracion | 2 comunicacion con
la vm | 3 almacenamiento o verificacion | 4 cancelado por el usuario
EOF
}

# @description Termina con un error de uso o de configuracion siempre con el codigo 1.
# @arg $1 string Mensaje de error (varios argumentos se unen en uno solo).
# @stderr El mensaje, con sello de tiempo y nivel ERROR.
# @exitcode 1 VBOXDISK_E_CONFIG; nunca retorna.
die_cfg() { die "$VBOXDISK_E_CONFIG" "$@"; }

# @description Comprueba que cada vm declarada existe en el hipervisor.
# Consulta de solo lectura; no enciende ni modifica maquina alguna.
# @noargs
# @stderr Mensaje de la vm inexistente, con sello de tiempo y nivel ERROR.
# @exitcode 0 Todas las vm declaradas existen.
# @exitcode 1 Alguna vm no existe o falta una dependencia (vbox_require).
validate_hypervisor() {
    vbox_require
    local vm
    while IFS= read -r vm; do
        if ! vbox_vm_exists "$vm"; then
            die_cfg "la vm '$vm' del archivo declarativo no existe en el hipervisor"
        fi
    done < <(cfg_vms)
}

# @description Validacion previa a actuar: comprueba la dependencia yq y el
# archivo declarativo y, cuando el comando lo pide, la existencia de cada vm
# en el hipervisor.
# @arg $1 string "1" para comprobar ademas el hipervisor, "0" para no hacerlo; no vacio.
# @stderr Motivo de la invalidacion, con sello de tiempo y nivel ERROR.
# @exitcode 0 Configuracion valida.
# @exitcode 1 Falta yq, el archivo declarativo no supera la validacion o una vm no existe.
# @see validate_hypervisor()
validate_config() {
    local check_hypervisor="$1"
    if ! have_cmd yq; then
        die_cfg "yq no esta disponible en el host (dependencia de ejecucion)"
    fi
    cfg_validate "$VBOXDISK_FILE" || die_cfg "el archivo declarativo no supera la validacion: $VBOXDISK_FILE"
    if [[ "$check_hypervisor" == "1" ]]; then
        validate_hypervisor
    fi
}

# @description Analiza la linea de comandos completa. Deja la orden en CMD y
# sus opciones en las variables globales; una orden desconocida o una bandera
# invalida terminan con el codigo de uso. Los argumentos posicionales son la
# orden (apply, status o ld) y, para ld, el nombre de la vm.
# @option -f | --file FILE Archivo declarativo (por defecto ./vdisk.yml).
# @option --dry-run Muestra el plan de cambios sin modificar nada; solo con la orden apply.
# @option -y | --yes Omite las confirmaciones; ante un disco registrado y ausente del archivo elige eliminarlo.
# @option -h | --help Muestra la ayuda y termina.
# @option --version Muestra la version instalada y termina.
# @set CMD string Orden recibida: apply, status o ld.
# @set VBOXDISK_FILE path Archivo declarativo (por defecto ./vdisk.yml).
# @set DRY_RUN int 1 con --dry-run, 0 en caso contrario.
# @set VBOXDISK_ASSUME_YES int 1 con -y/--yes, 0 en caso contrario.
# @set LD_NAME string Nombre de la vm que recibe la orden ld.
# @stdout Texto de ayuda con -h/--help y la version con --version.
# @stderr Mensajes de error y, cuando falta la orden, el aviso previo a la ayuda.
# @exitcode 0 Con -h/--help o --version.
# @exitcode 1 VBOXDISK_E_CONFIG: orden o bandera invalida; nunca retorna en error.
cli_parse() {
    while (($#)); do
        case "$1" in
            apply | status | ld)
                if [[ -n "$CMD" ]]; then
                    die_cfg "solo se admite una orden por corrida"
                fi
                CMD="$1"
                ;;
            -f | --file)
                if (($# < 2)); then
                    die_cfg "la opcion $1 requiere un argumento"
                fi
                VBOXDISK_FILE="$2"
                shift
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            -y | --yes)
                VBOXDISK_ASSUME_YES=1
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --version)
                say "vboxdisk $VBOXDISK_VERSION"
                exit 0
                ;;
            -*)
                die_cfg "bandera desconocida: $1"
                ;;
            *)
                if [[ "$CMD" == "ld" && -z "$LD_NAME" ]]; then
                    LD_NAME="$1"
                else
                    die_cfg "argumento inesperado: $1"
                fi
                ;;
        esac
        shift
    done

    # Validaciones globales posteriores al analisis.
    if [[ -z "$CMD" ]]; then
        # Banderas que solo pertenecen a apply: se senala la orden que falta
        # antes de imprimir la ayuda, para no dejar la duda con el uso completo.
        if ((DRY_RUN == 1)); then
            log_error "falta la orden; quizas quiso decir: vboxdisk apply --dry-run"
        elif ((VBOXDISK_ASSUME_YES == 1)); then
            log_error "falta la orden; quizas quiso decir: vboxdisk apply -y"
        else
            log_error "falta la orden; las ordenes validas son apply, status y ld"
        fi
        usage >&2
        exit "$VBOXDISK_E_CONFIG"
    fi
    if ((DRY_RUN == 1)) && [[ "$CMD" != "apply" ]]; then
        die_cfg "la opcion --dry-run solo aplica a la orden apply"
    fi
    if [[ "$CMD" == "ld" && -z "$LD_NAME" ]]; then
        die_cfg "la orden ld requiere el nombre de una vm"
    fi
}
