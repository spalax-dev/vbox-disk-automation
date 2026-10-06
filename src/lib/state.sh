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
# shellcheck disable=SC2034  # variables compartidas entre la
# entrada y las demas bibliotecas de src/lib.
# state.sh: state.lock (una entrada por vm) y bitacoras por ejecucion de apply.
# Rutas segun las variables XDG; state.lock no se instala ni se elimina.

# @description Directorio de estado de vboxdisk.
# Precedencia: VBOXDISK_STATE_DIR (usado en pruebas) > $XDG_DATA_HOME/vboxdisk
# > ~/.local/share/vboxdisk.
# @noargs
# @stdout La ruta, sin salto de línea.
state_dir() {
    printf '%s' "${VBOXDISK_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/vboxdisk}"
}

# @description Ruta completa del fichero de bloqueo state.lock (una entrada por vm).
# @noargs
# @stdout La ruta, sin salto de línea.
# @see state_dir()
state_lock_file() {
    printf '%s/state.lock' "$(state_dir)"
}

# @description Directorio de las bitácoras por ejecución de apply.
# @noargs
# @stdout La ruta, sin salto de línea.
# @see state_dir()
state_log_dir() {
    printf '%s/state' "$(state_dir)"
}

# @description Crea el directorio de estado y el de bitácoras si aún no existen.
# @noargs
# @exitcode 0 Directorios creados o ya existentes.
# @exitcode 1 mkdir no pudo crearlos.
state_init_dirs() {
    mkdir -p "$(state_dir)" "$(state_log_dir)"
}

# @description Lee una clave de la sección de una vm en state.lock.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave; las anidadas se escriben con puntos (p. ej. disks.data0.size).
# @stdout El valor de la clave, sin salto de línea.
# @exitcode 0 La clave existe.
# @exitcode 1 La clave no existe o no hay state.lock.
# @see state_get_disk()
state_get() {
    local vm="$1" key="$2" lock
    lock="$(state_lock_file)"
    if [[ ! -f "$lock" ]]; then
        return 1
    fi
    awk -v vm="$vm" -v key="$key" '
        $0 == "[" vm "]" { in_vm = 1; next }
        /^\[/ { in_vm = 0 }
        in_vm && index($0, key "=") == 1 {
            print substr($0, length(key) + 2)
            found = 1
            exit
        }
        END { exit found ? 0 : 1 }
    ' "$lock"
}

# @description Lee una clave anidada de un disco: disks.<disco>.<clave>.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco.
# @arg $3 string Clave dentro del disco (p. ej. size, table_b64).
# @stdout El valor de la clave, sin salto de línea.
# @exitcode 0 La clave existe.
# @exitcode 1 La clave no existe o no hay state.lock.
# @see state_get()
state_get_disk() {
    state_get "$1" "disks.$2.$3"
}

# @description Enumera los discos registrados de la vm, en orden de registro.
# @arg $1 string Nombre de la vm.
# @stdout Un nombre de disco por línea; vacío si no hay state.lock ni discos.
# @exitcode 0 Siempre.
state_disk_keys() {
    local vm="$1" lock
    lock="$(state_lock_file)"
    if [[ ! -f "$lock" ]]; then
        return 0
    fi
    awk -v vm="$vm" -v p="disks." '
        $0 == "[" vm "]" { in_vm = 1; next }
        /^\[/ { in_vm = 0 }
        in_vm && index($0, p) == 1 {
            key = substr($0, length(p) + 1)
            sub(/\..*$/, "", key)
            if (key != "" && !seen[key]++) print key
        }
    ' "$lock"
}

# @description Enumera las máquinas con sección en state.lock, en orden de registro.
# @noargs
# @stdout Un nombre de vm por línea; vacío si no hay state.lock.
# @exitcode 0 Siempre.
state_vms() {
    local lock
    lock="$(state_lock_file)"
    if [[ ! -f "$lock" ]]; then
        return 0
    fi
    awk '/^\[/ { sub(/^\[/, ""); sub(/\]$/, ""); print }' "$lock"
}

# @description Reescribe o crea la sección completa de una vm en state.lock con
# las claves recibidas.
# La sección anterior se elimina por completo: las claves no incluidas se
# pierden. Si la vm no tenía sección, esta se añade al final del fichero.
# @arg $1 string Nombre de la vm.
# @arg $@ string Pares 'clave=valor' que compondrán la sección, desde $2.
# @exitcode 0 Sección reescrita.
# @see state_update_vm()
state_set_vm() {
    local vm="$1"
    shift
    local lock tmp kv
    lock="$(state_lock_file)"
    mkdir -p "$(dirname "$lock")"
    tmp="$(mktemp "${lock}.XXXXXX")"
    if [[ -f "$lock" ]]; then
        awk -v vm="$vm" '
            $0 == "[" vm "]" { skip = 1; next }
            /^\[/ { skip = 0 }
            !skip { print }
        ' "$lock" >"$tmp"
    fi
    {
        printf '[%s]\n' "$vm"
        for kv in "$@"; do
            printf '%s\n' "$kv"
        done
    } >>"$tmp"
    mv "$tmp" "$lock"
}

# @description Fusiona claves en la sección de una vm sin tocar el resto.
# Las claves recibidas se actualizan o se añaden al final; las ya existentes
# conservan su posición original y el resto de la sección se conserva tal
# cual, de modo que los discos no afectados por la corrida no pierden su
# registro. Difiere de state_set_vm(), que reescribe la sección entera.
# @arg $1 string Nombre de la vm.
# @arg $@ string Pares 'clave=valor' a fusionar, desde $2; los que no contienen '=' se ignoran.
# @exitcode 0 Sección actualizada.
# @see state_set_vm()
state_update_vm() {
    local vm="$1"
    shift
    local lock tmp kv line
    local -A prev=()
    local -a order=()
    lock="$(state_lock_file)"
    mkdir -p "$(dirname "$lock")"
    if [[ -f "$lock" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            case "$line" in
                "[$vm]")
                    in_vm=1
                    continue
                    ;;
                \[*)
                    in_vm=0
                    ;;
            esac
            [[ "${in_vm:-0}" == "1" && "$line" == *"="* ]] || continue
            kv="${line%%=*}"
            if [[ -z "${prev[$kv]+x}" ]]; then
                order+=("$kv")
            fi
            prev[$kv]="${line#*=}"
        done <"$lock"
    fi
    for kv in "$@"; do
        [[ "$kv" == *"="* ]] || continue
        if [[ -z "${prev[${kv%%=*}]+x}" ]]; then
            order+=("${kv%%=*}")
        fi
        prev[${kv%%=*}]="${kv#*=}"
    done
    tmp="$(mktemp "${lock}.XXXXXX")"
    if [[ -f "$lock" ]]; then
        awk -v vm="$vm" '
            $0 == "[" vm "]" { skip = 1; next }
            /^\[/ { skip = 0 }
            !skip { print }
        ' "$lock" >"$tmp"
    fi
    {
        printf '[%s]\n' "$vm"
        for kv in "${order[@]}"; do
            printf '%s=%s\n' "$kv" "${prev[$kv]}"
        done
    } >>"$tmp"
    mv "$tmp" "$lock"
}

# @description Retira de la sección de la vm todas las claves que empiezan por
# un prefijo; una sección que queda vacía se borra por completo.
# Si no hay state.lock no hace nada.
# @arg $1 string Nombre de la vm.
# @arg $2 string Prefijo de las claves a eliminar (p. ej. disks.data0.).
# @exitcode 0 Operación completada.
# @see state_remove_disk()
state_remove_prefix() {
    local vm="$1" prefix="$2" lock tmp
    lock="$(state_lock_file)"
    if [[ ! -f "$lock" ]]; then
        return 0
    fi
    tmp="$(mktemp "${lock}.XXXXXX")"
    awk -v vm="$vm" -v p="$prefix" '
        $0 == "[" vm "]" { buf = "[" vm "]\n"; in_vm = 1; next }
        /^\[/ {
            if (in_vm) {
                if (length(buf) > length(vm) + 3) printf "%s", buf
                in_vm = 0
            }
            print
            next
        }
        in_vm {
            if (index($0, p) == 1) next
            buf = buf $0 "\n"
            next
        }
        { print }
        END {
            if (in_vm && length(buf) > length(vm) + 3) printf "%s", buf
        }
    ' "$lock" >"$tmp"
    mv "$tmp" "$lock"
}

# @description Retira el registro completo de un disco de la vm.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco.
# @exitcode 0 Operación completada.
# @see state_remove_prefix()
state_remove_disk() {
    state_remove_prefix "$1" "disks.$2."
}

# @description Retira la sección completa de la vm de state.lock.
# Si la vm no tiene sección o no hay state.lock, no hace nada.
# @arg $1 string Nombre de la vm.
# @exitcode 0 Operación completada.
state_remove_vm() {
    local vm="$1" lock tmp
    lock="$(state_lock_file)"
    if [[ ! -f "$lock" ]]; then
        return 0
    fi
    tmp="$(mktemp "${lock}.XXXXXX")"
    awk -v vm="$vm" '
        $0 == "[" vm "]" { skip = 1; next }
        /^\[/ { skip = 0 }
        !skip { print }
    ' "$lock" >"$tmp"
    mv "$tmp" "$lock"
}

# @description Devuelve ya decodificada la tabla de particiones registrada de un disco.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco.
# @stdout La tabla de particiones en texto plano, con sus saltos de línea.
# @exitcode 0 La tabla se decodificó.
# @exitcode 1 El disco no tiene tabla registrada o el base64 no es válido.
# @see state_encode_table()
state_table_b64() {
    local b64
    b64="$(state_get_disk "$1" "$2" table_b64 || true)"
    if [[ -z "$b64" ]]; then
        return 1
    fi
    printf '%s' "$b64" | base64 -d
}

# @description Codifica una tabla en base64 sin saltos de línea, para guardarla
# como una sola clave del lock.
# @arg $1 string Tabla de particiones en texto plano.
# @stdout La tabla en base64, en una sola línea.
# @see state_table_b64()
state_encode_table() {
    printf '%s' "$1" | base64 -w0
}

# @description Crea y abre una bitácora plana por ejecución de apply, con el
# directorio de bitácoras creado si falta.
# El nombre del fichero es la fecha y hora local con formato
# AAAAmmdd-HHMMSS.log. Después escribe la cabecera de la corrida.
# @noargs
# @set VBOXDISK_LOG_FILE string Ruta del fichero de bitácora recién creado.
# @stderr log_error si la bitácora no se pudo crear; después las cabeceras con log_info.
# @exitcode 0 Bitácora creada y registrada.
# @exitcode 1 No se pudo crear el fichero de bitácora.
state_open_log() {
    local dir f
    dir="$(state_log_dir)"
    mkdir -p "$dir"
    f="$dir/$(date '+%Y%m%d-%H%M%S').log"
    if ! : >"$f"; then
        log_error "no se pudo crear la bitacora: $f"
        return 1
    fi
    VBOXDISK_LOG_FILE="$f"
    log_info "vboxdisk ${VBOXDISK_VERSION} - bitacora de la corrida"
    log_info "archivo declarativo: $VBOXDISK_FILE"
    return 0
}
