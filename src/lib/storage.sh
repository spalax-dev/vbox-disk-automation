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
# storage.sh: verificacion declarativa, huellas en el host, preparacion y
# retiro de discos, y lectura de la salida clave=valor del script invitado.

# storage_desired_hash <vm>: sha256 del bloque declarado convertido a JSON,
# la referencia contra la que se compara el estado registrado.
storage_desired_hash() {
    yq -o=json ".\"${1}\"" "$VBOXDISK_FILE" | sha256sum | awk '{ print $1 }'
}

# storage_disk_desired_hash <vm> <disco>: sha256 del disco declarado, para
# comparar un disco concreto con su registro en state.lock.
storage_disk_desired_hash() {
    yq -o=json ".\"${1}\".disks.\"${2}\"" "$VBOXDISK_FILE" | sha256sum | awk '{ print $1 }'
}

# storage_disk_file <vm> <disco>: fichero .vdi de un disco declarado. Si el
# archivo no fija 'file', el nombre sale del directorio de la maquina y de la
# clave del disco.
storage_disk_file() {
    local vm="$1" disk="$2" file dir
    file="$(cfg_disk_get "$vm" "$disk" file)"
    if [[ -n "$file" ]]; then
        printf '%s' "$file"
        return 0
    fi
    if dir="$(vbox_vm_dir "$vm")"; then
        printf '%s/%s.vdi' "$dir" "$disk"
        return 0
    fi
    log_error "$vm: no se pudo derivar el fichero del disco '$disk'; declare 'file' o revise la maquina en el hipervisor"
    return 1
}

# storage_fingerprint <vm>: huella fisica de toda la configuracion de
# almacenamiento de la maquina: controladores y MAC reportados por
# showvminfo, mas el fichero y la adjuncion de cada disco declarado (sin
# VMState, para que la huella de una vm apagada coincida con la registrada).
storage_fingerprint() {
    local vm="$1" disk file out
    out="$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        grep -E '^(storagecontroller|macaddress)' || true)"
    while IFS= read -r disk; do
        [[ -n "$disk" ]] || continue
        if file="$(storage_disk_file "$vm" "$disk")"; then
            out+=$'\n'"$(storage_disk_fingerprint "$vm" "$file")"
        else
            out+=$'\n'"$disk sin fichero"
        fi
    done < <(cfg_disk_keys "$vm" "$VBOXDISK_FILE")
    printf '%s' "$out" | sha256sum | awk '{ print $1 }'
}

# storage_disk_fingerprint <vm> <fichero>: huella fisica de un disco: estado
# del fichero en el host, su ruta y la linea de adjuncion en showvminfo.
storage_disk_fingerprint() {
    local vm="$1" disk="$2" disk_part cfg_part
    disk_part="ausente"
    if [[ -f "$disk" ]]; then
        disk_part="$(stat -c '%Y %s' "$disk" 2>/dev/null || printf '?')"
    fi
    cfg_part="$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        grep -F "\"$disk\"" || true)"
    printf '%s\n%s\n%s\n' "$disk_part" "$disk" "$cfg_part" | sha256sum | awk '{ print $1 }'
}

# storage_disk_attached <vm> <fichero>: 0 si showvminfo ya menciona el fichero.
storage_disk_attached() {
    local vm="$1" disk="$2"
    VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        grep -F "\"$disk\"" >/dev/null
}

# storage_attachment <vm> <fichero>: imprime "<controlador> <puerto>" donde
# esta adjunto el fichero; sin adjuncion no imprime nada.
storage_attachment() {
    local vm="$1" disk="$2"
    VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        awk -F'"' -v d="$disk" '
            $2 == d {
                slot = $1
                sub(/=$/, "", slot)
                n = split(slot, a, "-")
                if (n >= 2 && a[2] ~ /^[0-9]+$/) {
                    printf "%s %s", a[1], a[2]
                    exit
                }
            }'
}

# storage_medium_uuid <vm> <fichero>: identificador del medio en el
# hipervisor; 1 si el fichero no figura adjunto.
storage_medium_uuid() {
    local vm="$1" disk="$2" info slot
    if ! info="$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null)"; then
        return 1
    fi
    slot="$(printf '%s\n' "$info" |
        awk -F'"' -v d="$disk" '$2 == d { s = $1; sub(/=$/, "", s); print s; exit }')"
    if [[ -z "$slot" ]]; then
        return 1
    fi
    printf '%s\n' "$info" |
        awk -F'"' -v ctl="${slot%%-*}" -v rest="${slot#*-}" \
            '$1 == ctl "-ImageUUID-" rest "=" { print $2; exit }'
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

# storage_require_space <fichero> <mb>: el ancestro mas profundo existente del
# fichero declarado tiene espacio para el disco que se va a crear. Se comprueba
# antes de createmedium, para no dejar un medio a medias.
storage_require_space() {
    local disk="$1" size_mb="$2" dir avail need
    dir="$(dirname "$disk")"
    while [[ ! -d "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
        dir="$(dirname "$dir")"
    done
    avail="$(df -B1 --output=avail "$dir" 2>/dev/null | awk 'NR == 2 { print $1 }')"
    need=$((size_mb * 1024 * 1024))
    if [[ -z "$avail" ]]; then
        log_warn "no se pudo medir el espacio libre en $dir; se continua sin esa comprobacion"
        return 0
    fi
    if ((avail < need)); then
        log_error "espacio insuficiente en $dir: disponibles $avail bytes y se requieren $need bytes para $disk"
        return 1
    fi
    return 0
}

# storage_ensure_medium <vm> <fichero> <mb>: crea y adjunta el disco declarativo.
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
        if ! confirm "$vm esta encendida; adjuntar $disk exige un ciclo de encendido, detener la maquina y volver a encenderla. Continuar?"; then
            log_warn "$vm: adjuncion del disco cancelada"
            return "$VBOXDISK_E_CANCEL"
        fi
    fi

    if [[ ! -f "$disk" ]]; then
        if ! storage_require_space "$disk" "$size_mb"; then
            return "$VBOXDISK_E_STORAGE"
        fi
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

# storage_ensure_detached <vm> <fichero>: retira el disco del hipervisor sin
# borrarlo. En una maquina encendida se intenta primero el desprendimiento en
# caliente y, si el hipervisor lo rechaza, se apaga y se reintenta.
storage_ensure_detached() {
    local vm="$1" disk="$2" att ctl port state
    if ! storage_disk_attached "$vm" "$disk"; then
        return 0
    fi
    att="$(storage_attachment "$vm" "$disk" || true)"
    if [[ -z "$att" ]]; then
        log_error "$vm: no se localizo el controlador de $disk para desprenderlo"
        return "$VBOXDISK_E_STORAGE"
    fi
    ctl="${att% *}"
    port="${att##* }"
    state="$(vbox_power_state "$vm" || true)"
    if [[ "$state" == "running" || "$state" == "starting" ]]; then
        log_info "$vm: desprendiendo $disk en caliente del controlador $ctl, puerto $port"
        if VBoxManage controlvm "$vm" storageattach "$ctl" --port "$port" --device 0 --medium none \
            >/dev/null 2>&1 && ! storage_disk_attached "$vm" "$disk"; then
            return 0
        fi
        log_warn "$vm: el hipervisor rechazo el desprendimiento en caliente; se detiene la maquina"
        vbox_stop "$vm" || true
    fi
    log_info "$vm: retirando $disk del controlador $ctl, puerto $port"
    if ! VBoxManage storageattach "$vm" --storagectl "$ctl" \
        --port "$port" --device 0 --medium none; then
        log_error "$vm: fallo al desprender $disk de $ctl-$port"
        return "$VBOXDISK_E_STORAGE"
    fi
    if storage_disk_attached "$vm" "$disk"; then
        log_error "$vm: $disk sigue adjunto tras el intento de desprendimiento"
        return "$VBOXDISK_E_STORAGE"
    fi
    return 0
}

# storage_delete_medium <vm> <fichero>: elimina del hipervisor y del host un
# disco de datos ya desprendido. Nunca se toca un medio todavia adjunto ni
# nada que no sea un fichero .vdi de datos, de modo que el disco del sistema
# queda fuera del alcance de la orden.
storage_delete_medium() {
    local vm="$1" disk="$2" cfg
    if [[ "$disk" != *.vdi ]]; then
        log_error "$vm: se niega a eliminar $disk: solo se admiten ficheros .vdi de datos"
        return "$VBOXDISK_E_STORAGE"
    fi
    if storage_disk_attached "$vm" "$disk"; then
        log_error "$vm: se niega a eliminar $disk porque sigue adjunto a la maquina"
        return "$VBOXDISK_E_STORAGE"
    fi
    cfg="$(vbox_info "$vm" CfgFile || true)"
    if [[ -n "$cfg" && "$(readlink -f "$disk" 2>/dev/null || printf '%s' "$disk")" == \
        "$(readlink -f "$cfg" 2>/dev/null || printf '%s' "$cfg")" ]]; then
        log_error "$vm: se niega a eliminar $disk: es el fichero de configuracion de la maquina"
        return "$VBOXDISK_E_STORAGE"
    fi
    if [[ ! -e "$disk" ]]; then
        VBoxManage closemedium disk "$disk" >/dev/null 2>&1 || true
        return 0
    fi
    log_info "$vm: eliminando el disco virtual $disk"
    if ! VBoxManage closemedium disk "$disk" --delete; then
        log_error "$vm: fallo al eliminar el disco virtual $disk"
        return "$VBOXDISK_E_STORAGE"
    fi
    return 0
}

# storage_orphan_disks <vm>: discos registrados en state.lock que el archivo
# declarativo ya no menciona y que siguen pendientes de decision; los que
# quedaron inactivos se consideran resueltos.
storage_orphan_disks() {
    local vm="$1" disk
    while IFS= read -r disk; do
        [[ -n "$disk" ]] || continue
        if cfg_disk_keys "$vm" "$VBOXDISK_FILE" | grep -Fxq "$disk"; then
            continue
        fi
        if [[ "$(state_get_disk "$vm" "$disk" state || true)" == "inactive" ]]; then
            continue
        fi
        printf '%s\n' "$disk"
    done < <(state_disk_keys "$vm")
}

# storage_plan_vm: plan de la verificacion declarativa en el host, sin tocar
# la maquina (usado por --dry-run). Imprime una linea por stdout.
storage_plan_vm() {
    local vm="$1"
    local desired stored fp stored_fp power disk file size fstate
    local plan extra="" orphans=0
    local -a details=()
    desired="$(storage_desired_hash "$vm")"
    stored="$(state_get "$vm" desired_hash || true)"
    fp="$(storage_fingerprint "$vm")"
    stored_fp="$(state_get "$vm" fingerprint || true)"
    power="$(vbox_power_state "$vm" || printf 'desconocido')"

    while IFS= read -r disk; do
        [[ -n "$disk" ]] || continue
        file="$(storage_disk_file "$vm" "$disk" || true)"
        size="$(cfg_disk_size_mb "$vm" "$disk" || true)"
        fstate="$(cfg_disk_state "$vm" "$disk")"
        if [[ "$fstate" == "inactive" ]]; then
            details+=("$disk: se desprendra del hipervisor (disco inactivo)")
        elif [[ -n "$file" ]] && storage_disk_attached "$vm" "$file"; then
            details+=("$disk: ya esta adjunto")
        elif [[ -n "$file" && -f "$file" ]]; then
            details+=("$disk: se adjuntara el disco existente")
        else
            details+=("$disk: se creara y adjuntara el disco de ${size} MB")
        fi
    done < <(cfg_disk_keys "$vm" "$VBOXDISK_FILE")

    while IFS= read -r disk; do
        orphans=$((orphans + 1))
        details+=("$disk: registrado y ausente del archivo declarativo; requiere decision")
    done < <(storage_orphan_disks "$vm")

    if [[ -z "$stored" ]]; then
        plan="primera aplicacion: preparar el almacenamiento declarado"
    elif [[ "$desired" != "$stored" ]]; then
        plan="cambios declarados pendientes respecto del ultimo registro"
    elif [[ "$fp" != "$stored_fp" ]]; then
        plan="huella fisica modificada fuera de la solucion: se verificara en la vm"
    elif [[ "$power" != "poweroff" ]]; then
        plan="vm encendida: sondeo de solo lectura y convergencia"
    elif ((orphans > 0)); then
        plan="discos registrados pendientes de decision"
    else
        plan="sin cambios: la vm coincide con lo declarado y permanece apagada"
    fi
    for disk in "${details[@]}"; do
        if [[ -n "$extra" ]]; then
            extra+="; "
        fi
        extra+="$disk"
    done
    if [[ -n "$extra" ]]; then
        plan+=" ($extra)"
    fi
    printf '%s: %s (estado actual: %s)\n' "$vm" "$plan" "$power"
}

# Campos GUEST_*: estado del invitado que deja storage_parse_guest_output
# (par clave=valor de emit_state); los consumen storage_verify_guest y
# apply_vm. Como una corrida sustituye a la anterior, cada disco guarda ademas
# su propia copia con guest_snapshot.
GUEST_EXIT=""
GUEST_DEVICE=""
GUEST_TABLE=""
GUEST_FSTYPE=""
GUEST_UUID=""
GUEST_MOUNTED=""
GUEST_MOUNTPOINT=""
GUEST_FSTAB=""
GUEST_TABLE_LINES=""

# Copias por disco de los campos GUEST_*, para verificar cada uno en la etapa
# final aunque despues se hayan ejecutado otras corridas invitado.
declare -gA GUEST_S_EXIT=() GUEST_S_DEVICE=() GUEST_S_TABLE=() GUEST_S_FSTYPE=()
declare -gA GUEST_S_UUID=() GUEST_S_MOUNTED=() GUEST_S_MOUNTPOINT=() GUEST_S_FSTAB=()
declare -gA GUEST_S_LINES=()

# guest_snapshot <vm> <disco>: conserva los campos GUEST_* de la ultima
# corrida del disco.
guest_snapshot() {
    local key="$1/$2"
    GUEST_S_EXIT[$key]="$GUEST_EXIT"
    GUEST_S_DEVICE[$key]="$GUEST_DEVICE"
    GUEST_S_TABLE[$key]="$GUEST_TABLE"
    GUEST_S_FSTYPE[$key]="$GUEST_FSTYPE"
    GUEST_S_UUID[$key]="$GUEST_UUID"
    GUEST_S_MOUNTED[$key]="$GUEST_MOUNTED"
    GUEST_S_MOUNTPOINT[$key]="$GUEST_MOUNTPOINT"
    GUEST_S_FSTAB[$key]="$GUEST_FSTAB"
    GUEST_S_LINES[$key]="$GUEST_TABLE_LINES"
}

# guest_restore <vm> <disco>: recarga en GUEST_* la copia del disco.
guest_restore() {
    local key="$1/$2"
    GUEST_EXIT="${GUEST_S_EXIT[$key]:-}"
    GUEST_DEVICE="${GUEST_S_DEVICE[$key]:-}"
    GUEST_TABLE="${GUEST_S_TABLE[$key]:-}"
    GUEST_FSTYPE="${GUEST_S_FSTYPE[$key]:-}"
    GUEST_UUID="${GUEST_S_UUID[$key]:-}"
    GUEST_MOUNTED="${GUEST_S_MOUNTED[$key]:-}"
    GUEST_MOUNTPOINT="${GUEST_S_MOUNTPOINT[$key]:-}"
    GUEST_FSTAB="${GUEST_S_FSTAB[$key]:-}"
    GUEST_TABLE_LINES="${GUEST_S_LINES[$key]:-}"
}

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

# storage_drift <vm> <disco>: 0 si el invitado difiere del ultimo registro
# conocido (modificacion externa). Las claves sin registro previo no generan
# deriva.
storage_drift() {
    local vm="$1" disk="$2"
    local keys=(kv_device kv_table kv_fstype kv_uuid kv_mounted kv_fstab)
    local vals=("$GUEST_DEVICE" "$GUEST_TABLE" "$GUEST_FSTYPE" "$GUEST_UUID" "$GUEST_MOUNTED" "$GUEST_FSTAB")
    local i stored drift=0
    for i in "${!keys[@]}"; do
        stored="$(state_get_disk "$vm" "$disk" "${keys[$i]}" || true)"
        if [[ -z "$stored" ]]; then
            continue
        fi
        if [[ "$stored" != "${vals[$i]}" ]]; then
            log_warn "$vm/$disk: deriva detectada en ${keys[$i]}: registrado='$stored' actual='${vals[$i]}'"
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

# storage_verify_guest <vm> <disco>: orquesta la comprobacion final de la
# convergencia de un disco; en cuanto alguna propiedad esperada no se cumple,
# devuelve el codigo de almacenamiento y detiene la corrida de la vm.
storage_verify_guest() {
    local vm="$1" disk="$2" fs mount who="$1/$2"
    fs="$(cfg_disk_get "$vm" "$disk" fs_type)"
    mount="$(cfg_disk_get "$vm" "$disk" mount_point)"
    storage_require_exit "$who" || return "$VBOXDISK_E_STORAGE"
    storage_require_mounted "$who" "$mount" || return "$VBOXDISK_E_STORAGE"
    storage_require_fstab "$who" "$mount" || return "$VBOXDISK_E_STORAGE"
    storage_require_fstype "$who" "$fs" || return "$VBOXDISK_E_STORAGE"
    storage_require_mountpoint "$who" "$mount" || return "$VBOXDISK_E_STORAGE"
    return 0
}
