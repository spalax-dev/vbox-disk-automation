#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables compartidas entre la
# entrada y las demas bibliotecas de src/lib.
# common.sh: registro, cronometros, progreso por etapa, confirmaciones y codigos.
# Se carga desde src/vboxdisk; no se ejecuta por si mismo.

VBOXDISK_VERSION="1.0.0"

VBOXDISK_OK=0
VBOXDISK_E_CONFIG=1
VBOXDISK_E_COMM=2
VBOXDISK_E_STORAGE=3
VBOXDISK_E_CANCEL=4

VBOXDISK_LOG_FILE=""
VBOXDISK_TOTAL_T0=0
VBOXDISK_STAGE_N=0
VBOXDISK_STAGE_T0=0
VBOXDISK_STAGE_NAME=""
VBOXDISK_STAGE_TOTAL=5

now_s() { date +%s; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_tty() { [[ -t 2 ]]; }

log() {
    local level="$1"
    shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    if [[ -n "${VBOXDISK_LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >>"$VBOXDISK_LOG_FILE"
    fi
    printf '%s\n' "$line" >&2
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# Datos por stdout, separados del progreso y los registros.
say() { printf '%s\n' "$*"; }

die() {
    local code="$1"
    shift
    log_error "$@"
    exit "$code"
}

confirm() {
    local prompt="$1"
    if [[ "${VBOXDISK_ASSUME_YES:-0}" == "1" ]]; then
        log_info "confirmacion omitida por -y: $prompt"
        return 0
    fi
    if [[ ! -t 0 ]]; then
        log_error "se requiere confirmacion y la entrada no es un terminal: $prompt (use -y)"
        return "$VBOXDISK_E_CANCEL"
    fi
    local answer
    printf '%s [s/N] ' "$prompt" >&2
    IFS= read -r answer || return "$VBOXDISK_E_CANCEL"
    case "${answer,,}" in
        s | si | sí | y | yes) return 0 ;;
        *)
            log_warn "operacion cancelada por el usuario"
            return "$VBOXDISK_E_CANCEL"
            ;;
    esac
}

stage_begin() {
    VBOXDISK_STAGE_N="$1"
    VBOXDISK_STAGE_NAME="$2"
    VBOXDISK_STAGE_T0="$(now_s)"
    if is_tty; then
        local filled=$((VBOXDISK_STAGE_N - 1))
        local width=20 i bar=""
        for ((i = 0; i < width; i++)); do
            if ((i < filled)); then
                bar+="="
            elif ((i == filled)); then
                bar+=">"
            else
                bar+=" "
            fi
        done
        printf '\r[%d/%d] [%s] %s' "$VBOXDISK_STAGE_N" "$VBOXDISK_STAGE_TOTAL" "$bar" "$VBOXDISK_STAGE_NAME" >&2
    fi
}

stage_end() {
    local dur=$(($(now_s) - VBOXDISK_STAGE_T0))
    if is_tty; then
        printf ' listo (%ds)\n' "$dur" >&2
    else
        printf '[%d/%d] %s ... listo (%ds)\n' \
            "$VBOXDISK_STAGE_N" "$VBOXDISK_STAGE_TOTAL" "$VBOXDISK_STAGE_NAME" "$dur" >&2
    fi
    log_info "etapa $VBOXDISK_STAGE_N/$VBOXDISK_STAGE_TOTAL: $VBOXDISK_STAGE_NAME completada en ${dur}s"
}

# Severidad de los codigos de salida: los globales 1 y 4 dominan; entre los
# particulares, 3 precede a 2 (Tabla: tab:codigos).
code_weight() {
    case "$1" in
        1) printf '40' ;;
        4) printf '30' ;;
        3) printf '20' ;;
        2) printf '10' ;;
        *) printf '0' ;;
    esac
}

aggregate_code() {
    local best=0 code w bw
    for code in "$@"; do
        w=$(code_weight "$code")
        bw=$(code_weight "$best")
        if ((w > bw)); then
            best="$code"
        fi
    done
    printf '%s' "$best"
}

total_start() { VBOXDISK_TOTAL_T0="$(now_s)"; }

total_seconds() { printf '%s' "$(( $(now_s) - VBOXDISK_TOTAL_T0 ))"; }

VBOXDISK_TMP_PATHS=()

register_tmp() { VBOXDISK_TMP_PATHS+=("$1"); }

# Trampa de salida: primero borra el directorio en el invitado (necesita el
# fichero de credenciales temporal) y despues destruye ese fichero en el host.
cleanup_tmps() {
    local f
    if declare -F vbox_guest_rm >/dev/null 2>&1; then
        vbox_guest_cleanup_all || true
    fi
    for f in "${VBOXDISK_TMP_PATHS[@]}"; do
        if [[ -n "$f" && -e "$f" ]]; then
            shred -u "$f" 2>/dev/null || rm -f "$f"
        fi
    done
}
