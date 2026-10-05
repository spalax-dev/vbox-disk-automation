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

# vbox_require: dependencias de ejecucion en el host.
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

# vbox_vm_exists <vm>: 0 si el nombre figura en VBoxManage list vms.
vbox_vm_exists() {
    local name="$1"
    VBoxManage list vms 2>/dev/null | awk -F'"' -v n="$name" '$2 == n { found = 1 } END { exit found ? 0 : 1 }'
}

# vbox_info <vm> <clave>: valor de showvminfo --machinereadable.
vbox_info() {
    local vm="$1" key="$2"
    VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        awk -F'"' -v k="$key" '$1 == k "=" { print $2; found = 1 } END { exit found ? 0 : 1 }'
}

# vbox_power_state <vm>: estado actual de la maquina (clave VMState).
vbox_power_state() {
    vbox_info "$1" VMState
}

# vbox_start <vm>: enciende en modo headless si hace falta y aguarda running.
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
        sleep 1
    done
    log_error "$vm no alcanzo el estado running tras el arranque"
    return "$VBOXDISK_E_COMM"
}

# vbox_stop: apagado ordenado con ACPI y, si no responde, forzado.
vbox_stop() {
    local vm="$1" t0 state
    VBoxManage controlvm "$vm" acpipowerbutton >/dev/null 2>&1 || true
    t0="$(now_s)"
    while (($(now_s) - t0 < 60)); do
        state="$(vbox_power_state "$vm" || true)"
        if [[ "$state" == "poweroff" || "$state" == "aborted" || "$state" == "saved" ]]; then
            return 0
        fi
        sleep 2
    done
    log_warn "$vm no respondio al apagado ACPI; se fuerza el apagado"
    VBoxManage controlvm "$vm" poweroff >/dev/null 2>&1 || true
    sleep 2
    return 0
}

# vbox_wait_ready <vm> <segundos>: aguarda a que VBoxService publique propiedades.
vbox_wait_ready() {
    local vm="$1" timeout="${2:-120}" t0
    t0="$(now_s)"
    while :; do
        if VBoxManage guestproperty get "$vm" /VirtualBox/GuestAdditions/Version 2>/dev/null |
            grep -q '^Value:'; then
            return 0
        fi
        if (($(now_s) - t0 >= timeout)); then
            return 1
        fi
        sleep 2
    done
}

# vbox_guestproperty_ip <vm>: propiedad Net/0/V4/IP cuando es una IPv4 valida.
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

# vbox_mac <vm>: MAC del adaptador 1 con dos puntos y en minusculas, tal como
# la espera la tabla ARP.
vbox_mac() {
    local raw
    raw="$(vbox_info "$1" macaddress1 || true)"
    if [[ -z "$raw" ]]; then
        return 1
    fi
    printf '%s' "$raw" | sed 's/../&:/g; s/:$//' | tr '[:upper:]' '[:lower:]'
}

# vbox_arp_ip <mac>: respaldo sobre la tabla ARP de la red en puente.
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

# vbox_detect_ip <vm> <segundos>: propiedad de Guest Additions y respaldo ARP,
# reintentando cada dos segundos hasta agotar el tiempo.
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
        sleep 2
    done
}

# vbox_gc <vm> <argumentos...>: sesion guestcontrol con el usuario y el fichero
# de credenciales preparados por guest_dispatch.
vbox_gc() {
    local vm="$1"
    shift
    VBoxManage guestcontrol "$vm" \
        --username "$VBOXDISK_GUEST_USER" \
        --passwordfile "$VBOXDISK_GUEST_PASSFILE" "$@"
}

# vbox_guest_mktemp_dir <vm>: directorio temporal en el invitado; la salida
# "Directory name: <ruta>" se reduce a la ruta absoluta.
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

# vbox_guest_copy_to <vm> <dir> <fichero>: copia al invitado en silencio. El
# destino lleva barra final: sin ella, VBoxManage 7.2 toma --target-directory
# como la ruta del fichero de destino y falla contra un directorio existente
# con el mismo nombre.
vbox_guest_copy_to() {
    local vm="$1" dir="$2" file="$3"
    case "$dir" in
        */) ;;
        *) dir="$dir/" ;;
    esac
    vbox_gc "$vm" copyto --quiet --target-directory="$dir" "$file"
}

# vbox_guest_run <vm> <cwd> <segundos> <script> [args...]:
# el programa es el primer argumento tras --, de modo que bash recibe el script
# como operando y sus argumentos tal cual.
vbox_guest_run() {
    local vm="$1" cwd="$2" secs="$3" script="$4"
    shift 4
    vbox_gc "$vm" run --timeout="$((secs * 1000))" --cwd="$cwd" -- \
        /bin/bash "$script" "$@"
}

# La suborden rm solo acepta ficheros individuales; para el directorio temporal
# completo se despacha /bin/rm -rf con la misma sesion.
vbox_guest_rm() {
    local vm="$1" dir="$2"
    timeout 15 VBoxManage guestcontrol "$vm" \
        --username "$VBOXDISK_GUEST_USER" \
        --passwordfile "$VBOXDISK_GUEST_PASSFILE" \
        run --quiet --timeout=15000 -- /bin/rm -rf "$dir" >/dev/null 2>&1 || true
}

# Directorios temporales del invitado abiertos en esta corrida.
VBOXDISK_GUEST_DIRS=()

# vbox_guest_track_dir <dir>: anade el directorio a los pendientes de limpieza.
vbox_guest_track_dir() {
    VBOXDISK_GUEST_DIRS+=("$1")
}

# vbox_guest_untrack_dir <dir>: retira el directorio ya borrado.
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

# Mejor esfuerzo en la trampa de salida: borra directorios del invitado.
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

# vbox_vm_dir <vm>: directorio de la maquina en el host (la clave CfgFile de
# showvminfo); de ahi salen los discos por defecto cuando el archivo
# declarativo no fija un fichero concreto.
vbox_vm_dir() {
    local cfg
    cfg="$(vbox_info "$1" CfgFile)" || return 1
    if [[ -z "$cfg" || "$cfg" != /* ]]; then
        return 1
    fi
    dirname "$cfg"
}
