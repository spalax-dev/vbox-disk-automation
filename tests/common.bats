#!/usr/bin/env bats
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
# common.bats: la barra vive en el ultimo renglon del bloque de su etapa y
# los mensajes la empujan hacia arriba con \r, \x1b[K y salto de linea (sin
# cursor arriba/abajo, que se desalinean al partir lineas anchas), el tiempo
# corre en la propia barra, el cierre distingue etapa completada de
# fallida, el prompt retira y devuelve la barra, y la salida sin terminal es
# plana.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    source "$REPO/src/lib/common.sh"
    # La mayoria de las pruebas fingen un terminal: la barra solo se pinta
    # cuando stderr lo es, y aqui se fuerza ese camino para inspeccionar las
    # secuencias de control que quedarian en pantalla.
    is_tty() { return 0; }
}

@test "la barra siempre queda al final y los mensajes la empujan hacia arriba" {
    local err="$BATS_TEST_TMPDIR/err" data first_bar first_msg raw_idx close_idx
    {
        stage_begin 1 "verificacion declarativa de VM1"
        log_info "mensaje uno"
        log_warn "mensaje dos"
        emit_line "salida cruda del invitado"
        stage_end 0
    } 2>"$err"
    data="$(cat "$err")"
    # Nunca hay cursor arriba/abajo: el unico control ANSI permitido es
    # limpiar renglon, que es inmune al ancho de terminal.
    [ "$(grep -oP $'\x1b\[[0-9]*[A-Za-z]' <<<"$data" | sort -u)" = $'\x1b[K' ]
    # Cinco apariciones del segmento: pintada inicial, tres redibujos (uno
    # por mensaje) y el cierre, que cierra su renglon con salto de linea.
    [ "$(grep -oF '[1/5]' <<<"$data" | wc -l)" -eq 5 ]
    # Cada mensaje se escribe sobre el renglon limpio que ocupaba la barra
    # y la barra vuelve a aparecer debajo, en el renglon siguiente.
    grep -zqP '\x1b\[K[^\n]*\[INFO\] mensaje uno' <<<"$data"
    grep -zqP 'mensaje uno\n\r\x1b\[K\[1/5\]' <<<"$data"
    grep -zqP 'salida cruda del invitado\n\r\x1b\[K\[1/5\]' <<<"$data"
    # El primer mensaje aparece despues de la primera pintada.
    first_bar="$(grep -bo -m1 'verificacion declarativa de VM1' <<<"$data" | cut -d: -f1)"
    first_msg="$(grep -bo -m1 'mensaje uno' <<<"$data" | cut -d: -f1)"
    [ -n "$first_bar" ] && [ -n "$first_msg" ]
    [ "$first_msg" -gt "$first_bar" ]
    # El cierre de la etapa aparece despues de la ultima salida.
    raw_idx="$(grep -bo -m1 'salida cruda del invitado' <<<"$data" | cut -d: -f1)"
    close_idx="$(grep -bo -m1 'listo' <<<"$data" | cut -d: -f1)"
    [ "$close_idx" -gt "$raw_idx" ]
    # La barra muestra el tiempo transcurrido y el cierre cierra la cuenta.
    grep -qP 'verificacion declarativa de VM1 [0-9]+s' <<<"$data"
    grep -qP 'listo \([0-9]+s\)$' <<<"$data"
    grep -q 'etapa 1/5: verificacion declarativa de VM1 completada en' <<<"$data"
}

@test "stage_end con error cierra la barra como fallida y lo registra" {
    local err="$BATS_TEST_TMPDIR/err"
    {
        stage_begin 2 "disponibilidad de VM1"
        stage_end 2
    } 2>"$err"
    grep -qP '\[2/5\][^\x1b]*fallida \([0-9]+s\)$' "$err"
    grep -q 'etapa 2/5: disponibilidad de VM1 fallida en' "$err"
    ! grep -q 'completada en' "$err"
}

@test "el prompt retira la barra y la respuesta la devuelve" {
    local err="$BATS_TEST_TMPDIR/err"
    {
        stage_begin 1 "verificacion declarativa de VM1"
        bar_suspend
        printf 'descartar VM1? [s/N] ' >&2
        printf 'si\n' >&2
        bar_resume
        log_info "confirmacion aceptada"
        stage_end 0
    } 2>"$err"
    # La pregunta ocupa el renglon que liberaba la barra y el aviso vuelve
    # a empujarla hacia arriba; no quedan secuencias de cursor.
    grep -q 'descartar VM1? \[s/N\]' "$err"
    grep -zqP '\x1b\[K[^\n]*\[INFO\] confirmacion aceptada' "$err"
    ! grep -qP $'\x1b\[[0-9]+[FE]' "$err"
    grep -qP 'listo \([0-9]+s\)$' "$err"
}

@test "sin terminal la etapa emite la linea plana sin secuencias de control" {
    is_tty() { [[ -t 2 ]]; }
    local err="$BATS_TEST_TMPDIR/err"
    {
        stage_begin 1 "verificacion declarativa de VM1"
        log_info "mensaje uno"
        stage_end 0
    } 2>"$err"
    ! grep -q $'\x1b' "$err"
    grep -qxF '[1/5] verificacion declarativa de VM1 ... listo (0s)' "$err"
    grep -q '\[INFO\] mensaje uno' "$err"
    grep -q 'etapa 1/5: verificacion declarativa de VM1 completada en 0s' "$err"
}

@test "sin terminal una etapa fallida anuncia fallida en la linea plana" {
    is_tty() { [[ -t 2 ]]; }
    local err="$BATS_TEST_TMPDIR/err"
    {
        stage_begin 3 "identificacion de la direccion IP de VM1"
        stage_end 2
    } 2>"$err"
    ! grep -q $'\x1b' "$err"
    grep -qxF '[3/5] identificacion de la direccion IP de VM1 ... fallida (0s)' "$err"
    grep -q 'etapa 3/5: identificacion de la direccion IP de VM1 fallida en 0s' "$err"
}

@test "log_raw conserva la salida cruda solo en la bitacora" {
    local log="$BATS_TEST_TMPDIR/run.log" err="$BATS_TEST_TMPDIR/err"
    VBOXDISK_LOG_FILE="$log"
    {
        log_raw "0%...100%...100%"
        log_raw ""
    } 2>"$err"
    grep -q '0%...100%...100%' "$log"
    [ ! -s "$err" ]
}

@test "el renglon de un prompt interrumpido se cierra antes del aviso" {
    local err="$BATS_TEST_TMPDIR/err"
    {
        stage_begin 1 "verificacion declarativa de VM1"
        bar_suspend
        printf 'descartar VM1? [s/N] ' >&2
        close_prompt_line
        log_warn "lectura de la respuesta interrumpida"
        stage_end 0
    } 2>"$err"
    # El aviso no se pega al prompt: el renglon quedo cerrado y la barra se
    # repitio debajo antes de escribir.
    grep -q 'lectura de la respuesta interrumpida' "$err"
    grep -zqP '\x1b\[K[^\n]*\[WARN\] lectura de la respuesta interrumpida' "$err"
    grep -qP 'listo \([0-9]+s\)$' "$err"
    # Pintada inicial, repeticion al cerrar el prompt, redibujo del aviso y
    # cierre: cuatro apariciones del segmento, sin cursor arriba/abajo.
    [ "$(grep -oF '[1/5]' "$err" | wc -l)" -eq 4 ]
    ! grep -qP $'\x1b\[[0-9]+[FE]' "$err"
}
