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
# storage.sh: verificacion declarativa, huellas en el host y lectura de la
# salida clave=valor del script invitado.

# storage_desired_hash <vm>: sha256 del bloque declarado convertido a JSON,
# la referencia contra la que se compara el estado registrado.
storage_desired_hash() {
    yq -o=json ".\"${1}\"" "$VBOXDISK_FILE" | sha256sum | awk '{ print $1 }'
}

# storage_fingerprint <vm> <disco>: huella fisica = fichero .vdi + configuracion
# de almacenamiento y MAC reportada por showvminfo (sin VMState, para que la
# huella de una vm apagada coincida con la registrada).
storage_fingerprint() {
    local vm="$1" disk="$2" disk_part cfg_part
    disk_part="ausente"
    if [[ -f "$disk" ]]; then
        disk_part="$(stat -c '%Y %s' "$disk" 2>/dev/null || printf '?')"
    fi
    cfg_part="$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        grep -E '^(storagecontroller|SATA-|IDE-|SCSI-|NVMe-|USB-|macaddress)' || true)"
    printf '%s\n%s\n%s\n' "$disk_part" "$disk" "$cfg_part" | sha256sum | awk '{ print $1 }'
}

# storage_disk_attached <vm> <disco>: 0 si showvminfo ya menciona el fichero.
storage_disk_attached() {
    local vm="$1" disk="$2"
    VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        grep -F "\"$disk\"" >/dev/null
}

# storage_pick_port <vm>: imprime "<controlador> <puerto>" libres; no controlador
# disponible retorna 3.
storage_pick_port() {
    local vm="$1" info ctl port count key
    info="$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null)" || return "$VBOXDISK_E_STORAGE"
    ctl="$(printf '%s\n' "$info" |
        awk -F'"' '/^storagecontrollername[0-9]+=/{ n = toupper($2) } n != "IDE" && /^storagecontrollername[0-9]+=/ { print $2; exit }')"
    if [[ -z "$ctl" ]]; then
        ctl="$(printf '%s\n' "$info" |
            awk -F'"' '/^storagecontrollername[0-9]+=/{ print $2; exit }')"
    fi
    if [[ -z "$ctl" ]]; then
        log_error "$vm no tiene controladores de almacenamiento declarados"
        return "$VBOXDISK_E_STORAGE"
    fi
    count="$(printf '%s\n' "$info" | awk -F'"' -v c="$ctl" '$1 == c "-portcount=" { print $2; exit }')"
    if [[ -z "$count" ]]; then
        count=30
    fi
    for ((port = 0; port < count; port++)); do
        key="$ctl-$port-0"
        if ! printf '%s\n' "$info" | awk -F'"' -v k="$key" '$1 == k "=" { f = 1 } END { exit f ? 0 : 1 }'; then
            printf '%s %s' "$ctl" "$port"
            return 0
        fi
    done
    log_error "$vm no tiene puertos libres en el controlador $ctl"
    return "$VBOXDISK_E_STORAGE"
}

# storage_ensure_medium <vm> <disco> <mb>: crea y adjunta el disco declarativo.
# Si la vm esta encendida exige confirmacion, porque implica un ciclo de
# encendido. Retorna 0, 3 (almacenamiento) o 4 (cancelado).
storage_ensure_medium() {
    local vm="$1" disk="$2" size_mb="$3"
    local was_running=0 pick ctl port state

    if storage_disk_attached "$vm" "$disk"; then
        log_info "$vm: el disco declarado ya esta adjunto ($disk)"
        return 0
    fi

    state="$(vbox_power_state "$vm" || true)"
    if [[ "$state" == "running" || "$state" == "starting" ]]; then
        was_running=1
        if ! confirm "$vm esta encendida y necesita un ciclo de encendido para adjuntar el disco $disk. Continuar?"; then
            log_warn "$vm: adjuncion del disco cancelada"
            return "$VBOXDISK_E_CANCEL"
        fi
    fi

    if [[ ! -f "$disk" ]]; then
        mkdir -p "$(dirname "$disk")"
        log_info "$vm: creando el disco virtual $disk (${size_mb} MB, formato VDI)"
        if ! VBoxManage createmedium disk --filename "$disk" --size "$size_mb" --format VDI; then
            log_error "$vm: fallo al crear el disco virtual $disk"
            return "$VBOXDISK_E_STORAGE"
        fi
    fi

    if ((was_running == 1)); then
        log_info "$vm: deteniendo la maquina para adjuntar el disco"
        if ! vbox_stop "$vm"; then
            log_error "$vm: no se pudo detener para adjuntar el disco"
            return "$VBOXDISK_E_COMM"
        fi
    fi

    pick="$(storage_pick_port "$vm")" || return "$?"
    ctl="${pick% *}"
    port="${pick##* }"
    log_info "$vm: adjuntando $disk en el controlador $ctl, puerto $port"
    if ! VBoxManage storageattach "$vm" --storagectl "$ctl" \
        --port "$port" --device 0 --type hdd --medium "$disk"; then
        log_error "$vm: fallo al adjuntar $disk en $ctl-$port"
        return "$VBOXDISK_E_STORAGE"
    fi
    return 0
}

# storage_plan_vm: plan de la verificacion declarativa en el host, sin tocar
# la maquina (usado por --dry-run). Imprime una linea por stdout.
storage_plan_vm() {
    local vm="$1"
    local disk size desired stored fp stored_fp power extra="" plan
    disk="$(cfg_get "$vm" disk_file)"
    size="$(cfg_get "$vm" disk_size_mb)"
    desired="$(storage_desired_hash "$vm")"
    stored="$(state_get "$vm" desired_hash || true)"
    fp="$(storage_fingerprint "$vm" "$disk")"
    stored_fp="$(state_get "$vm" fingerprint || true)"
    power="$(vbox_power_state "$vm" || printf 'desconocido')"

    if ! storage_disk_attached "$vm" "$disk" && [[ ! -f "$disk" ]]; then
        extra="; se creara y adjuntara el disco de ${size} MB"
    elif ! storage_disk_attached "$vm" "$disk"; then
        extra="; se adjuntara el disco existente"
    fi

    if [[ -z "$stored" ]]; then
        plan="primera aplicacion: preparar el almacenamiento declarado$extra"
    elif [[ "$desired" != "$stored" ]]; then
        plan="cambios declarados pendientes respecto del ultimo registro$extra"
    elif [[ "$fp" != "$stored_fp" ]]; then
        plan="huella fisica modificada fuera de la solucion: se verificara en la vm$extra"
    elif [[ "$power" != "poweroff" ]]; then
        plan="vm encendida: sondeo de solo lectura y convergencia$extra"
    else
        plan="sin cambios: la vm coincide con lo declarado y permanece apagada"
    fi
    printf '%s: %s (estado actual: %s)\n' "$vm" "$plan" "$power"
}

# Campos GUEST_*: estado del invitado que deja storage_parse_guest_output
# (par clave=valor de emit_state); los consumen storage_verify_guest y
# apply_vm.
GUEST_EXIT=""
GUEST_DEVICE=""
GUEST_TABLE=""
GUEST_FSTYPE=""
GUEST_UUID=""
GUEST_MOUNTED=""
GUEST_MOUNTPOINT=""
GUEST_FSTAB=""
GUEST_TABLE_LINES=""

# storage_parse_guest_output <texto>: extrae los pares clave=valor y la tabla.
storage_parse_guest_output() {
    local out="$1" line
    GUEST_EXIT=""
    GUEST_DEVICE=""
    GUEST_TABLE=""
    GUEST_FSTYPE=""
    GUEST_UUID=""
    GUEST_MOUNTED=""
    GUEST_MOUNTPOINT=""
    GUEST_FSTAB=""
    GUEST_TABLE_LINES=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            VBOXDISK_EXIT=*) GUEST_EXIT="${line#VBOXDISK_EXIT=}" ;;
            DEVICE=*) GUEST_DEVICE="${line#DEVICE=}" ;;
            TABLE=*) GUEST_TABLE="${line#TABLE=}" ;;
            FSTYPE=*) GUEST_FSTYPE="${line#FSTYPE=}" ;;
            UUID=*) GUEST_UUID="${line#UUID=}" ;;
            MOUNTED=*) GUEST_MOUNTED="${line#MOUNTED=}" ;;
            MOUNTPOINT=*) GUEST_MOUNTPOINT="${line#MOUNTPOINT=}" ;;
            FSTAB=*) GUEST_FSTAB="${line#FSTAB=}" ;;
            TABLE_LINE=*)
                if [[ -n "$GUEST_TABLE_LINES" ]]; then
                    GUEST_TABLE_LINES+=$'\n'
                fi
                GUEST_TABLE_LINES+="${line#TABLE_LINE=}"
                ;;
        esac
    done <<<"$out"
}

# storage_drift <vm>: 0 si el invitado difiere del ultimo registro conocido
# (modificacion externa). Las claves sin registro previo no generan deriva.
storage_drift() {
    local vm="$1"
    local keys=(kv_device kv_table kv_fstype kv_uuid kv_mounted kv_fstab)
    local vals=("$GUEST_DEVICE" "$GUEST_TABLE" "$GUEST_FSTYPE" "$GUEST_UUID" "$GUEST_MOUNTED" "$GUEST_FSTAB")
    local i stored drift=0
    for i in "${!keys[@]}"; do
        stored="$(state_get "$vm" "${keys[$i]}" || true)"
        if [[ -z "$stored" ]]; then
            continue
        fi
        if [[ "$stored" != "${vals[$i]}" ]]; then
            log_warn "$vm: deriva detectada en ${keys[$i]}: registrado='$stored' actual='${vals[$i]}'"
            drift=1
        fi
    done
    return "$drift"
}

# storage_require_* <vm> [...]: cada comprobacion final de la convergencia.
# Devuelven 1 y registran el motivo cuando el invitado no coincide con lo
# declarado; storage_verify_guest traduce cualquier fallo al codigo 3.

# storage_require_exit <vm>: el script invitado termino con exito.
storage_require_exit() {
    if [[ "$GUEST_EXIT" != "0" ]]; then
        log_error "$1: el script invitado termino con codigo ${GUEST_EXIT:-desconocido}"
        return 1
    fi
    return 0
}

# storage_require_mounted <vm> <montaje>: el punto de montaje quedo montado.
storage_require_mounted() {
    if [[ "$GUEST_MOUNTED" != "yes" ]]; then
        log_error "$1: el punto de montaje $2 no quedo montado"
        return 1
    fi
    return 0
}

# storage_require_fstab <vm> <montaje>: el montaje quedo declarado en fstab.
storage_require_fstab() {
    if [[ "$GUEST_FSTAB" != "yes" ]]; then
        log_error "$1: $2 no quedo declarado en /etc/fstab"
        return 1
    fi
    return 0
}

# storage_require_fstype <vm> <esperado>: el sistema de archivos instalado
# es el declarado.
storage_require_fstype() {
    if [[ "$GUEST_FSTYPE" != "$2" ]]; then
        log_error "$1: sistema de archivos '$GUEST_FSTYPE' distinto del declarado '$2'"
        return 1
    fi
    return 0
}

# storage_require_mountpoint <vm> <esperado>: el volumen quedo montado en la
# ruta declarada.
storage_require_mountpoint() {
    if [[ "$GUEST_MOUNTPOINT" != "$2" ]]; then
        log_error "$1: montado en '$GUEST_MOUNTPOINT' y no en '$2'"
        return 1
    fi
    return 0
}

# storage_verify_guest <vm>: orquesta la comprobacion final de la
# convergencia; en cuanto alguna propiedad esperada no se cumple, devuelve
# el codigo de almacenamiento y detiene la corrida de la vm.
storage_verify_guest() {
    local vm="$1" fs mount
    fs="$(cfg_get "$vm" fs_type)"
    mount="$(cfg_get "$vm" mount_point)"
    storage_require_exit "$vm" || return "$VBOXDISK_E_STORAGE"
    storage_require_mounted "$vm" "$mount" || return "$VBOXDISK_E_STORAGE"
    storage_require_fstab "$vm" "$mount" || return "$VBOXDISK_E_STORAGE"
    storage_require_fstype "$vm" "$fs" || return "$VBOXDISK_E_STORAGE"
    storage_require_mountpoint "$vm" "$mount" || return "$VBOXDISK_E_STORAGE"
    return 0
}
