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
# common.sh: registro, cronometros, progreso por etapa, confirmaciones y codigos.
# Se carga desde src/vboxdisk; no se ejecuta por si mismo.

# Version de la solucion y codigos de salida de la Tabla tab:codigos.
VBOXDISK_VERSION="1.0.0"

VBOXDISK_OK=0
VBOXDISK_E_CONFIG=1
VBOXDISK_E_COMM=2
VBOXDISK_E_STORAGE=3
VBOXDISK_E_CANCEL=4

# Estado global de la corrida: bitacora, cronometro total y etapa en curso.
VBOXDISK_LOG_FILE=""
VBOXDISK_TOTAL_T0=0
VBOXDISK_STAGE_N=0
VBOXDISK_STAGE_T0=0
VBOXDISK_STAGE_NAME=""
VBOXDISK_STAGE_TOTAL=5
VBOXDISK_STAGE_OPEN=0
# Con la barra pintada ocupa el ultimo renglon del bloque de su etapa y el
# cursor queda a su final; todo mensaje la empuja hacia arriba y la repite
# debajo, solo con \r, \x1b[K y salto de linea.
VBOXDISK_STAGE_PAINTED=0

# now_s: segundos desde la epoca, base de todos los cronometros.
now_s() { date +%s; }

# have_cmd: 0 si el comando esta en el PATH.
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# is_tty: 0 si stderr es un terminal (ahi cabe la barra de progreso).
is_tty() { [[ -t 2 ]]; }

# bar_segment: "[n/T] [barra] nombre" de la etapa en curso, sin el tiempo,
# para componer tanto la barra viva como el cierre de la etapa.
bar_segment() {
    local filled i bar=""
    filled=$((VBOXDISK_STAGE_N - 1))
    for ((i = 0; i < 20; i++)); do
        if ((i < filled)); then
            bar+="="
        elif ((i == filled)); then
            bar+=">"
        else
            bar+=" "
        fi
    done
    printf '[%d/%d] [%s] %s' \
        "$VBOXDISK_STAGE_N" "$VBOXDISK_STAGE_TOTAL" "$bar" "$VBOXDISK_STAGE_NAME"
}

# bar_text: segmento de la barra con el tiempo transcurrido de la etapa.
bar_text() {
    printf '%s %ds' "$(bar_segment)" "$(( $(now_s) - VBOXDISK_STAGE_T0 ))"
}

# bar_paint: pinta la barra de la etapa en su propio renglon, el ultimo del
# bloque, sin cerrarlo: el cursor queda al final de la barra y lo que la
# etapa escriba (registros, salidas del invitado, preguntas) la empuja hacia
# arriba. Solo actua cuando stderr es terminal; en cualquier otra salida la
# etapa usa la linea plana.
bar_paint() {
    ((VBOXDISK_STAGE_OPEN == 1)) || return 0
    is_tty || return 0
    printf '\r\033[K%s' "$(bar_text)" >&2
    VBOXDISK_STAGE_PAINTED=1
}

# bar_tick: refresca la barra en su renglon con el tiempo actualizado,
# limpiandolo y volviendolo a escribir sin salto de linea, de modo que el
# cursor sigue al final de la barra. Sin barra pintada no hace nada.
bar_tick() {
    ((VBOXDISK_STAGE_PAINTED == 1)) || return 0
    is_tty || return 0
    printf '\r\033[K%s' "$(bar_text)" >&2
}

# emit_line <texto>: escribe una linea empujando la barra hacia arriba: limpia
# su renglon, pone el mensaje y repite la barra debajo, sin cerrarla, para que
# siempre quede al final. Con la barra pintada toda la salida de la etapa
# debe pasar por aqui; cualquier mensaje mas ancho que el terminal se parte
# en varias filas y la barra desciende igual, sin contarlas.
emit_line() {
    if ((VBOXDISK_STAGE_PAINTED == 1)); then
        printf '\r\033[K%s\n\r\033[K%s' "$1" "$(bar_text)" >&2
    else
        printf '%s\n' "$1" >&2
    fi
}

# bar_suspend: retira la barra del renglon antes de escribir un prompt, para
# que la pregunta ocupe ese renglon. Sin barra pintada no hace nada.
bar_suspend() {
    ((VBOXDISK_STAGE_PAINTED == 1)) || return 0
    printf '\r\033[K' >&2
    VBOXDISK_STAGE_PAINTED=0
}

# bar_resume: vuelve a pintar la barra en el renglon corriente, al terminar
# la respuesta al prompt. Fuera de una etapa no hace nada.
bar_resume() {
    ((VBOXDISK_STAGE_OPEN == 1)) || return 0
    bar_paint
}

# close_prompt_line: cierra el renglon de un prompt cuya respuesta no llego
# completa y repite la barra, para que el mensaje siguiente no se pegue a la
# pregunta.
close_prompt_line() {
    printf '\n' >&2
    bar_resume
}

# bar_finalize: en la trampa de salida cierra el renglon de una barra que
# quede pintada, para que el prompt no se pegue al avance.
bar_finalize() {
    if ((VBOXDISK_STAGE_PAINTED == 1)); then
        printf '\n' >&2
        VBOXDISK_STAGE_PAINTED=0
    fi
}

# log <nivel> <mensaje>: sello de tiempo y nivel a stderr y, si hay bitacora,
# la misma linea al fichero de la corrida. La linea se emite empujando la
# barra hacia arriba, que vuelve a ocupar el renglon de abajo.
log() {
    local level="$1"
    shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    if [[ -n "${VBOXDISK_LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >>"$VBOXDISK_LOG_FILE"
    fi
    emit_line "$line"
}

# log_raw <texto>: conserva la salida cruda de un comando externo (el chatter
# del hipervisor) en la bitacora sin sacarla al terminal, para que no
# contamine la barra ni la salida visible.
log_raw() {
    [[ -n "${1:-}" ]] || return 0
    if [[ -n "${VBOXDISK_LOG_FILE:-}" ]]; then
        printf '%s\n' "$1" >>"$VBOXDISK_LOG_FILE"
    fi
    return 0
}

# Atajos de registro por nivel.
log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# Datos por stdout, separados del progreso y los registros.
say() { printf '%s\n' "$*"; }

# die <codigo> <mensaje>: error en el registro y terminacion con ese codigo.
die() {
    local code="$1"
    shift
    log_error "$@"
    exit "$code"
}

# read_answer <prompt>: imprime el prompt en stderr y devuelve la respuesta
# por stdout. Lee de stdin cuando es terminal y, si la entrada esta redirigida,
# de la terminal de control mientras stderr tambien lo sea (el caso de una
# corrida lanzada desde una terminal con la entrada tomada por otro proceso).
# Devuelve 1 cuando no hay terminal donde preguntar y 2 cuando la lectura se
# interrumpe. Se invoca siempre entre $( ), de modo que el cambio de stdin no
# escapa al llamador.
read_answer() {
    local prompt="$1" answer
    if [[ -t 0 ]]; then
        bar_suspend
        printf '%s ' "$prompt" >&2
        if ! IFS= read -r answer; then
            return 2
        fi
        bar_resume
        printf '%s' "$answer"
        return 0
    fi
    is_tty || return 1
    if ! { exec 0</dev/tty; } 2>/dev/null; then
        return 1
    fi
    bar_suspend
    printf '%s ' "$prompt" >&2
    if ! IFS= read -r answer; then
        return 2
    fi
    bar_resume
    printf '%s' "$answer"
}

# confirm <pregunta>: confirmacion de los caminos peligrosos. -y la omite y,
# sin terminal donde preguntar, se cancela porque no hay a quien formularla.
confirm() {
    local prompt="$1" answer rc=0
    if [[ "${VBOXDISK_ASSUME_YES:-0}" == "1" ]]; then
        log_info "confirmacion omitida por -y: $prompt"
        return 0
    fi
    answer="$(read_answer "$prompt [s/N]")" || rc=$?
    if ((rc == 1)); then
        log_error "no hay terminal donde preguntar: $prompt"
        log_info "responda en linea reejecutando la orden desde una terminal"
        return "$VBOXDISK_E_CANCEL"
    fi
    if ((rc == 2)); then
        close_prompt_line
        log_warn "lectura de la respuesta interrumpida"
        return "$VBOXDISK_E_CANCEL"
    fi
    case "${answer,,}" in
        s | si | sí | y | yes) return 0 ;;
        *)
            log_warn "operacion cancelada por el usuario"
            return "$VBOXDISK_E_CANCEL"
            ;;
    esac
}

# size_to_mb <texto>: tamano declarado normalizado a megabytes. Admite el entero
# solo (megabytes) o el sufijo m|mb|g|gb|t|tb, sin distincion de mayusculas;
# una cifra cero o una forma desconocida no es un tamano valido.
size_to_mb() {
    local raw num unit
    raw="${1,,}"
    if [[ ! "$raw" =~ ^([0-9]+)(m|mb|g|gb|t|tb)?$ ]]; then
        return 1
    fi
    num=$((10#${BASH_REMATCH[1]}))
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        g | gb) num=$((num * 1024)) ;;
        t | tb) num=$((num * 1024 * 1024)) ;;
    esac
    if ((num <= 0)); then
        return 1
    fi
    printf '%s' "$num"
}

# confirm_choice <pregunta>: decision sobre un disco registrado que ya no figura
# en el archivo declarativo: eliminarlo, dejarlo inactivo o saltarlo. -y elige
# eliminar; sin terminal no hay a quien preguntar y la corrida se cancela. La
# letra elegida queda en CHOICE (e, i o s).
confirm_choice() {
    local prompt="$1" answer rc=0
    CHOICE=""
    if [[ "${VBOXDISK_ASSUME_YES:-0}" == "1" ]]; then
        log_info "confirmacion omitida por -y: $prompt -> eliminar"
        CHOICE="e"
        return 0
    fi
    answer="$(read_answer "$prompt [e]liminar/[i]nactivar/[s]altar:")" || rc=$?
    if ((rc == 1)); then
        log_error "no hay terminal donde preguntar: $prompt"
        log_info "responda en linea reejecutando la orden desde una terminal"
        return "$VBOXDISK_E_CANCEL"
    fi
    if ((rc == 2)); then
        close_prompt_line
        log_warn "lectura de la respuesta interrumpida"
        return "$VBOXDISK_E_CANCEL"
    fi
    while :; do
        case "${answer,,}" in
            e | eliminar | d) CHOICE="e"; return 0 ;;
            i | inactivar) CHOICE="i"; return 0 ;;
            s | saltar | "") CHOICE="s"; return 0 ;;
        esac
        log_warn "respuesta no reconocida: $answer"
        rc=0
        answer="$(read_answer "$prompt [e]liminar/[i]nactivar/[s]altar:")" || rc=$?
        if ((rc == 1)); then
            log_error "no hay terminal donde preguntar: $prompt"
            log_info "responda en linea reejecutando la orden desde una terminal"
            return "$VBOXDISK_E_CANCEL"
        fi
        if ((rc == 2)); then
            close_prompt_line
            log_warn "lectura de la respuesta interrumpida"
            return "$VBOXDISK_E_CANCEL"
        fi
    done
}

# in_list <valor> [elementos...]: 0 si el valor figura en la lista.
in_list() {
    local want="$1" item
    shift
    for item in "$@"; do
        if [[ "$item" == "$want" ]]; then
            return 0
        fi
    done
    return 1
}

# stage_begin <n> <nombre>: abre la etapa n y pinta la barra si stderr es tty.
stage_begin() {
    VBOXDISK_STAGE_N="$1"
    VBOXDISK_STAGE_NAME="$2"
    VBOXDISK_STAGE_T0="$(now_s)"
    VBOXDISK_STAGE_OPEN=1
    VBOXDISK_STAGE_PAINTED=0
    bar_paint
}

# stage_end [codigo]: cierra la etapa, informa su duracion y la registra en
# la bitacora. Un codigo cero la cierra con "listo"; cualquier otro, con
# "fallida", porque una etapa que devolvio error no se completo. Con la
# barra pintada el cierre la reescribe en su renglon y lo cierra con salto
# de linea, quedando el resumen debajo; sin barra (salida sin terminal) se
# emite la linea plana con la misma distincion.
stage_end() {
    local rc="${1:-0}" dur word
    dur=$(($(now_s) - VBOXDISK_STAGE_T0))
    if ((rc == 0)); then
        word="listo"
    else
        word="fallida"
    fi
    if ((VBOXDISK_STAGE_PAINTED == 1)); then
        printf '\r\033[K%s %s (%ds)\n' \
            "$(bar_segment)" "$word" "$dur" >&2
    else
        printf '[%d/%d] %s ... %s (%ds)\n' \
            "$VBOXDISK_STAGE_N" "$VBOXDISK_STAGE_TOTAL" "$VBOXDISK_STAGE_NAME" \
            "$word" "$dur" >&2
    fi
    VBOXDISK_STAGE_OPEN=0
    VBOXDISK_STAGE_PAINTED=0
    if ((rc == 0)); then
        log_info "etapa $VBOXDISK_STAGE_N/$VBOXDISK_STAGE_TOTAL: $VBOXDISK_STAGE_NAME completada en ${dur}s"
    else
        log_error "etapa $VBOXDISK_STAGE_N/$VBOXDISK_STAGE_TOTAL: $VBOXDISK_STAGE_NAME fallida en ${dur}s"
    fi
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

# aggregate_code [codigo...]: el codigo final de la corrida es el de mayor
# severidad entre los devueltos por cada vm (0 si ninguna fallo).
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

# Cronometro total de la corrida, informado en el resumen final.
total_start() { VBOXDISK_TOTAL_T0="$(now_s)"; }

total_seconds() { printf '%s' "$(( $(now_s) - VBOXDISK_TOTAL_T0 ))"; }

# Temporales del host registrados para su destruccion en la trampa de salida.
VBOXDISK_TMP_PATHS=()

register_tmp() { VBOXDISK_TMP_PATHS+=("$1"); }

# Trampa de salida: primero borra el directorio en el invitado (necesita el
# fichero de credenciales temporal) y despues destruye ese fichero en el host.
cleanup_tmps() {
    local f
    bar_finalize
    if declare -F vbox_guest_rm >/dev/null 2>&1; then
        vbox_guest_cleanup_all || true
    fi
    for f in "${VBOXDISK_TMP_PATHS[@]}"; do
        if [[ -n "$f" && -e "$f" ]]; then
            shred -u "$f" 2>/dev/null || rm -f "$f"
        fi
    done
}
