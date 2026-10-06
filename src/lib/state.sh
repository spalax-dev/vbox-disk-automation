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

# Rutas XDG por defecto; VBOXDISK_STATE_DIR las sobreescribe (usado en pruebas).
state_dir() {
    printf '%s' "${VBOXDISK_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/vboxdisk}"
}

state_lock_file() {
    printf '%s/state.lock' "$(state_dir)"
}

state_log_dir() {
    printf '%s/state' "$(state_dir)"
}

# state_init_dirs: crea el directorio de estado y el de bitacoras.
state_init_dirs() {
    mkdir -p "$(state_dir)" "$(state_log_dir)"
}

# state_get <vm> <clave>: imprime el valor; retorna 1 si no existe.
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

# state_get_disk <vm> <disco> <clave>: clave anidada disks.<disco>.<clave>.
state_get_disk() {
    state_get "$1" "disks.$2.$3"
}

# state_disk_keys <vm>: discos registrados de la maquina, en orden de registro.
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

# state_vms: maquinas con seccion en state.lock, en orden de registro.
state_vms() {
    local lock
    lock="$(state_lock_file)"
    if [[ ! -f "$lock" ]]; then
        return 0
    fi
    awk '/^\[/ { sub(/^\[/, ""); sub(/\]$/, ""); print }' "$lock"
}

# state_set_vm <vm> <clave=valor>...  Reescribe o anade la entrada completa.
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

# state_update_vm <vm> <clave=valor>...  Fusiona con la entrada existente: las
# claves recibidas se actualizan o se anaden al final y el resto de la seccion
# se conserva tal cual, de modo que los discos no afectados por la corrida no
# pierden su registro.
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

# state_remove_prefix <vm> <prefijo>: retira de la seccion de la maquina todas
# las claves que empiezan por el prefijo; una seccion que queda vacia se borra
# por completo.
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

# state_remove_disk <vm> <disco>: retira el registro completo de un disco.
state_remove_disk() {
    state_remove_prefix "$1" "disks.$2."
}

# state_remove_vm <vm>: retira la seccion completa de la maquina.
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

# state_table_b64 <vm> <disco>: tabla de particiones registrada de un disco,
# ya decodificada.
state_table_b64() {
    local b64
    b64="$(state_get_disk "$1" "$2" table_b64 || true)"
    if [[ -z "$b64" ]]; then
        return 1
    fi
    printf '%s' "$b64" | base64 -d
}

# state_encode_table: tabla en base64 sin saltos, para una sola clave del lock.
state_encode_table() {
    printf '%s' "$1" | base64 -w0
}

# state_open_log: una bitacora plana por ejecucion de apply.
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
