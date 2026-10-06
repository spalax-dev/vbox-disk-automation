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

# @description Devuelve los segundos desde la época Unix; base de todos los cronómetros.
# @noargs
# @stdout Los segundos desde la época, sin salto de línea.
# @exitcode 0 Siempre.
now_s() { date +%s; }

# @description Indica si un comando está disponible en el PATH.
# @arg $1 string Nombre del comando a comprobar (vacío no permitido).
# @exitcode 0 El comando está en el PATH.
# @exitcode 1 El comando no está.
# @example
#   have_cmd VBoxManage && echo disponible
have_cmd() { command -v "$1" >/dev/null 2>&1; }

# @description Indica si stderr es un terminal; ahí cabe la barra de progreso.
# @noargs
# @exitcode 0 stderr es un terminal.
# @exitcode 1 stderr no es un terminal.
is_tty() { [[ -t 2 ]]; }

# @description Compone el segmento "[n/T] [barra] nombre" de la etapa en curso, sin el tiempo,
# para componer tanto la barra viva como el cierre de la etapa.
# La barra tiene 20 celdas: "=" para las ya contadas, ">" para la etapa en curso y espacios para las restantes.
# @noargs
# @stdout El segmento de la barra, sin salto de línea.
# @exitcode 0 Siempre.
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

# @description Devuelve el segmento de la barra con el tiempo transcurrido de la etapa en segundos.
# @noargs
# @stdout El segmento de la barra seguido de " <n>s", sin salto de línea.
# @exitcode 0 Siempre.
bar_text() {
    printf '%s %ds' "$(bar_segment)" "$(( $(now_s) - VBOXDISK_STAGE_T0 ))"
}

# @description Pinta la barra de la etapa en su propio renglón, el último del bloque, sin cerrarlo:
# el cursor queda al final de la barra y lo que la etapa escriba (registros, salidas del invitado,
# preguntas) la empuja hacia arriba.
# Solo actúa cuando hay etapa abierta y stderr es terminal; en cualquier otra salida la etapa usa la línea plana.
# @noargs
# @set VBOXDISK_STAGE_PAINTED int 1 cuando la barra queda pintada.
# @stderr La barra de progreso con \r y \033[K, sin salto de línea.
# @exitcode 0 Siempre (no pinta si no corresponde).
bar_paint() {
    ((VBOXDISK_STAGE_OPEN == 1)) || return 0
    is_tty || return 0
    printf '\r\033[K%s' "$(bar_text)" >&2
    VBOXDISK_STAGE_PAINTED=1
}

# @description Refresca la barra en su renglón con el tiempo actualizado, limpiándolo y volviéndolo
# a escribir sin salto de línea, de modo que el cursor sigue al final de la barra.
# Sin barra pintada o sin terminal no hace nada.
# @noargs
# @stderr La barra de progreso actualizada con \r y \033[K, sin salto de línea.
# @exitcode 0 Siempre.
bar_tick() {
    ((VBOXDISK_STAGE_PAINTED == 1)) || return 0
    is_tty || return 0
    printf '\r\033[K%s' "$(bar_text)" >&2
}

# @description Escribe una línea empujando la barra hacia arriba: limpia su renglón, pone el mensaje
# y repite la barra debajo, sin cerrarla, para que siempre quede al final.
# Con la barra pintada toda la salida de la etapa debe pasar por aquí; cualquier mensaje más ancho
# que el terminal se parte en varias filas y la barra desciende igual, sin contarlas.
# @arg $1 string Texto de la línea a emitir (se le agrega un salto de línea).
# @stderr El texto con salto de línea y, con la barra pintada, la barra repetida debajo.
# @exitcode 0 Siempre.
emit_line() {
    if ((VBOXDISK_STAGE_PAINTED == 1)); then
        printf '\r\033[K%s\n\r\033[K%s' "$1" "$(bar_text)" >&2
    else
        printf '%s\n' "$1" >&2
    fi
}

# @description Retira la barra del renglón antes de escribir un prompt, para que la pregunta ocupe
# ese renglón. Sin barra pintada no hace nada.
# @noargs
# @set VBOXDISK_STAGE_PAINTED int 0 al retirar la barra.
# @stderr Limpieza del renglón con \r\033[K (solo si había barra pintada).
# @exitcode 0 Siempre.
bar_suspend() {
    ((VBOXDISK_STAGE_PAINTED == 1)) || return 0
    printf '\r\033[K' >&2
    VBOXDISK_STAGE_PAINTED=0
}

# @description Vuelve a pintar la barra en el renglón corriente, al terminar la respuesta al prompt.
# Fuera de una etapa no hace nada.
# @noargs
# @exitcode 0 Siempre.
# @see bar_paint()
bar_resume() {
    ((VBOXDISK_STAGE_OPEN == 1)) || return 0
    bar_paint
}

# @description Cierra el renglón de un prompt cuya respuesta no llegó completa y repite la barra,
# para que el mensaje siguiente no se pegue a la pregunta.
# @noargs
# @stderr Un salto de línea y, con etapa abierta, la barra debajo.
# @exitcode 0 Siempre.
close_prompt_line() {
    printf '\n' >&2
    bar_resume
}

# @description En la trampa de salida cierra el renglón de una barra que quede pintada, para que el
# prompt no se pegue al avance. Sin barra pintada no hace nada.
# @noargs
# @set VBOXDISK_STAGE_PAINTED int 0 al cerrar el renglón.
# @stderr Un salto de línea (solo si había barra pintada).
# @exitcode 0 Siempre.
bar_finalize() {
    if ((VBOXDISK_STAGE_PAINTED == 1)); then
        printf '\n' >&2
        VBOXDISK_STAGE_PAINTED=0
    fi
}

# @description Registra un mensaje con sello de tiempo y nivel: lo emite en stderr empujando la
# barra hacia arriba y, si hay bitácora, agrega la misma línea al fichero de la corrida.
# @arg $1 string Nivel del mensaje (p. ej. INFO, WARN, ERROR).
# @arg $2 string Mensaje; los argumentos a partir de $2 se unen con un espacio (variadic).
# @stderr La línea "YYYY-MM-DD HH:MM:SS [nivel] mensaje" (con la barra repetida debajo si está pintada).
# @exitcode 0 Siempre.
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

# @description Conserva la salida cruda de un comando externo (el chatter del hipervisor) en la
# bitácora sin sacarla al terminal, para que no contamine la barra ni la salida visible.
# @arg $1 string Línea a guardar; cadena vacía no hace nada.
# @exitcode 0 Siempre (también con cadena vacía).
log_raw() {
    [[ -n "${1:-}" ]] || return 0
    if [[ -n "${VBOXDISK_LOG_FILE:-}" ]]; then
        printf '%s\n' "$1" >>"$VBOXDISK_LOG_FILE"
    fi
    return 0
}

# @description Atajo de log() con nivel INFO: mensaje con sello de tiempo en stderr y, si hay
# bitácora, la misma línea en el fichero de la corrida.
# @arg $1 string Mensaje; los argumentos se unen con un espacio (variadic).
# @exitcode 0 Siempre.
log_info() { log "INFO" "$@"; }
# @description Atajo de log() con nivel WARN, con el mismo formato que log_info().
# @arg $1 string Mensaje; los argumentos se unen con un espacio (variadic).
# @exitcode 0 Siempre.
log_warn() { log "WARN" "$@"; }
# @description Atajo de log() con nivel ERROR, con el mismo formato que log_info().
# @arg $1 string Mensaje; los argumentos se unen con un espacio (variadic).
# @exitcode 0 Siempre.
log_error() { log "ERROR" "$@"; }

# @description Escribe datos por stdout, separados del progreso y los registros.
# @arg $1 string Texto; los argumentos se unen con un espacio (variadic).
# @stdout El texto seguido de salto de línea.
# @exitcode 0 Siempre.
say() { printf '%s\n' "$*"; }

# @description Registra el error con nivel ERROR y termina el proceso con el código dado.
# @arg $1 int Código de salida (los del proyecto: 0 ok, 1 uso/configuración, 2 comunicación, 3 almacenamiento, 4 cancelado).
# @arg $2 string Mensaje del error; los argumentos a partir de $2 se unen con un espacio (variadic).
# @stderr El mensaje con sello de tiempo y nivel [ERROR], con la barra empujada hacia arriba.
# @exitcode $1 Termina con el código indicado en $1.
die() {
    local code="$1"
    shift
    log_error "$@"
    exit "$code"
}

# @description Imprime el prompt en stderr y devuelve la respuesta por stdout.
# Lee de stdin cuando es terminal y, si la entrada está redirigida, de la terminal de control mientras
# stderr también lo sea (el caso de una corrida lanzada desde una terminal con la entrada tomada por
# otro proceso).
# Se invoca siempre entre $( ), de modo que el cambio de stdin no escapa al llamador.
# @arg $1 string Prompt a mostrar (se le agrega un espacio; la respuesta no forma parte del prompt).
# @stdout La respuesta leída, sin salto de línea.
# @stderr El prompt; la barra se retira antes y se repite después.
# @exitcode 0 Lectura completa.
# @exitcode 1 No hay terminal donde preguntar.
# @exitcode 2 La lectura se interrumpe.
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

# @description Confirmación de los caminos peligrosos: pregunta en la terminal y acepta como
# afirmativas s, si, sí, y o yes, sin distinción de mayúsculas.
# -y (VBOXDISK_ASSUME_YES=1) la omite y, sin terminal donde preguntar, se cancela porque no hay a
# quien formularla.
# @arg $1 string Pregunta; se le agrega " [s/N]".
# @stderr El prompt y los registros de la decisión (INFO con -y, ERROR sin terminal, WARN al cancelar).
# @exitcode 0 Confirmada (respuesta afirmativa o -y).
# @exitcode 4 Cancelada: sin terminal, lectura interrumpida o respuesta no afirmativa (VBOXDISK_E_CANCEL).
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

# @description Normaliza un tamaño declarado a megabytes.
# Admite el entero solo (megabytes) o el sufijo m|mb|g|gb|t|tb, sin distinción de mayúsculas, con
# 1 g = 1024 MB y 1 t = 1024*1024 MB; una cifra cero o una forma desconocida no es un tamaño válido.
# @arg $1 string Tamaño a convertir, p. ej. "512", "512m", "4g", "1t"; sin espacios y sin vacío.
# @stdout El tamaño en MB, sin salto de línea.
# @exitcode 0 Conversión exitosa.
# @exitcode 1 Forma desconocida o tamaño cero.
# @example
#   size_to_mb 4g   # imprime 4096
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

# @description Decide sobre un disco registrado que ya no figura en el archivo declarativo:
# eliminarlo, dejarlo inactivo o saltarlo.
# Acepta e|eliminar|d, i|inactivar y s|saltar (respuesta vacía = saltar), sin distinción de
# mayúsculas; una respuesta no reconocida vuelve a preguntar. -y elige eliminar; sin terminal no hay
# a quien preguntar y la corrida se cancela.
# @arg $1 string Pregunta; se le agrega " [e]liminar/[i]nactivar/[s]altar:".
# @set CHOICE string Letra elegida: "e" eliminar, "i" inactivar o "s" saltar; queda vacía si se cancela.
# @stderr El prompt y los registros de la decisión o de la respuesta no reconocida.
# @exitcode 0 Decisión tomada (CHOICE con e, i o s).
# @exitcode 4 Cancelada: sin terminal o lectura interrumpida (VBOXDISK_E_CANCEL).
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

# @description Indica si un valor figura en la lista.
# @arg $1 string Valor a buscar.
# @arg $2 string Elementos de la lista; todos los argumentos a partir de $2 se comparan con coincidencia exacta, sin patrones (variadic).
# @exitcode 0 El valor figura en la lista.
# @exitcode 1 El valor no figura.
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

# @description Abre la etapa n, reinicia su cronómetro y pinta la barra si stderr es terminal.
# @arg $1 int Número de etapa, mostrado como [n/T] con T = VBOXDISK_STAGE_TOTAL (5 por defecto).
# @arg $2 string Nombre de la etapa, visible en la barra y en el registro.
# @set VBOXDISK_STAGE_N int Número de la etapa en curso.
# @set VBOXDISK_STAGE_NAME string Nombre de la etapa en curso.
# @set VBOXDISK_STAGE_T0 int Segundos desde la época al abrir la etapa (cronómetro de la etapa).
# @set VBOXDISK_STAGE_OPEN int 1 mientras la etapa está abierta.
# @set VBOXDISK_STAGE_PAINTED int 0 al abrir; queda en 1 si la barra se pinta.
# @stderr La barra de progreso (solo si stderr es terminal).
# @exitcode 0 Siempre.
stage_begin() {
    VBOXDISK_STAGE_N="$1"
    VBOXDISK_STAGE_NAME="$2"
    VBOXDISK_STAGE_T0="$(now_s)"
    VBOXDISK_STAGE_OPEN=1
    VBOXDISK_STAGE_PAINTED=0
    bar_paint
}

# @description Cierra la etapa, informa su duración y la registra en la bitácora.
# Un código cero la cierra con "listo"; cualquier otro, con "fallida", porque una etapa que devolvió
# error no se completó. Con la barra pintada el cierre la reescribe en su renglón y lo cierra con
# salto de línea, quedando el resumen debajo; sin barra (salida sin terminal) se emite la línea
# plana con la misma distinción.
# @arg $1 int Código de la etapa; opcional, por defecto 0. Cero cierra como "listo" y cualquier otro valor como "fallida".
# @set VBOXDISK_STAGE_OPEN int 0 al cerrar la etapa.
# @set VBOXDISK_STAGE_PAINTED int 0 al cerrar la etapa.
# @stderr El resumen "[n/T] nombre ... listo/fallida (Xs)" y el registro INFO o ERROR con la
#  duración en segundos.
# @exitcode 0 Siempre; el código recibido solo clasifica el resumen.
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

# @description Severidad de los códigos de salida: los globales 1 y 4 dominan; entre los
# particulares, 3 precede a 2 (Tabla tab:codigos).
# @arg $1 int Código de salida; cualquier valor fuera de 0-4 pesa 0.
# @stdout La severidad sin formato: 40 (1), 30 (4), 20 (3), 10 (2) o 0 (el resto).
# @exitcode 0 Siempre.
code_weight() {
    case "$1" in
        1) printf '40' ;;
        4) printf '30' ;;
        3) printf '20' ;;
        2) printf '10' ;;
        *) printf '0' ;;
    esac
}

# @description Devuelve el código final de la corrida: el de mayor severidad entre los devueltos por
# cada vm (0 si ninguna falló).
# @arg $1 int Códigos a comparar; todos los argumentos se evalúan y, sin argumentos, devuelve 0 (variadic).
# @stdout El código final, sin salto de línea.
# @exitcode 0 Siempre.
# @example
#   aggregate_code 0 3   # imprime 3
# @see code_weight()
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

# @description Marca el inicio del cronómetro total de la corrida, informado en el resumen final.
# @noargs
# @set VBOXDISK_TOTAL_T0 int Segundos desde la época al iniciar el cronómetro.
# @exitcode 0 Siempre.
total_start() { VBOXDISK_TOTAL_T0="$(now_s)"; }

# @description Devuelve los segundos transcurridos desde total_start().
# @noargs
# @stdout Los segundos transcurridos, sin salto de línea.
# @exitcode 0 Siempre.
# @see total_start()
total_seconds() { printf '%s' "$(( $(now_s) - VBOXDISK_TOTAL_T0 ))"; }

# Temporales del host registrados para su destruccion en la trampa de salida.
VBOXDISK_TMP_PATHS=()

# @description Registra un temporal del host para su destrucción en la trampa de salida.
# @arg $1 path Ruta del fichero o directorio temporal a acumular.
# @set VBOXDISK_TMP_PATHS array Rutas acumuladas para destruir después.
# @exitcode 0 Siempre.
# @see cleanup_tmps()
register_tmp() { VBOXDISK_TMP_PATHS+=("$1"); }

# @description Trampa de salida: cierra el renglón de una barra pintada, borra primero el directorio
# en el invitado (necesita el fichero de credenciales temporal) y después destruye ese fichero en el
# host con shred y, si falla, con rm. Los fallos de borrado se descartan.
# @noargs
# @stderr Un salto de línea si había barra pintada (el resto de la salida depende de las funciones
#  del invitado que invoca).
# @see bar_finalize()
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
