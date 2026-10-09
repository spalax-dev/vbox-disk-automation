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

# @description sha256 del bloque declarado de la vm convertido a JSON: la
# referencia contra la que se compara el estado registrado en state.lock.
# @arg $1 string Nombre de la vm en el archivo declarativo.
# @stdout sha256 en hexadecimal de 64 caracteres, con salto de linea.
storage_desired_hash() {
    yq -o=json ".\"${1}\"" "$VBOXDISK_FILE" | sha256sum | awk '{ print $1 }'
}

# @description sha256 del bloque de un disco declarado, para comparar ese disco
# concreto con su registro en state.lock.
# @arg $1 string Nombre de la vm en el archivo declarativo.
# @arg $2 string Clave del disco bajo la vm (nombre del nodo en 'disks').
# @stdout sha256 en hexadecimal de 64 caracteres, con salto de linea.
storage_disk_desired_hash() {
    yq -o=json ".\"${1}\".disks.\"${2}\"" "$VBOXDISK_FILE" | sha256sum | awk '{ print $1 }'
}

# @description Fichero .vdi de un disco declarado. Si el archivo no fija 'file',
# el nombre sale del directorio de la maquina y de la clave del disco.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco declarado.
# @stdout Ruta del fichero .vdi, sin salto de linea.
# @stderr log_error si no se pudo derivar el fichero.
# @exitcode 0 Ruta resuelta (propia o derivada de la maquina).
# @exitcode 1 No se pudo resolver la ruta.
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

# @description Huella fisica de toda la configuracion de almacenamiento de la
# maquina: controladores y MAC reportados por showvminfo, mas el fichero y la
# adjuncion de cada disco declarado (sin VMState, para que la huella de una vm
# apagada coincida con la registrada). Un disco sin fichero se aporta como
# "<disco> sin fichero".
# @arg $1 string Nombre de la vm en el hipervisor.
# @stdout sha256 en hexadecimal de 64 caracteres, con salto de linea.
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

# @description Huella fisica de un disco: estado del fichero en el host (mtime y
# tamano), su ruta y la linea de adjuncion en showvminfo.
# @arg $1 string Nombre de la vm en el hipervisor.
# @arg $2 path Ruta del fichero .vdi; si no existe se huella como "ausente".
# @stdout sha256 en hexadecimal de 64 caracteres, con salto de linea.
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

# @description Indica si showvminfo ya menciona el fichero, es decir, si el
# disco esta adjunto a la maquina.
# @arg $1 string Nombre de la vm en el hipervisor.
# @arg $2 path Ruta del fichero .vdi.
# @exitcode 0 El disco figura adjunto.
# @exitcode 1 El disco no figura adjunto o no se pudo consultar la vm.
storage_disk_attached() {
    local vm="$1" disk="$2"
    VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        grep -F "\"$disk\"" >/dev/null
}

# @description Imprime donde esta adjunto el fichero. En el formato legible por
# maquina la linea de adjuncion es "CTL-N-0"="<fichero>": la clave lleva
# comillas, por lo que el fichero es el cuarto campo.
# @arg $1 string Nombre de la vm en el hipervisor.
# @arg $2 path Ruta del fichero .vdi.
# @stdout "<controlador> <puerto>" sin salto de linea; sin adjuncion no imprime nada.
storage_attachment() {
    local vm="$1" disk="$2"
    VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null |
        awk -F'"' -v d="$disk" '
            $4 == d {
                slot = $2
                n = split(slot, a, "-")
                if (n >= 2 && a[2] ~ /^[0-9]+$/) {
                    printf "%s %s", a[1], a[2]
                    exit
                }
            }'
}

# @description Identificador del medio en el hipervisor (ImageUUID del puerto
# donde esta adjunto el fichero).
# @arg $1 string Nombre de la vm en el hipervisor.
# @arg $2 path Ruta del fichero .vdi, que debe figurar adjunto.
# @stdout UUID del medio con salto de linea.
# @exitcode 0 UUID impreso.
# @exitcode 1 El fichero no figura adjunto o no se pudo consultar la vm.
storage_medium_uuid() {
    local vm="$1" disk="$2" info slot
    if ! info="$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null)"; then
        return 1
    fi
    slot="$(printf '%s\n' "$info" |
        awk -F'"' -v d="$disk" \
            '$4 == d && $2 ~ /^[^-]+-[0-9]+-[0-9]+$/ { print $2; exit }')"
    if [[ -z "$slot" ]]; then
        return 1
    fi
    printf '%s\n' "$info" |
        awk -F'"' -v ctl="${slot%%-*}" -v rest="${slot#*-}" \
            '$2 == ctl "-ImageUUID-" rest { print $4; exit }'
}

# @description Indice numerico del controlador en las claves
# storagecontroller<campo><indice> de showvminfo.
# @arg $1 string Salida completa de VBoxManage showvminfo --machinereadable.
# @arg $2 string Nombre del controlador, tal como aparece en storagecontrollername<indice>.
# @stdout El indice (p. ej. "0") con salto de linea; vacio si no figura.
storage_ctl_index() {
    printf '%s\n' "$1" | awk -F'"' -v n="$2" '
        $0 ~ /^storagecontrollername[0-9]+=/ && $2 == n {
            s = $1
            sub(/^storagecontrollername/, "", s)
            sub(/=$/, "", s)
            print s
            exit
        }'
}

# @description Valor de la clave storagecontroller<campo><indice> de showvminfo.
# @arg $1 string Salida completa de VBoxManage showvminfo --machinereadable.
# @arg $2 string Campo de la clave, p. ej. "portcount" o "maxportcount".
# @arg $3 int Indice del controlador, tal como lo devuelve storage_ctl_index().
# @stdout Valor de la clave con salto de linea; vacio si no existe.
storage_ctl_field() {
    printf '%s\n' "$1" | awk -F'"' -v f="$2" -v i="$3" \
        '$1 == "storagecontroller" f i "=" { print $2; exit }'
}

# @description Imprime un puerto libre del controlador preferido de la maquina.
# La pertenencia de un puerto se decide sobre las lineas "CTL-N-0"="medio" de
# showvminfo: la clave va entre comillas, y una linea con valor none marca un
# puerto existente sin medio, que por tanto esta libre. El limite superior es el
# maxportcount del controlador, no el portcount vigente, porque un puerto aun no
# ampliado sigue siendo un destino valido. Prefiere cualquier controlador
# distinto de IDE.
# @arg $1 string Nombre de la vm en el hipervisor.
# @stdout "<controlador> <puerto>" sin salto de linea.
# @stderr log_error si la vm no tiene controladores o no queda ningun puerto libre.
# @exitcode 0 Puerto libre encontrado.
# @exitcode 3 VBOXDISK_E_STORAGE: showvminfo fallo, la vm no tiene controladores o no hay puertos libres.
# @see storage_ctl_index()
# @see storage_ctl_field()
storage_pick_port() {
    local vm="$1" info ctl idx bound port key max
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
    bound=30
    idx="$(storage_ctl_index "$info" "$ctl")"
    if [[ -n "$idx" ]]; then
        max="$(storage_ctl_field "$info" maxportcount "$idx")"
        if [[ "$max" =~ ^[0-9]+$ ]]; then
            bound="$max"
        fi
    fi
    for ((port = 0; port < bound; port++)); do
        key="$ctl-$port-0"
        if ! printf '%s\n' "$info" | awk -F'"' -v k="$key" \
            '$2 == k && $4 != "none" { f = 1 } END { exit f ? 0 : 1 }'; then
            printf '%s %s' "$ctl" "$port"
            return 0
        fi
    done
    log_error "$vm no tiene puertos libres en el controlador $ctl"
    return "$VBOXDISK_E_STORAGE"
}

# @description Amplia el PortCount del controlador cuando el puerto elegido queda
# fuera del rango vigente; el hipervisor rechaza la adjuncion en un puerto
# inexistente. Sin dato legible no se toca nada y la adjuncion decide.
# @arg $1 string Nombre de la vm en el hipervisor.
# @arg $2 string Nombre del controlador.
# @arg $3 int Puerto elegido (base 0) que debe quedar dentro del portcount.
# @stderr log_error si falla la ampliacion, log_info al ampliar y la salida cruda de VBoxManage.
# @exitcode 0 El puerto ya esta en rango, el controlador no es consultable o quedo ampliado.
# @exitcode 3 VBOXDISK_E_STORAGE: no se pudo leer showvminfo ni ampliar el controlador.
storage_ensure_portcount() {
    local vm="$1" ctl="$2" port="$3" info idx count want out
    info="$(VBoxManage showvminfo "$vm" --machinereadable 2>/dev/null)" || return "$VBOXDISK_E_STORAGE"
    idx="$(storage_ctl_index "$info" "$ctl")"
    [[ -n "$idx" ]] || return 0
    count="$(storage_ctl_field "$info" portcount "$idx")"
    [[ "$count" =~ ^[0-9]+$ ]] || return 0
    ((port < count)) && return 0
    want=$((port + 1))
    out="$(VBoxManage storagectl "$vm" --name "$ctl" --portcount "$want" 2>&1)" || {
        log_raw "$out"
        log_error "$vm: no se pudo ampliar el controlador $ctl a $want puertos"
        return "$VBOXDISK_E_STORAGE"
    }
    log_raw "$out"
    log_info "$vm: controlador $ctl ampliado a $want puertos para alojar el puerto $port"
    return 0
}

# @description Comprueba que el ancestro mas profundo existente del fichero
# declarado tiene espacio para el disco que se va a crear. Se comprueba antes de
# createmedium, para no dejar un medio a medias.
# @arg $1 path Ruta declarada del disco .vdi; los directorios inexistentes se remontan al ancestral existente.
# @arg $2 int Tamano del disco en MB (se convierte a bytes: MB * 1024 * 1024).
# @stderr log_warn si no se pudo medir el espacio (se continua sin esa comprobacion); log_error si falta espacio.
# @exitcode 0 Hay espacio suficiente o no se pudo medir.
# @exitcode 1 Espacio insuficiente (codigo propio, no VBOXDISK_E_STORAGE).
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

# @description Capacidad de un medio del hipervisor, en MB, leida de
# showmediuminfo. El fichero no declarativo (una ruta creada a mano en una
# prueba, por ejemplo) no tiene capacidad publicable.
# @arg $1 path Ruta del fichero .vdi.
# @stdout Capacidad en MB, sin salto de linea.
# @stderr La salida cruda de VBoxManage queda descartada.
# @exitcode 0 La capacidad se pudo leer.
# @exitcode 1 El medio no existe o no publico una capacidad numerica.
storage_medium_capacity() {
    local disk="$1" out cap
    out="$(VBoxManage showmediuminfo disk "$disk" 2>/dev/null || true)"
    cap="$(printf '%s\n' "$out" | awk '$1 == "Capacity:" { print $2; exit }')"
    if [[ ! "$cap" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    printf '%s' "$cap"
}

# @description Ajusta la capacidad del medio a la declarada cuando el disco
# fisico quedo mas pequeno. Solo se admite ampliar: VirtualBox rechaza reducir
# un medio y un tamano declarado menor que el actual se toma como error. Si la
# maquina esta encendida se detiene sin preguntar, porque el medio no se puede
# ampliar en caliente (el llamador la vuelve a encender en la etapa siguiente).
# @arg $1 string Nombre de la vm en el hipervisor.
# @arg $2 path Ruta del fichero .vdi.
# @arg $3 int Tamano declarado en MB.
# @stderr log_warn si no se pudo leer la capacidad, log_info al ampliar o detener, log_error al rechazar una reduccion y la salida cruda de VBoxManage.
# @exitcode 0 El medio ya tiene el tamano declarado, se amplio o no se pudo leer.
# @exitcode 2 VBOXDISK_E_COMM: no se pudo detener la maquina.
# @exitcode 3 VBOXDISK_E_STORAGE: tamano declarado menor que el actual o fallo al ampliar.
# @see storage_medium_capacity()
# @see vbox_stop()
storage_ensure_size() {
    local vm="$1" disk="$2" declared="$3"
    local cap state out rc
    if [[ ! -f "$disk" ]]; then
        return 0
    fi
    if [[ ! "$declared" =~ ^[0-9]+$ ]] || ((declared <= 0)); then
        log_warn "$vm/$disk: tamano declarado ilegible: '$declared'; se omite la comprobacion de capacidad"
        return 0
    fi
    if ! cap="$(storage_medium_capacity "$disk")"; then
        log_warn "$vm/$disk: no se pudo leer la capacidad de $disk; se omite la comprobacion de capacidad"
        return 0
    fi
    if ((declared == cap)); then
        return 0
    fi
    if ((declared < cap)); then
        log_error "$vm/$disk: lo declarado ($declared MB) es menor que el medio actual ($cap MB); VirtualBox no admite reducir un medio"
        return "$VBOXDISK_E_STORAGE"
    fi
    state="$(vbox_power_state "$vm" || true)"
    if [[ "$state" == "running" || "$state" == "starting" ]]; then
        log_info "$vm: deteniendo la maquina para ampliar $disk"
        if ! vbox_stop "$vm"; then
            log_error "$vm: no se pudo detener para ampliar $disk"
            return "$VBOXDISK_E_COMM"
        fi
    fi
    rc=0
    out="$(VBoxManage modifymedium disk "$disk" --resize "$declared" 2>&1)" || rc=$?
    log_raw "$out"
    if ((rc != 0)); then
        log_error "$vm: fallo al ampliar $disk de $cap a $declared MB"
        return "$VBOXDISK_E_STORAGE"
    fi
    log_info "$vm: medio ampliado de $cap a $declared MB: $disk"
    return 0
}

# @description Crea y adjunta el disco declarativo. Si el fichero ya existe solo
# se ajusta a su tamano declarado (si hace falta) y se adjunta; si la vm esta
# encendida exige confirmacion, porque la adjuncion implica detener la maquina
# (el llamador la vuelve a encender despues). Una ampliacion de capacidad no
# exige confirmacion: se detiene la maquina sin preguntar.
# @arg $1 string Nombre de la vm en el hipervisor.
# @arg $2 path Ruta del fichero .vdi a crear y adjuntar.
# @arg $3 int Tamano declarado del disco en MB.
# @stderr log_info, log_warn y log_error, mas la salida cruda de VBoxManage.
# @exitcode 0 El disco ya estaba adjunto o quedo creado, ampliado y adjunto.
# @exitcode 2 VBOXDISK_E_COMM: no se pudo detener la maquina para adjuntar o ampliar.
# @exitcode 3 VBOXDISK_E_STORAGE: sin espacio, sin puerto, reduccion declarada, fallo al crear, al ampliar o al adjuntar.
# @exitcode 4 VBOXDISK_E_CANCEL: el usuario rechazo la confirmacion.
# @see confirm()
# @see storage_ensure_size()
# @see storage_pick_port()
storage_ensure_medium() {
    local vm="$1" disk="$2" size_mb="$3"
    local was_running=0 pick ctl port state out rc

    if [[ -f "$disk" ]]; then
        storage_ensure_size "$vm" "$disk" "$size_mb" || return "$?"
    fi

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
        rc=0
        out="$(VBoxManage createmedium disk --filename "$disk" --size "$size_mb" --format VDI 2>&1)" || rc=$?
        log_raw "$out"
        if ((rc != 0)); then
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
    if ! storage_ensure_portcount "$vm" "$ctl" "$port"; then
        return "$VBOXDISK_E_STORAGE"
    fi
    log_info "$vm: adjuntando $disk en el controlador $ctl, puerto $port"
    rc=0
    out="$(VBoxManage storageattach "$vm" --storagectl "$ctl" \
        --port "$port" --device 0 --type hdd --medium "$disk" 2>&1)" || rc=$?
    log_raw "$out"
    if ((rc != 0)); then
        log_error "$vm: fallo al adjuntar $disk en $ctl-$port"
        return "$VBOXDISK_E_STORAGE"
    fi
    return 0
}

# @description Retira el disco del hipervisor sin borrarlo. En una maquina
# encendida se intenta primero el desprendimiento en caliente y, si el
# hipervisor lo rechaza, se apaga y se reintenta.
# @arg $1 string Nombre de la vm en el hipervisor.
# @arg $2 path Ruta del fichero .vdi a desprender.
# @stderr log_info, log_warn y log_error, mas la salida cruda de VBoxManage.
# @exitcode 0 El disco quedo desprendido (o ya estaba desprendido).
# @exitcode 3 VBOXDISK_E_STORAGE: no se localizo el controlador o el desprendimiento fallo.
storage_ensure_detached() {
    local vm="$1" disk="$2" att ctl port state out rc
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
    rc=0
    out="$(VBoxManage storageattach "$vm" --storagectl "$ctl" \
        --port "$port" --device 0 --medium none 2>&1)" || rc=$?
    log_raw "$out"
    if ((rc != 0)); then
        log_error "$vm: fallo al desprender $disk de $ctl-$port"
        return "$VBOXDISK_E_STORAGE"
    fi
    if storage_disk_attached "$vm" "$disk"; then
        log_error "$vm: $disk sigue adjunto tras el intento de desprendimiento"
        return "$VBOXDISK_E_STORAGE"
    fi
    return 0
}

# @description Elimina del hipervisor y del host un disco de datos ya desprendido.
# Nunca se toca un medio todavia adjunto ni nada que no sea un fichero .vdi de
# datos, de modo que el disco del sistema queda fuera del alcance de la orden.
# Si el fichero ya no existe en el host solo se cierra el medio.
# @arg $1 string Nombre de la vm, para los mensajes de error.
# @arg $2 path Ruta del fichero .vdi; debe terminar en ".vdi".
# @stderr log_info y log_error, mas la salida cruda de VBoxManage.
# @exitcode 0 Medio cerrado y fichero borrado (o el fichero ya no existia).
# @exitcode 3 VBOXDISK_E_STORAGE: fichero no admitido, sigue adjunto, es la configuracion de la vm o fallo al eliminar.
storage_delete_medium() {
    local vm="$1" disk="$2" cfg out rc
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
    rc=0
    out="$(VBoxManage closemedium disk "$disk" --delete 2>&1)" || rc=$?
    log_raw "$out"
    if ((rc != 0)); then
        log_error "$vm: fallo al eliminar el disco virtual $disk"
        return "$VBOXDISK_E_STORAGE"
    fi
    return 0
}

# @description Lista los discos registrados en state.lock que el archivo
# declarativo ya no menciona y que siguen pendientes de decision; los que
# quedaron inactivos se consideran resueltos.
# @arg $1 string Nombre de la vm.
# @stdout Una clave de disco por linea, en orden de registro; nada si no hay huerfanos.
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

# @description Cambios que el archivo declarativo impone sobre el registro del
# mismo disco en state.lock: cada campo declarado que difiere de lo registrado.
# Un disco sin registro previo no tiene cambios que reportar (se crea entero en
# la etapa 1) y el fichero se compara por su ruta efectiva, de modo que una
# declaracion sin 'file' no se confunda con un cambio.
# @arg $1 string Nombre de la vm en el archivo declarativo.
# @arg $2 string Clave del disco bajo la vm.
# @arg $3 string Modo: "largo" (por defecto) con "campo: registrado -> declarado"; "corto" solo con los campos.
# @stdout Los cambios separados por "; ", sin salto de linea; cadena vacia si no hay ninguno.
# @exitcode 0 Siempre.
# @see state_get_disk()
# @see cfg_disk_get()
storage_disk_changes() {
    local vm="$1" disk="$2" modo="${3:-largo}"
    local i out="" s_state decl_file
    local -a campos=(size label fs_type mount_point file state)
    local -a nombres=(tamano etiqueta tipo_ficheros montaje fichero estado)
    local -a viejos nuevos

    s_state="$(state_get_disk "$vm" "$disk" state || true)"
    if [[ -z "$s_state" ]]; then
        return 0
    fi
    decl_file="$(storage_disk_file "$vm" "$disk" || true)"
    viejos=(
        "$(state_get_disk "$vm" "$disk" size_mb || true)"
        "$(state_get_disk "$vm" "$disk" label || true)"
        "$(state_get_disk "$vm" "$disk" fs_type || true)"
        "$(state_get_disk "$vm" "$disk" mount_point || true)"
        "$(state_get_disk "$vm" "$disk" file || true)"
        "$s_state"
    )
    nuevos=(
        "$(cfg_disk_size_mb "$vm" "$disk" || true)"
        "$(cfg_disk_get "$vm" "$disk" label)"
        "$(cfg_disk_get "$vm" "$disk" fs_type)"
        "$(cfg_disk_get "$vm" "$disk" mount_point)"
        "${decl_file:-${viejos[4]}}"
        "$(cfg_disk_state "$vm" "$disk")"
    )
    for i in "${!campos[@]}"; do
        [[ "${viejos[$i]}" == "${nuevos[$i]}" ]] && continue
        if [[ "$modo" == "corto" ]]; then
            out+="${out:+; }${nombres[$i]}"
        elif [[ "${campos[$i]}" == "size" ]]; then
            out+="${out:+; }tamano ${viejos[$i]:-sin declarar} -> ${nuevos[$i]:-sin declarar} MB"
        else
            out+="${out:+; }${nombres[$i]} ${viejos[$i]:-sin declarar} -> ${nuevos[$i]:-sin declarar}"
        fi
    done
    printf '%s' "$out"
}

# @description Plan de la verificacion declarativa en el host, sin tocar la
# maquina (usado por --dry-run). No escribe en state.lock.
# @arg $1 string Nombre de la vm, declarada o no en el archivo declarativo.
# @stdout Una unica linea "<vm>: <plan> (estado actual: <potencia>)"; el plan lleva entre parentesis el detalle de los discos cuando lo hay. En terminal el nombre de la vm va en negrita y el plan pinta verde si no hay nada que hacer y amarillo si anuncia trabajo pendiente; redirigido o sin terminal sale plano.
storage_plan_vm() {
    local vm="$1"
    local desired stored fp stored_fp power disk file size fstate cambios cap
    local plan extra="" orphans=0 declared_vm=1 color=""
    local -a details=()
    cfg_vms | grep -Fxq "$vm" || declared_vm=0
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
        cambios="$(storage_disk_changes "$vm" "$disk" largo)"
        if [[ -n "$cambios" ]]; then
            details+=("$disk: declarado difiere del registro: $cambios")
        fi
        if [[ "$fstate" != "inactive" && -n "$file" && -f "$file" ]] &&
            cap="$(storage_medium_capacity "$file")" &&
            [[ "$size" =~ ^[0-9]+$ ]] && ((size > 0)); then
            if ((size > cap)); then
                details+=("$disk: el medio actual es de $cap MB y lo declarado es de $size MB: se ampliara")
            elif ((size < cap)); then
                details+=("$disk: el medio actual es de $cap MB y lo declarado es de $size MB: no se puede reducir")
            fi
        fi
    done < <(cfg_disk_keys "$vm" "$VBOXDISK_FILE")

    while IFS= read -r disk; do
        orphans=$((orphans + 1))
        if ((declared_vm)); then
            details+=("$disk: registrado y ausente del archivo declarativo; requiere decision")
        else
            details+=("$disk: sigue registrado y requiere decision")
        fi
    done < <(storage_orphan_disks "$vm")

    if ((declared_vm == 0)); then
        if ((orphans > 0)); then
            plan="la vm ya no figura en el archivo declarativo; decision pendiente sobre sus discos registrados"
        else
            plan="la vm ya no figura en el archivo declarativo y no tiene decisiones pendientes"
        fi
    elif [[ -z "$stored" ]]; then
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
    # Verde cuando no hay nada que hacer, amarillo cuando anuncia trabajo
    # pendiente y sin color para lo meramente informativo.
    case "$plan" in
        "sin cambios"*) color=32 ;;
        *pendiente* | *"primera aplicacion"* | *"huella fisica"*) color=33 ;;
    esac
    printf '%s: %s (estado actual: %s)\n' \
        "$(colorize 1 1 "$vm")" "$(colorize 1 "$color" "$plan")" "$power"
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
GUEST_SIZE_MB=""

# Copias por disco de los campos GUEST_*, para verificar cada uno en la etapa
# final aunque despues se hayan ejecutado otras corridas invitado.
declare -gA GUEST_S_EXIT=() GUEST_S_DEVICE=() GUEST_S_TABLE=() GUEST_S_FSTYPE=()
declare -gA GUEST_S_UUID=() GUEST_S_MOUNTED=() GUEST_S_MOUNTPOINT=() GUEST_S_FSTAB=()
declare -gA GUEST_S_LINES=() GUEST_S_SIZE=()

# @description Conserva los campos GUEST_* de la ultima corrida del disco en las
# copias por disco, para verificar cada uno en la etapa final aunque despues se
# hayan ejecutado otras corridas invitado.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco; la copia se guarda bajo la clave "<vm>/<disco>".
# @set GUEST_S_EXIT array Copia de GUEST_EXIT para "<vm>/<disco>".
# @set GUEST_S_DEVICE array Copia de GUEST_DEVICE para "<vm>/<disco>".
# @set GUEST_S_TABLE array Copia de GUEST_TABLE para "<vm>/<disco>".
# @set GUEST_S_FSTYPE array Copia de GUEST_FSTYPE para "<vm>/<disco>".
# @set GUEST_S_UUID array Copia de GUEST_UUID para "<vm>/<disco>".
# @set GUEST_S_MOUNTED array Copia de GUEST_MOUNTED para "<vm>/<disco>".
# @set GUEST_S_MOUNTPOINT array Copia de GUEST_MOUNTPOINT para "<vm>/<disco>".
# @set GUEST_S_FSTAB array Copia de GUEST_FSTAB para "<vm>/<disco>".
# @set GUEST_S_LINES array Copia de GUEST_TABLE_LINES para "<vm>/<disco>".
# @set GUEST_S_SIZE array Copia de GUEST_SIZE_MB para "<vm>/<disco>".
# @see guest_restore()
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
    GUEST_S_SIZE[$key]="$GUEST_SIZE_MB"
}

# @description Recarga en GUEST_* la copia conservada del disco; sin copia previa
# los campos quedan vacios.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco; la copia se lee de la clave "<vm>/<disco>".
# @set GUEST_EXIT string Restaurada desde GUEST_S_EXIT.
# @set GUEST_DEVICE string Restaurada desde GUEST_S_DEVICE.
# @set GUEST_TABLE string Restaurada desde GUEST_S_TABLE.
# @set GUEST_FSTYPE string Restaurada desde GUEST_S_FSTYPE.
# @set GUEST_UUID string Restaurada desde GUEST_S_UUID.
# @set GUEST_MOUNTED string Restaurada desde GUEST_S_MOUNTED.
# @set GUEST_MOUNTPOINT string Restaurada desde GUEST_S_MOUNTPOINT.
# @set GUEST_FSTAB string Restaurada desde GUEST_S_FSTAB.
# @set GUEST_TABLE_LINES string Restaurada desde GUEST_S_LINES.
# @set GUEST_SIZE_MB string Restaurada desde GUEST_S_SIZE.
# @see guest_snapshot()
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
    GUEST_SIZE_MB="${GUEST_S_SIZE[$key]:-}"
}

# @description Extrae los pares clave=valor y la tabla de la salida del script
# invitado (emit_state) y los deja en los globales GUEST_*. Cada corrida
# sustituye a la anterior: los campos ausentes quedan vacios.
# @arg $1 string Salida completa del script invitado, multilinea.
# @set GUEST_EXIT string Valor de VBOXDISK_EXIT (codigo de salida del invitado).
# @set GUEST_DEVICE string Valor de DEVICE.
# @set GUEST_TABLE string Valor de TABLE.
# @set GUEST_FSTYPE string Valor de FSTYPE.
# @set GUEST_UUID string Valor de UUID.
# @set GUEST_MOUNTED string Valor de MOUNTED ("yes" cuando quedo montado).
# @set GUEST_MOUNTPOINT string Valor de MOUNTPOINT.
# @set GUEST_FSTAB string Valor de FSTAB ("yes" cuando quedo en fstab).
# @set GUEST_TABLE_LINES string Todas las TABLE_LINE concatenadas con saltos de linea.
# @set GUEST_SIZE_MB string Valor de SIZE_MB (tamano del dispositivo en el invitado).
# @set GUEST_NOTE string Ultima nota "guest_ensure: " emitida por el invitado.
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
    GUEST_SIZE_MB=""
    GUEST_NOTE=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            VBOXDISK_EXIT=*) GUEST_EXIT="${line#VBOXDISK_EXIT=}" ;;
            DEVICE=*) GUEST_DEVICE="${line#DEVICE=}" ;;
            SIZE_MB=*) GUEST_SIZE_MB="${line#SIZE_MB=}" ;;
            TABLE=*) GUEST_TABLE="${line#TABLE=}" ;;
            FSTYPE=*) GUEST_FSTYPE="${line#FSTYPE=}" ;;
            UUID=*) GUEST_UUID="${line#UUID=}" ;;
            MOUNTED=*) GUEST_MOUNTED="${line#MOUNTED=}" ;;
            MOUNTPOINT=*) GUEST_MOUNTPOINT="${line#MOUNTPOINT=}" ;;
            FSTAB=*) GUEST_FSTAB="${line#FSTAB=}" ;;
            guest_ensure:*) GUEST_NOTE="${line#guest_ensure: }" ;;
            TABLE_LINE=*)
                if [[ -n "$GUEST_TABLE_LINES" ]]; then
                    GUEST_TABLE_LINES+=$'\n'
                fi
                GUEST_TABLE_LINES+="${line#TABLE_LINE=}"
                ;;
        esac
    done <<<"$out"
}

# @description Detecta modificacion externa: compara los campos actuales de
# GUEST_* con el ultimo registro conocido en state.lock (kv_device, kv_table,
# kv_fstype, kv_uuid, kv_mounted, kv_fstab). Las claves sin registro previo no
# generan deriva.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco.
# @stderr log_warn por cada clave con deriva, con el valor registrado y el actual.
# @exitcode 0 Sin deriva: todo coincide o no hay registro previo.
# @exitcode 1 Al menos una clave difiere del registro.
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

# @description Comprueba que el script invitado termino con exito.
# @arg $1 string Identificador "<vm>/<disco>" que encabeza el mensaje de error.
# @stderr log_error si el invitado no termino con 0.
# @exitcode 0 GUEST_EXIT vale 0.
# @exitcode 1 El invitado fallo o su codigo no quedo registrado.
storage_require_exit() {
    if [[ "$GUEST_EXIT" != "0" ]]; then
        log_error "$1: el script invitado termino con codigo ${GUEST_EXIT:-desconocido}"
        return 1
    fi
    return 0
}

# @description Comprueba que el punto de montaje quedo montado en el invitado.
# @arg $1 string Identificador "<vm>/<disco>" que encabeza el mensaje de error.
# @arg $2 path Punto de montaje declarado, citado en el mensaje de error.
# @stderr log_error si no quedo montado.
# @exitcode 0 GUEST_MOUNTED vale "yes".
# @exitcode 1 GUEST_MOUNTED es distinto de "yes".
storage_require_mounted() {
    if [[ "$GUEST_MOUNTED" != "yes" ]]; then
        log_error "$1: el punto de montaje $2 no quedo montado"
        return 1
    fi
    return 0
}

# @description Comprueba que el montaje quedo declarado en /etc/fstab.
# @arg $1 string Identificador "<vm>/<disco>" que encabeza el mensaje de error.
# @arg $2 path Entrada declarada en fstab, citada en el mensaje de error.
# @stderr log_error si no quedo declarado.
# @exitcode 0 GUEST_FSTAB vale "yes".
# @exitcode 1 GUEST_FSTAB es distinto de "yes".
storage_require_fstab() {
    if [[ "$GUEST_FSTAB" != "yes" ]]; then
        log_error "$1: $2 no quedo declarado en /etc/fstab"
        return 1
    fi
    return 0
}

# @description Comprueba que el sistema de archivos instalado es el declarado.
# @arg $1 string Identificador "<vm>/<disco>" que encabeza el mensaje de error.
# @arg $2 string Tipo de filesystem declarado (p. ej. ext4).
# @stderr log_error si el tipo instalado difiere del declarado.
# @exitcode 0 GUEST_FSTYPE coincide con lo declarado.
# @exitcode 1 GUEST_FSTYPE difiere de lo declarado.
storage_require_fstype() {
    if [[ "$GUEST_FSTYPE" != "$2" ]]; then
        log_error "$1: sistema de archivos '$GUEST_FSTYPE' distinto del declarado '$2'"
        return 1
    fi
    return 0
}

# @description Comprueba que el volumen quedo montado en la ruta declarada.
# @arg $1 string Identificador "<vm>/<disco>" que encabeza el mensaje de error.
# @arg $2 path Ruta de montaje declarada.
# @stderr log_error si el volumen quedo montado en otra ruta.
# @exitcode 0 GUEST_MOUNTPOINT coincide con lo declarado.
# @exitcode 1 GUEST_MOUNTPOINT difiere de lo declarado.
storage_require_mountpoint() {
    if [[ "$GUEST_MOUNTPOINT" != "$2" ]]; then
        log_error "$1: montado en '$GUEST_MOUNTPOINT' y no en '$2'"
        return 1
    fi
    return 0
}

# @description Comprueba que el tamano del disco visible en el invitado es el
# declarado, con una tolerancia de 1 MB para el redondeo de la unidad.
# @arg $1 string Identificador "<vm>/<disco>" que encabeza el mensaje de error.
# @arg $2 int Tamano declarado en MB.
# @stderr log_error si el invitado no informo el tamano o si difiere mas de 1 MB.
# @exitcode 0 GUEST_SIZE_MB coincide con lo declarado.
# @exitcode 1 GUEST_SIZE_MB difiere de lo declarado o no se pudo leer.
storage_require_size() {
    local who="$1" want="$2" diff
    if [[ ! "$GUEST_SIZE_MB" =~ ^[0-9]+$ ]]; then
        log_error "$who: el invitado no informo el tamano del disco"
        return 1
    fi
    if [[ ! "$want" =~ ^[0-9]+$ ]] || ((want <= 0)); then
        return 0
    fi
    diff=$((GUEST_SIZE_MB - want))
    if ((diff < 0)); then
        diff=$((-diff))
    fi
    if ((diff > 1)); then
        log_error "$who: el invitado ve $GUEST_SIZE_MB MB y lo declarado es $want MB"
        return 1
    fi
    return 0
}

# @description Orquesta la comprobacion final de la convergencia de un disco;
# en cuanto alguna propiedad esperada no se cumple, devuelve el codigo de
# almacenamiento y detiene la corrida de la vm. Traduce cualquier fallo de las
# comprobaciones al codigo 3.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco; lee fs_type, mount_point y size del archivo declarativo.
# @stderr Mensajes de log_error de la comprobacion que falle.
# @exitcode 0 Todas las propiedades del invitado coinciden con lo declarado.
# @exitcode 3 VBOXDISK_E_STORAGE: alguna propiedad no coincide.
# @see storage_require_exit()
# @see storage_require_mounted()
# @see storage_require_fstab()
# @see storage_require_fstype()
# @see storage_require_mountpoint()
# @see storage_require_size()
storage_verify_guest() {
    local vm="$1" disk="$2" fs mount size who="$1/$2"
    fs="$(cfg_disk_get "$vm" "$disk" fs_type)"
    mount="$(cfg_disk_get "$vm" "$disk" mount_point)"
    size="$(cfg_disk_size_mb "$vm" "$disk" || true)"
    storage_require_exit "$who" || return "$VBOXDISK_E_STORAGE"
    storage_require_size "$who" "$size" || return "$VBOXDISK_E_STORAGE"
    storage_require_mounted "$who" "$mount" || return "$VBOXDISK_E_STORAGE"
    storage_require_fstab "$who" "$mount" || return "$VBOXDISK_E_STORAGE"
    storage_require_fstype "$who" "$fs" || return "$VBOXDISK_E_STORAGE"
    storage_require_mountpoint "$who" "$mount" || return "$VBOXDISK_E_STORAGE"
    return 0
}
