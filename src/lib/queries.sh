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
# almacenamiento, y presentan el resultado. Se carga desde el punto de
# entrada src/vboxdisk.

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

# cmd_status: tabla de sincronizacion e IP por vm, de solo lectura.
cmd_status() {
    validate_config 1
    printf '%-12s %-16s %s\n' "MAQUINA" "ESTADO" "DIRECCION_IP"
    local vm estado ip
    while IFS= read -r vm; do
        estado="$(vm_sync_status "$vm")"
        ip="$(vm_status_ip "$vm")"
        printf '%-12s %-16s %s\n' "$vm" "$estado" "$ip"
    done < <(cfg_vms)
}

# cmd_ld <nombre>: ultima corrida registrada y tabla de particiones de una vm.
cmd_ld() {
    local name="$1" run table
    validate_config 0
    if ! cfg_vms | grep -Fxq "$name"; then
        die_cfg "la vm '$name' no esta declarada en $VBOXDISK_FILE"
    fi
    run="$(state_get "$name" last_run || true)"
    if [[ -z "$run" ]]; then
        die_cfg "no hay ningun registro en state.lock para $name"
    fi
    say "registro de $name: $run"
    table="$(state_table_b64 "$name" || true)"
    if [[ -z "$table" ]]; then
        say "(sin tabla de particiones registrada)"
    else
        printf '%s\n' "$table"
    fi
}
