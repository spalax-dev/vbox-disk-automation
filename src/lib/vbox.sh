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
# vbox.sh: envoltorios de VBoxManage (arranque, disponibilidad, IP y guestcontrol).

# Credenciales de la sesion con el invitado y tiempos por defecto; estos
# ultimos se sobreescriben con las variables de entorno VBOXDISK_*.
VBOXDISK_GUEST_USER=""
VBOXDISK_GUEST_PASSFILE=""
VBOXDISK_READY_TIMEOUT="${VBOXDISK_READY_TIMEOUT:-120}"
VBOXDISK_IP_TIMEOUT="${VBOXDISK_IP_TIMEOUT:-60}"
VBOXDISK_GUEST_TIMEOUT="${VBOXDISK_GUEST_TIMEOUT:-300}"

# @description Comprueba las dependencias de ejecución en el host (VBoxManage,
# yq e ip); si falta alguna, termina la corrida.
# @noargs
# @stderr log_error con el nombre de la dependencia que falte.
# @exitcode 0 Las tres dependencias están disponibles.
# @exitcode 1 Faltan dependencias (VBOXDISK_E_CONFIG): sale del proceso.
vbox_require() {
    if ! have_cmd VBoxManage; then
        die "$VBOXDISK_E_CONFIG" "VBoxManage no esta disponible en el host (dependencia de ejecucion)"
    fi
    if ! have_cmd yq; then
        die "$VBOXDISK_E_CONFIG" "yq no esta disponible en el host (dependencia de ejecucion)"
    fi
    if ! have_cmd ip; then
        die "$VBOXDISK_E_CONFIG" "ip no esta disponible en el host (dependencia de ejecucion)"
    fi
}

# @description Indica si el nombre figura en la salida de VBoxManage list vms,
# con comparación exacta del nombre entre comillas.
# @arg $1 string Nombre exacto de la máquina virtual.
# @exitcode 0 La máquina existe en el hipervisor.
# @exitcode 1 La máquina no existe o la lista no se pudo leer.
vbox_vm_exists() {
    local name="$1"
    VBoxManage list vms 2>/dev/null | awk -F'"' -v n="$name" '$2 == n { found = 1 } END { exit found ? 0 : 1 }'
}

# @description Lee una clave de la salida --machinereadable de VBoxManage
# showvminfo.
# @arg $1 string Nombre de la máquina virtual.
# @arg $2 string Clave a leer (p. ej. VMState, CfgFile, macaddress1).
# @stdout Valor de la clave, sin las comillas que lo rodean, con salto de línea.
# @exitcode 0 La clave aparece en la salida.
# @exitcode 1 La clave no aparece o la máquina no se pudo consultar.
vbox_info() {
    local vm="$1" key="$2"
    VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        awk -F'"' -v k="$key" '$1 == k "=" { print $2; found = 1 } END { exit found ? 0 : 1 }'
}

# @description Estado de encendido de la máquina, leído de la clave VMState.
# @arg $1 string Nombre de la máquina virtual.
# @stdout El estado con salto de línea (p. ej. running, poweroff, aborted,
#  saved, paused, starting, stuck).
# @exitcode 0 Estado leído.
# @exitcode 1 No se pudo leer el estado (máquina desconocida).
# @see vbox_info()
vbox_power_state() {
    vbox_info "$1" VMState
}

# @description Enciende la máquina en modo headless si aún no lo está y aguarda
# a que alcance el estado running. Si ya está running no hace nada; si está
# arrancando, solo aguarda.
# @arg $1 string Nombre de la máquina virtual.
# @stderr log_info al iniciar, log_error si el estado impide el arranque o si
#  no se alcanza running, y refrescos de la barra de progreso.
# @exitcode 0 La máquina quedó en running (o ya lo estaba).
# @exitcode 2 No arrancó en 30 s, VBoxManage startvm falló o el estado actual lo impide (VBOXDISK_E_COMM).
vbox_start() {
    local vm="$1" i state
    state="$(vbox_power_state "$vm" || true)"
    case "$state" in
        running)
            # Ya estaba encendida: nada que hacer.
            return 0
            ;;
        starting)
            # Arranque en curso: solo se aguarda a que alcance running.
            ;;
        "" | poweroff | aborted | saved | paused | stuck | teleported)
            # Cualquier estado apagado o guardado admite startvm headless.
            log_info "$vm: encendiendo en modo headless"
            if ! VBoxManage startvm "$vm" --type headless >/dev/null 2>&1; then
                log_error "no se pudo encender $vm con VBoxManage startvm"
                return "$VBOXDISK_E_COMM"
            fi
            ;;
        *)
            log_error "$vm esta en un estado que impide el arranque: $state"
            return "$VBOXDISK_E_COMM"
            ;;
    esac
    for ((i = 0; i < 30; i++)); do
        if [[ "$(vbox_power_state "$vm" || true)" == "running" ]]; then
            return 0
        fi
        bar_tick
        sleep 1
    done
    log_error "$vm no alcanzo el estado running tras el arranque"
    return "$VBOXDISK_E_COMM"
}

# @description Apaga la máquina de forma ordenada con el botón ACPI y, si no
# responde en 60 s, fuerza el apagado con controlvm poweroff.
# @arg $1 string Nombre de la máquina virtual.
# @stderr log_warn cuando hay que forzar el apagado, y refrescos de la barra
#  de progreso.
# @exitcode 0 Siempre: tanto si el apagado ACPI respondió como si hubo que forzarlo.
vbox_stop() {
    local vm="$1" t0 state
    VBoxManage controlvm "$vm" acpipowerbutton >/dev/null 2>&1 || true
    t0="$(now_s)"
    while (($(now_s) - t0 < 60)); do
        state="$(vbox_power_state "$vm" || true)"
        if [[ "$state" == "poweroff" || "$state" == "aborted" || "$state" == "saved" ]]; then
            return 0
        fi
        bar_tick
        sleep 2
    done
    log_warn "$vm no respondio al apagado ACPI; se fuerza el apagado"
    VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
    bar_tick
    sleep 2
    return 0
}

# @description Indica si Guest Additions ya publicó su versión como propiedad
# del invitado. VBox 7.2 usa /VirtualBox/GuestAdd/Version y otros empaquetados
# publican /VirtualBox/GuestAdditions/Version; se acepta cualquiera de las dos
# para no depender del nombre que elija cada empaquetado.
# @arg $1 string Nombre de la máquina virtual.
# @exitcode 0 Guest Additions publica su versión.
# @exitcode 1 Ninguna de las dos propiedades tiene valor.
vbox_guest_ready() {
    local vm="$1" prop
    for prop in /VirtualBox/GuestAdd/Version /VirtualBox/GuestAdditions/Version; do
        if VBoxManage guestproperty get "$vm" "$prop" 2>/dev/null | grep -q '^Value:'; then
            return 0
        fi
    done
    return 1
}

# @description Aguarda a que VBoxService publique las propiedades de Guest
# Additions, comprobando cada 2 s hasta agotar el tiempo.
# @arg $1 string Nombre de la máquina virtual.
# @arg $2 int Segundos máximos de espera; por defecto 120 s.
# @stderr Refrescos de la barra de progreso.
# @exitcode 0 Guest Additions publicó su versión a tiempo.
# @exitcode 1 Se agotó el tiempo de espera.
# @see vbox_guest_ready()
vbox_wait_ready() {
    local vm="$1" timeout="${2:-120}" t0
    t0="$(now_s)"
    while :; do
        if vbox_guest_ready "$vm"; then
            return 0
        fi
        if (($(now_s) - t0 >= timeout)); then
            return 1
        fi
        bar_tick
        sleep 2
    done
}

# @description Devuelve la propiedad Net/0/V4/IP de Guest Additions cuando es
# una IPv4 con el formato válido (cuatro octetos separados por punto).
# @arg $1 string Nombre de la máquina virtual.
# @stdout La IPv4, sin salto de línea.
# @exitcode 0 La propiedad contiene una IPv4 válida.
# @exitcode 1 La propiedad está vacía o no tiene formato IPv4.
# @see vbox_detect_ip()
vbox_guestproperty_ip() {
    local vm="$1" out
    out="$(VBoxManage guestproperty get "$vm" /VirtualBox/GuestInfo/Net/0/V4/IP 2>/dev/null || true)"
    out="${out#Value: }"
    if [[ "$out" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$out"
        return 0
    fi
    return 1
}

# @description MAC del adaptador 1 de la máquina en el formato que espera la
# tabla ARP: dos puntos como separador y letras en minúsculas.
# @arg $1 string Nombre de la máquina virtual.
# @stdout La MAC con dos puntos en minúsculas, sin salto de línea.
# @exitcode 0 MAC leída.
# @exitcode 1 La máquina no informa macaddress1.
vbox_mac() {
    local raw
    raw="$(vbox_info "$1" macaddress1 || true)"
    if [[ -z "$raw" ]]; then
        return 1
    fi
    printf '%s' "$raw" | sed 's/../&:/g; s/:$//' | tr '[:upper:]' '[:lower:]'
}

# @description Busca la IP asociada a una MAC en la tabla ARP de la red en
# puente (ip neigh show), como respaldo cuando Guest Additions no informa la
# IP. La comparación no distingue mayúsculas.
# @arg $1 string MAC con dos puntos en minúsculas.
# @stdout La IP encontrada, sin salto de línea.
# @exitcode 0 La MAC figura en la tabla ARP.
# @exitcode 1 La MAC no figura o la tabla no arrojó ninguna IP.
# @see vbox_detect_ip()
vbox_arp_ip() {
    local mac="$1" found
    found="$(ip neigh show 2>/dev/null |
        awk -v m="$mac" 'tolower($0) ~ tolower(m) { print $1; exit }')"
    if [[ -n "$found" ]]; then
        printf '%s' "$found"
        return 0
    fi
    return 1
}

# @description Detecta la IP de la máquina reintentando cada 2 s hasta agotar
# el tiempo: primero lee la propiedad de Guest Additions y, si no está, recurre
# a la tabla ARP con la MAC del adaptador 1.
# @arg $1 string Nombre de la máquina virtual.
# @arg $2 int Segundos máximos de espera; por defecto 60 s.
# @stdout La IP detectada, sin salto de línea.
# @stderr Refrescos de la barra de progreso.
# @exitcode 0 IP detectada.
# @exitcode 1 Se agotó el tiempo sin obtener ninguna IP.
# @example
#   ip="$(vbox_detect_ip web60)" || echo "sin IP"
# @see vbox_guestproperty_ip()
vbox_detect_ip() {
    local vm="$1" timeout="${2:-60}" t0 ip mac
    t0="$(now_s)"
    while :; do
        if ip="$(vbox_guestproperty_ip "$vm")"; then
            printf '%s' "$ip"
            return 0
        fi
        if mac="$(vbox_mac "$vm")" && ip="$(vbox_arp_ip "$mac")"; then
            printf '%s' "$ip"
            return 0
        fi
        if (($(now_s) - t0 >= timeout)); then
            return 1
        fi
        bar_tick
        sleep 2
    done
}

# @description Ejecuta una suborden de VBoxManage guestcontrol con el usuario y
# el fichero de credenciales de la sesión con el invitado, que prepara
# guest_session_open antes de llamar a esta biblioteca.
# @arg $1 string Nombre de la máquina virtual.
# @arg $@ string Argumentos de la suborden (mktemp, copyto, run, ...), desde $2, pasados tal cual a VBoxManage.
# @exitcode 0 La suborden terminó sin errores; si falla, se propaga el código que devuelve VBoxManage.
# @see guest_session_open()
vbox_gc() {
    local vm="$1"
    shift
    VBoxManage guestcontrol "$vm" \
        --username "$VBOXDISK_GUEST_USER" \
        --passwordfile "$VBOXDISK_GUEST_PASSFILE" "$@"
}

# @description Crea un directorio temporal en el invitado (bajo /tmp con la
# plantilla vboxdisk.XXXXXX) y devuelve su ruta. La salida
# "Directory name: <ruta>" se reduce a la ruta absoluta.
# @arg $1 string Nombre de la máquina virtual.
# @stdout La ruta absoluta del directorio, sin salto de línea.
# @exitcode 0 Directorio creado y ruta devuelta.
# @exitcode 1 La respuesta del invitado no es una ruta absoluta; si mktemp falló, se propaga el código de vbox_gc.
# @see vbox_guest_rm()
vbox_guest_mktemp_dir() {
    local out path
    out="$(vbox_gc "$1" mktemp --directory --tmpdir=/tmp 'vboxdisk.XXXXXX')" || return $?
    path="${out#Directory name: }"
    path="${path%%$'\n'*}"
    if [[ "$path" != /* ]]; then
        return 1
    fi
    printf '%s' "$path"
}

# @description Copia un fichero del host al directorio indicado del invitado,
# en silencio. El destino lleva barra final: sin ella, VBoxManage 7.2 toma
# --target-directory como la ruta del fichero de destino y falla contra un
# directorio existente con el mismo nombre. La salida del hipervisor se
# captura para no empujar la barra ni pegarla a los registros de la etapa, y
# se conserva en la bitácora.
# @arg $1 string Nombre de la máquina virtual.
# @arg $2 path Directorio de destino en el invitado; se le añade la barra final si no termina en ella.
# @arg $3 path Fichero de origen en el host.
# @exitcode 0 Copia completada; si falla, se propaga el código de VBoxManage.
vbox_guest_copy_to() {
    local vm="$1" dir="$2" file="$3" out rc=0
    case "$dir" in
        */) ;;
        *) dir="$dir/" ;;
    esac
    # La salida del hipervisor se captura para no empujar la barra ni
    # pegarsela a los registros de la etapa; se conserva en la bitacora.
    out="$(vbox_gc "$vm" copyto --quiet --target-directory="$dir" "$file" 2>&1)" || rc=$?
    log_raw "$out"
    return "$rc"
}

# @description Ejecuta un script del invitado con /bin/bash a través de
# guestcontrol. El programa va justo después de --, de modo que bash recibe
# el script como operando y sus argumentos tal cual.
# @arg $1 string Nombre de la máquina virtual.
# @arg $2 path Directorio de trabajo del proceso en el invitado (--cwd).
# @arg $3 int Tiempo límite en segundos; guestcontrol lo recibe en milisegundos.
# @arg $4 path Ruta del script en el invitado.
# @arg $@ string Argumentos del script, desde $5, pasados tal cual.
# @exitcode 0 El programa terminó sin errores; si falla, se propaga el código que devuelve VBoxManage.
vbox_guest_run() {
    local vm="$1" cwd="$2" secs="$3" script="$4"
    shift 4
    vbox_gc "$vm" run --timeout="$((secs * 1000))" --cwd="$cwd" -- \
        /bin/bash "$script" "$@"
}

# @description Borra un directorio del invitado con /bin/rm -rf usando la misma
# sesión: la suborden rm solo acepta ficheros individuales, así que para el
# directorio temporal completo se despacha rm. Es mejor esfuerzo con un tope
# de 15 s; los fallos se descartan.
# @arg $1 string Nombre de la máquina virtual.
# @arg $2 path Ruta del directorio a borrar en el invitado.
# @exitcode 0 Siempre: cualquier fallo o timeout se ignora.
vbox_guest_rm() {
    local vm="$1" dir="$2"
    timeout 15 VBoxManage guestcontrol "$vm" \
        --username "$VBOXDISK_GUEST_USER" \
        --passwordfile "$VBOXDISK_GUEST_PASSFILE" \
        run --quiet --timeout=15000 -- /bin/rm -rf "$dir" >/dev/null 2>&1 || true
}

# Directorios temporales del invitado abiertos en esta corrida.
VBOXDISK_GUEST_DIRS=()

# @description Añade un directorio temporal del invitado a la lista de
# pendientes de limpieza, para que la trampa de salida lo borre.
# @arg $1 path Ruta del directorio en el invitado.
# @set VBOXDISK_GUEST_DIRS array Registra el directorio como pendiente.
# @see vbox_guest_cleanup_all()
vbox_guest_track_dir() {
    VBOXDISK_GUEST_DIRS+=("$1")
}

# @description Retira de la lista de pendientes un directorio que ya fue
# borrado; si la ruta no está registrada, no hace nada.
# @arg $1 path Ruta del directorio en el invitado.
# @set VBOXDISK_GUEST_DIRS array Elimina la entrada que coincida con la ruta.
# @exitcode 0 Siempre, haya coincidido o no.
# @see vbox_guest_track_dir()
vbox_guest_untrack_dir() {
    local dir="$1" i
    for i in "${!VBOXDISK_GUEST_DIRS[@]}"; do
        if [[ "${VBOXDISK_GUEST_DIRS[$i]}" == "$dir" ]]; then
            unset "VBOXDISK_GUEST_DIRS[$i]"
            return 0
        fi
    done
    return 0
}

# @description Mejor esfuerzo en la trampa de salida: borra del invitado cada
# directorio registrado con vbox_guest_track_dir. No hace nada si no hay una
# máquina en curso (VBOXDISK_CURRENT_VM vacía).
# @noargs
# @set VBOXDISK_GUEST_DIRS array Queda vacía al terminar.
# @exitcode 0 Siempre.
# @see vbox_guest_rm()
vbox_guest_cleanup_all() {
    local dir vm="${VBOXDISK_CURRENT_VM:-}"
    [[ -n "$vm" ]] || return 0
    for dir in "${VBOXDISK_GUEST_DIRS[@]}"; do
        if [[ -n "$dir" ]]; then
            vbox_guest_rm "$vm" "$dir"
        fi
    done
    VBOXDISK_GUEST_DIRS=()
}

# @description Directorio de la máquina en el host, tomado de la clave CfgFile
# de showvminfo; de ahí salen los discos por defecto cuando el archivo
# declarativo no fija un fichero concreto.
# @arg $1 string Nombre de la máquina virtual.
# @stdout Ruta del directorio que contiene el fichero .vbox, con salto de línea.
# @exitcode 0 Directorio resuelto.
# @exitcode 1 CfgFile ausente o no es una ruta absoluta.
vbox_vm_dir() {
    local cfg
    cfg="$(vbox_info "$1" CfgFile)" || return 1
    if [[ -z "$cfg" || "$cfg" != /* ]]; then
        return 1
    fi
    dirname "$cfg"
}
