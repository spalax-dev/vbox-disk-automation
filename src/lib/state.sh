#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables compartidas entre la
# entrada y las demas bibliotecas de src/lib.
# state.sh: state.lock (una entrada por vm) y bitacoras por ejecucion de apply.
# Rutas segun las variables XDG; state.lock no se instala ni se elimina.

state_dir() {
    printf '%s' "${VBOXDISK_STATE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/vboxdisk}"
}

state_lock_file() {
    printf '%s/state.lock' "$(state_dir)"
}

state_log_dir() {
    printf '%s/state' "$(state_dir)"
}

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

# state_table_b64 <vm>: tabla de particiones registrada, ya decodificada.
state_table_b64() {
    local b64
    b64="$(state_get "$1" table_b64 || true)"
    if [[ -z "$b64" ]]; then
        return 1
    fi
    printf '%s' "$b64" | base64 -d
}

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
