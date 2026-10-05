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
# apply.sh: implementacion de la orden apply. Valida el archivo declarativo,
# recorre las vm y aplica a cada una las cinco etapas de convergencia,
# incluida la comunicacion con el invitado. Se carga desde el punto de
# entrada src/vboxdisk.

# cmd_apply: valida la configuracion, aplica --dry-run o recorre las vm una a
# una y agrega al final el codigo de mayor severidad de la corrida.
cmd_apply() {
    validate_config 1
    if ((DRY_RUN == 1)); then
        local vm
        while IFS= read -r vm; do
            storage_plan_vm "$vm"
        done < <(cfg_vms)
        exit "$VBOXDISK_OK"
    fi
    if [[ ! -f "$GUEST_SCRIPT" ]]; then
        die_cfg "no se encontro el script invitado: $GUEST_SCRIPT"
    fi
    state_init_dirs
    state_open_log
    total_start
    local -a codes=()
    local vm rc final
    while IFS= read -r vm; do
        rc=0
        apply_vm "$vm" || rc=$?
        codes+=("$rc")
        if ((rc == VBOXDISK_E_CANCEL)); then
            log_warn "se detiene la corrida por cancelacion del usuario"
            break
        fi
    done < <(cfg_vms)
    final="$(aggregate_code "${codes[@]}")"
    log_info "resumen: tiempo total $(total_seconds)s; codigo de salida $final"
    exit "$final"
}

# guest_dispatch <vm> <converge|probe>: copia el script invitado, lo ejecuta,
# registra su salida en la bitacora y deja los campos GUEST_* analizados.
guest_dispatch() {
    local vm="$1" mode="$2"
    local user pass_raw passfile guest_pass guest_dir vb_rc=0 out line i label device
    local args=()

    user="$(cfg_get "$vm" vm_user)"
    pass_raw="$(cfg_get "$vm" vm_pass)"
    if [[ -n "$pass_raw" ]]; then
        passfile="$(mktemp "${TMPDIR:-/tmp}/vboxdisk.pass.XXXXXX")"
        chmod 600 "$passfile"
        printf '%s\n' "$pass_raw" >"$passfile"
        register_tmp "$passfile"
    else
        passfile="$(cfg_get "$vm" vm_pass_file)"
    fi
    # shellcheck disable=SC2034  # las lee vbox_guest_run en vbox.sh.
    VBOXDISK_GUEST_USER="$user"
    # shellcheck disable=SC2034  # las lee vbox_guest_run en vbox.sh.
    VBOXDISK_GUEST_PASSFILE="$passfile"

    guest_dir=""
    for ((i = 0; i < 5; i++)); do
        guest_dir="$(vbox_guest_mktemp_dir "$vm" 2>/dev/null || true)"
        if [[ -n "$guest_dir" ]]; then
            break
        fi
        sleep 2
    done
    if [[ -z "$guest_dir" ]]; then
        log_error "$vm: Guest Control no acepto sesiones tras los reintentos"
        return "$VBOXDISK_E_COMM"
    fi
    vbox_guest_track_dir "$guest_dir"

    if ! vbox_guest_copy_to "$vm" "$guest_dir" "$GUEST_SCRIPT"; then
        log_error "$vm: no se pudo copiar guest_ensure.sh al invitado"
        return "$VBOXDISK_E_COMM"
    fi
    guest_pass="$guest_dir/$(basename "$passfile")"
    if ! vbox_guest_copy_to "$vm" "$guest_dir" "$passfile"; then
        log_error "$vm: no se pudo copiar el fichero de credenciales al invitado"
        return "$VBOXDISK_E_COMM"
    fi

    args=(--size-mb "$(cfg_get "$vm" disk_size_mb)")
    args+=(--mount "$(cfg_get "$vm" mount_point)")
    args+=(--fstype "$(cfg_get "$vm" fs_type)")
    args+=(--passfile "$guest_pass")
    label="$(cfg_get "$vm" fs_label)"
    device="$(cfg_get "$vm" disk_device)"
    if [[ -n "$label" ]]; then
        args+=(--label "$label")
    fi
    if [[ -n "$device" ]]; then
        args+=(--device "$device")
    fi
    if [[ "$mode" == "probe" ]]; then
        args+=(--probe)
    fi

    out="$(vbox_guest_run "$vm" "$guest_dir" "$VBOXDISK_GUEST_TIMEOUT" \
        "$guest_dir/guest_ensure.sh" "${args[@]}" 2>&1)" || vb_rc=$?
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -n "${VBOXDISK_LOG_FILE:-}" ]]; then
            printf '%s\n' "$line" >>"$VBOXDISK_LOG_FILE"
        fi
        printf '%s\n' "$line" >&2
    done <<<"$out"

    storage_parse_guest_output "$out"
    vbox_guest_rm "$vm" "$guest_dir"
    vbox_guest_untrack_dir "$guest_dir"

    if [[ -z "$GUEST_EXIT" ]]; then
        if ((vb_rc != 0)); then
            log_error "$vm: Guest Control no ejecuto el script invitado (VBoxManage rc=$vb_rc)"
            return "$VBOXDISK_E_COMM"
        fi
        log_error "$vm: la salida del script invitado no contiene la centinela VBOXDISK_EXIT"
        return "$VBOXDISK_E_STORAGE"
    fi
    if [[ "$GUEST_EXIT" != "0" ]]; then
        log_warn "$vm: el script invitado termino con codigo $GUEST_EXIT"
        return "$GUEST_EXIT"
    fi
    return 0
}

# apply_vm <vm>: las cinco etapas de la Subseccion del algoritmo.
apply_vm() {
    local vm="$1"
    # shellcheck disable=SC2034  # la lee vbox_guest_cleanup_all en vbox.sh.
    VBOXDISK_CURRENT_VM="$vm"
    local disk size rc=0 ip ready_t=0 desired stored fp stored_fp power
    local drift

    disk="$(cfg_get "$vm" disk_file)"
    size="$(cfg_get "$vm" disk_size_mb)"
    desired="$(storage_desired_hash "$vm")"
    stored="$(state_get "$vm" desired_hash || true)"
    fp="$(storage_fingerprint "$vm" "$disk")"
    stored_fp="$(state_get "$vm" fingerprint || true)"
    power="$(vbox_power_state "$vm" || true)"

    # Etapa 1: verificacion declarativa y preparacion del host.
    stage_begin 1 "verificacion declarativa de $vm"
    if [[ -n "$stored" && "$stored" == "$desired" && "$fp" == "$stored_fp" && "$power" == "poweroff" ]]; then
        stage_end
        log_info "$vm: sin cambios; la maquina coincide con lo declarado y permanece apagada"
        return 0
    fi
    storage_ensure_medium "$vm" "$disk" "$size" || rc=$?
    stage_end
    if ((rc != 0)); then
        return "$rc"
    fi

    # Etapa 2: encendido y disponibilidad de VBoxService.
    stage_begin 2 "disponibilidad de $vm"
    rc=0
    ready_t="$(now_s)"
    vbox_start "$vm" || rc=$?
    if ((rc == 0)); then
        if ! vbox_wait_ready "$vm" "$VBOXDISK_READY_TIMEOUT"; then
            log_error "$vm: VBoxService no respondio en ${VBOXDISK_READY_TIMEOUT}s"
            rc="$VBOXDISK_E_COMM"
        fi
    fi
    ready_t=$(($(now_s) - ready_t))
    stage_end
    if ((rc != 0)); then
        return "$rc"
    fi
    log_info "$vm: VBoxService respondio; maquina disponible en ${ready_t}s"

    # Etapa 3: identificacion de la direccion IP en tiempo de ejecucion.
    stage_begin 3 "identificacion de la direccion IP de $vm"
    rc=0
    ip="$(vbox_detect_ip "$vm" "$VBOXDISK_IP_TIMEOUT")" || rc=$?
    stage_end
    if ((rc != 0)); then
        log_error "$vm: direccion IP no disponible tras ${VBOXDISK_IP_TIMEOUT}s (propiedad de Guest Additions y respaldo ARP)"
        return "$VBOXDISK_E_COMM"
    fi
    log_info "$vm: direccion IP identificada: $ip"

    # Etapa 4: sondeo de solo lectura y convergencia en el invitado.
    stage_begin 4 "preparacion del almacenamiento en $vm"
    rc=0
    guest_dispatch "$vm" probe || rc=$?
    if ((rc != 0)); then
        stage_end
        log_error "$vm: el sondeo de solo lectura fallo con codigo $rc"
        return "$rc"
    fi
    drift=0
    storage_drift "$vm" || drift=1
    if ((drift == 1)); then
        if ! confirm "$vm: el invitado difiere del ultimo registro de la solucion. Forzar la sincronizacion con lo declarado?"; then
            stage_end
            return "$VBOXDISK_E_CANCEL"
        fi
    fi
    rc=0
    guest_dispatch "$vm" converge || rc=$?
    stage_end
    if ((rc != 0)); then
        log_error "$vm: la convergencia del almacenamiento fallo con codigo $rc"
        return "$rc"
    fi

    # Etapa 5: verificacion final y registro en state.lock.
    stage_begin 5 "verificacion y registro de $vm"
    rc=0
    storage_verify_guest "$vm" || rc=$?
    if ((rc != 0)); then
        stage_end
        return "$rc"
    fi
    fp="$(storage_fingerprint "$vm" "$disk")"
    state_set_vm "$vm" \
        "desired_hash=$desired" \
        "fingerprint=$fp" \
        "ip=$ip" \
        "last_run=$(date '+%Y-%m-%d %H:%M:%S')" \
        "kv_device=$GUEST_DEVICE" \
        "kv_table=$GUEST_TABLE" \
        "kv_fstype=$GUEST_FSTYPE" \
        "kv_uuid=$GUEST_UUID" \
        "kv_mounted=$GUEST_MOUNTED" \
        "kv_fstab=$GUEST_FSTAB" \
        "table_b64=$(state_encode_table "$GUEST_TABLE_LINES")"
    stage_end
    log_info "$vm: convergencia verificada y registrada (disponible en ${ready_t}s)"
    return 0
}
