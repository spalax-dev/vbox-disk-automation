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
# queries.sh: ordenes de solo lectura status y ld. Ninguna de las dos
# enciende ni modifica una vm: consultan state.lock, el hipervisor y el
# almacenamiento, y presentan el resultado. Cuando no hay registro previo y
# la vm esta encendida, ld abre ademas una sesion de Guest Control de sola
# lectura para mostrar la tabla real del invitado. Se carga desde el punto
# de entrada src/vboxdisk.

# vm_sync_status <vm>: estado de sincronizacion de la vm contra el
# archivo declarativo, segun la huella registrada en state.lock.
vm_sync_status() {
    local vm="$1" desired stored
    desired="$(storage_desired_hash "$vm")"
    stored="$(state_get "$vm" desired_hash || true)"
    if [[ -z "$stored" ]]; then
        printf 'sin estado'
    elif [[ "$stored" == "$desired" ]]; then
        printf 'sincronizada'
    else
        printf 'desincronizada'
    fi
}

# vm_status_disks <vm>: resumen por disco para la columna DISCOS de status:
# cuantos estan activos, cuantos inactivos, cuantos declarados sin registrar
# y cuantos registrados quedaron pendientes de decision.
vm_status_disks() {
    local vm="$1" disk st
    local active=0 inactive=0 fresh=0 pending=0 parts=""
    while IFS= read -r disk; do
        [[ -n "$disk" ]] || continue
        st="$(state_get_disk "$vm" "$disk" state || true)"
        case "$st" in
            active) active=$((active + 1)) ;;
            inactive) inactive=$((inactive + 1)) ;;
            *) fresh=$((fresh + 1)) ;;
        esac
    done < <(cfg_disk_keys "$vm" "$VBOXDISK_FILE")
    while IFS= read -r disk; do
        [[ -n "$disk" ]] && pending=$((pending + 1))
    done < <(storage_orphan_disks "$vm")

    if ((active > 0)); then
        parts+="$active $(plural "$active" activo), "
    fi
    if ((inactive > 0)); then
        parts+="$inactive $(plural "$inactive" inactivo), "
    fi
    if ((fresh > 0)); then
        parts+="$fresh sin registrar, "
    fi
    if ((pending > 0)); then
        parts+="$pending por resolver, "
    fi
    if [[ -z "$parts" ]]; then
        printf '(sin discos)'
        return 0
    fi
    printf '%s' "${parts%, }"
}

# plural <n> <palabra>: la palabra en plural cuando n no es uno.
plural() {
    if (($1 == 1)); then
        printf '%s' "$2"
    else
        printf '%ss' "$2"
    fi
}

# vm_status_ip <vm>: direccion IP para la tabla de status. Si la vm esta
# encendida se consulta en tiempo de ejecucion; si no, se muestra la
# registrada en state.lock y se advierte que la maquina esta apagada.
vm_status_ip() {
    local vm="$1" power ip
    power="$(vbox_power_state "$vm" || true)"
    if [[ "$power" != "running" ]]; then
        ip="$(state_get "$vm" ip || true)"
        if [[ -z "$ip" ]]; then
            ip="(sin registro)"
        fi
        printf '%s (apagada)' "$ip"
        return 0
    fi
    vbox_detect_ip "$vm" 0 || printf '(no disponible)'
}

# cmd_status: tabla de sincronizacion, discos e IP por vm, de solo lectura.
cmd_status() {
    validate_config 1
    printf '%-12s %-16s %-30s %s\n' "MAQUINA" "ESTADO" "DISCOS" "DIRECCION_IP"
    local vm estado discos ip
    while IFS= read -r vm; do
        estado="$(vm_sync_status "$vm")"
        discos="$(vm_status_disks "$vm")"
        ip="$(vm_status_ip "$vm")"
        printf '%-12s %-16s %-30s %s\n' "$vm" "$estado" "$discos" "$ip"
    done < <(cfg_vms)
}

# cmd_ld <nombre>: ultima corrida registrada y tabla de particiones de cada
# disco con registro en state.lock. Sin registro, consulta la tabla real a
# la vm si esta encendida y, si no lo esta, explica como se genera.
cmd_ld() {
    local name="$1" run disk st table size label mount fstype
    local found=0
    validate_config 0
    if ! cfg_vms | grep -Fxq "$name"; then
        die_cfg "la vm '$name' no esta declarada en $VBOXDISK_FILE"
    fi
    run="$(state_get "$name" last_run || true)"
    if [[ -z "$run" ]]; then
        ld_live "$name"
        return 0
    fi
    say "registro de $name: $run"
    while IFS= read -r disk; do
        [[ -n "$disk" ]] || continue
        found=1
        st="$(state_get_disk "$name" "$disk" state || true)"
        size="$(state_get_disk "$name" "$disk" size_mb || true)"
        label="$(state_get_disk "$name" "$disk" label || true)"
        mount="$(state_get_disk "$name" "$disk" mount_point || true)"
        fstype="$(state_get_disk "$name" "$disk" fs_type || true)"
        say ""
        say "disco $disk (${st:-desconocido}, ${size} MB, $fstype, etiqueta $label, montado en $mount):"
        table="$(state_table_b64 "$name" "$disk" || true)"
        if [[ -z "$table" ]]; then
            say "(sin tabla de particiones registrada)"
        else
            printf '%s\n' "$table"
        fi
    done < <(state_disk_keys "$name")
    if ((found == 0)); then
        say "(sin discos registrados)"
    fi
}

# ld_live <vm>: sin registro previo, lee la tabla real de los discos
# declarados abriendo una sesion de Guest Control contra la vm encendida.
# La consulta es de sola lectura y jamas enciende la maquina: si esta
# apagada, se explica que el registro se genera con apply.
ld_live() {
    local vm="$1" pstate word disk rc size fstype label mount
    local total=0 ok=0
    vbox_require
    pstate="$(vbox_power_state "$vm" || true)"
    if [[ "$pstate" != "running" ]]; then
        case "$pstate" in
            poweroff) word="apagada" ;;
            saved) word="guardada" ;;
            *) word="${pstate:-en estado desconocido}" ;;
        esac
        die_cfg "no hay corrida registrada para $vm y la vm esta $word; ejecute 'vboxdisk apply' para generar el registro"
    fi
    say "registro de $vm: sin corrida registrada; consulta en vivo $(date '+%Y-%m-%d %H:%M:%S')"
    if ! guest_session_open "$vm"; then
        die "$VBOXDISK_E_COMM" "$vm: no se pudo abrir sesion con el invitado para la consulta"
    fi
    # La salida cruda del invitado se retiene en stderr: lo que interesa
    # aqui es la tabla ya formateada, que se muestra por stdout.
    # shellcheck disable=SC2034  # la lee guest_run en apply.sh.
    VBOXDISK_GUEST_QUIET=1
    while IFS= read -r disk; do
        [[ -n "$disk" ]] || continue
        if [[ "$(cfg_disk_state "$vm" "$disk")" == "inactive" ]]; then
            continue
        fi
        size="$(cfg_disk_size_mb "$vm" "$disk" || true)"
        fstype="$(cfg_disk_get "$vm" "$disk" fs_type)"
        label="$(cfg_disk_get "$vm" "$disk" label)"
        mount="$(cfg_disk_get "$vm" "$disk" mount_point)"
        total=$((total + 1))
        guest_disk_args "$vm" "$disk" probe declarado
        rc=0
        guest_run "$vm" "${GUEST_ARGS[@]}" || rc=$?
        say ""
        if ((rc != 0)); then
            say "disco $disk: no identificable en el invitado (codigo $rc)"
            continue
        fi
        ok=$((ok + 1))
        say "disco $disk (declarado, ${size} MB, $fstype, etiqueta $label, montado en $mount):"
        if [[ -n "$GUEST_TABLE_LINES" ]]; then
            printf '%s\n' "$GUEST_TABLE_LINES"
        else
            say "(sin tabla de particiones en el invitado)"
        fi
    done < <(cfg_disk_keys "$vm" "$VBOXDISK_FILE")
    unset VBOXDISK_GUEST_QUIET
    guest_session_close "$vm"
    if ((total > 0 && ok == 0)); then
        die "$VBOXDISK_E_COMM" "$vm: no se pudo consultar ningun disco en la vm"
    fi
    return 0
}
