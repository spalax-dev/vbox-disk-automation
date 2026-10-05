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
# recorre las vm y aplica a cada una las cinco etapas de convergencia, con una
# corrida del script invitado por disco. Se carga desde el punto de entrada
# src/vboxdisk.

# Sesion abierta con el invitado: directorio temporal y fichero de
# credenciales del host, compartidos por todas las corridas de una vm.
VBOXDISK_SESSION_DIR=""
VBOXDISK_SESSION_PASS=""

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

# guest_session_open <vm>: prepara la sesion con el invitado: credenciales,
# directorio temporal y copia unica del script invitado para todas las
# corridas de la maquina.
guest_session_open() {
    local vm="$1" user pass_raw passfile guest_dir i
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
    VBOXDISK_SESSION_DIR="$guest_dir"
    VBOXDISK_SESSION_PASS="$passfile"
    return 0
}

# guest_session_close <vm>: retira el directorio temporal del invitado.
guest_session_close() {
    if [[ -z "${VBOXDISK_SESSION_DIR:-}" ]]; then
        return 0
    fi
    vbox_guest_rm "$1" "$VBOXDISK_SESSION_DIR"
    vbox_guest_untrack_dir "$VBOXDISK_SESSION_DIR"
    VBOXDISK_SESSION_DIR=""
    return 0
}

# guest_disk_args <vm> <disco> <modo> <origen>: compone los argumentos del
# script invitado en la variable GUEST_ARGS. El origen 'declarado' los lee del
# archivo declarativo y 'estado' de state.lock, que es de donde salen los
# discos registrados y ya ausentes del archivo.
guest_disk_args() {
    local vm="$1" disk="$2" mode="$3" origin="$4"
    local size="" mount="" fstype="" label="" hint
    GUEST_ARGS=()
    hint="$(state_get_disk "$vm" "$disk" kv_device || true)"
    if [[ "$origin" == "estado" ]]; then
        size="$(state_get_disk "$vm" "$disk" size_mb || true)"
        mount="$(state_get_disk "$vm" "$disk" mount_point || true)"
        fstype="$(state_get_disk "$vm" "$disk" fs_type || true)"
        label="$(state_get_disk "$vm" "$disk" label || true)"
    else
        size="$(cfg_disk_size_mb "$vm" "$disk" || true)"
        mount="$(cfg_disk_get "$vm" "$disk" mount_point)"
        fstype="$(cfg_disk_get "$vm" "$disk" fs_type)"
        label="$(cfg_disk_get "$vm" "$disk" label)"
    fi
    GUEST_ARGS=(--mount "$mount" --fstype "$fstype" --label "$label" --size-mb "$size")
    if [[ -n "$hint" ]]; then
        GUEST_ARGS+=(--device "$hint")
    fi
    case "$mode" in
        probe) GUEST_ARGS+=(--probe) ;;
        release) GUEST_ARGS+=(--release) ;;
    esac
    return 0
}

# guest_run <vm> <argumentos...>: una ejecucion del script invitado dentro de
# la sesion abierta. El fichero de credenciales se vuelve a copiar en cada
# corrida, porque el script lo destruye al terminar; la salida queda en la
# bitacora y los campos GUEST_* analizados para el disco que acaba de correr.
guest_run() {
    local vm="$1"
    shift
    local guest_pass vb_rc=0 out line
    local args=("$@")

    guest_pass="$VBOXDISK_SESSION_DIR/$(basename "$VBOXDISK_SESSION_PASS")"
    if ! vbox_guest_copy_to "$vm" "$VBOXDISK_SESSION_DIR" "$VBOXDISK_SESSION_PASS"; then
        log_error "$vm: no se pudo copiar el fichero de credenciales al invitado"
        return "$VBOXDISK_E_COMM"
    fi
    args+=(--passfile "$guest_pass")

    out="$(vbox_guest_run "$vm" "$VBOXDISK_SESSION_DIR" "$VBOXDISK_GUEST_TIMEOUT" \
        "$VBOXDISK_SESSION_DIR/guest_ensure.sh" "${args[@]}" 2>&1)" || vb_rc=$?
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ -n "${VBOXDISK_LOG_FILE:-}" ]]; then
            printf '%s\n' "$line" >>"$VBOXDISK_LOG_FILE"
        fi
        printf '%s\n' "$line" >&2
    done <<<"$out"

    storage_parse_guest_output "$out"

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
    local desired stored fp stored_fp power rc=0 ip ready_t=0
    local disk file size fstate att uuid drift=0
    local -a declared=() orphans=() todo_active=() todo_release=() todo_delete=()
    local -a kv=()

    desired="$(storage_desired_hash "$vm")"
    stored="$(state_get "$vm" desired_hash || true)"
    fp="$(storage_fingerprint "$vm")"
    stored_fp="$(state_get "$vm" fingerprint || true)"
    power="$(vbox_power_state "$vm" || true)"
    while IFS= read -r disk; do
        [[ -n "$disk" ]] && declared+=("$disk")
    done < <(cfg_disk_keys "$vm" "$VBOXDISK_FILE")
    while IFS= read -r disk; do
        [[ -n "$disk" ]] && orphans+=("$disk")
    done < <(storage_orphan_disks "$vm")

    # Etapa 1: verificacion declarativa y preparacion del host.
    stage_begin 1 "verificacion declarativa de $vm"
    if [[ -n "$stored" && "$stored" == "$desired" && "$fp" == "$stored_fp" &&
        "$power" == "poweroff" && ${#orphans[@]} -eq 0 ]]; then
        stage_end
        log_info "$vm: sin cambios; la maquina coincide con lo declarado y permanece apagada"
        return 0
    fi

    # Discos registrados que el archivo ya no declara: la decision del usuario
    # se toma antes de preparar nada, para que el retiro quede ordenado.
    for disk in "${orphans[@]}"; do
        if ! confirm_choice "$vm: el disco '$disk' esta registrado y ya no figura en el archivo declarativo. Que se hace?"; then
            stage_end
            return "$VBOXDISK_E_CANCEL"
        fi
        case "$CHOICE" in
            e)
                todo_release+=("$disk")
                todo_delete+=("$disk")
                ;;
            i)
                todo_release+=("$disk")
                ;;
        esac
    done

    for disk in "${declared[@]}"; do
        fstate="$(cfg_disk_state "$vm" "$disk")"
        if [[ "$fstate" == "inactive" ]]; then
            file="$(storage_disk_file "$vm" "$disk" || true)"
            if [[ "$(state_get_disk "$vm" "$disk" state || true)" == "active" ]] ||
                { [[ -n "$file" ]] && storage_disk_attached "$vm" "$file"; }; then
                todo_release+=("$disk")
            fi
            continue
        fi
        todo_active+=("$disk")
        file="$(storage_disk_file "$vm" "$disk")" || {
            stage_end
            return "$VBOXDISK_E_STORAGE"
        }
        size="$(cfg_disk_size_mb "$vm" "$disk")"
        storage_ensure_medium "$vm" "$file" "$size" || rc=$?
        if ((rc != 0)); then
            stage_end
            return "$rc"
        fi
    done
    stage_end

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

    # Etapa 4: sondeo de solo lectura y convergencia en el invitado, con una
    # corrida del script por disco dentro de la misma sesion.
    stage_begin 4 "preparacion del almacenamiento en $vm"
    rc=0
    guest_session_open "$vm" || rc=$?
    if ((rc != 0)); then
        stage_end
        return "$rc"
    fi

    # Liberaciones: el invitado desmonta y retira la entrada de fstab antes de
    # que el host desprenda el disco del hipervisor.
    for disk in "${todo_release[@]}"; do
        if cfg_disk_keys "$vm" "$VBOXDISK_FILE" | grep -Fxq "$disk"; then
            guest_disk_args "$vm" "$disk" release declarado
        else
            guest_disk_args "$vm" "$disk" release estado
        fi
        rc=0
        guest_run "$vm" "${GUEST_ARGS[@]}" || rc=$?
        guest_snapshot "$vm" "$disk"
        if ((rc != 0)); then
            log_error "$vm/$disk: fallo al liberar el montaje del disco"
            guest_session_close "$vm"
            stage_end
            return "$rc"
        fi
    done

    for disk in "${todo_active[@]}"; do
        guest_disk_args "$vm" "$disk" probe declarado
        rc=0
        guest_run "$vm" "${GUEST_ARGS[@]}" || rc=$?
        if ((rc != 0)); then
            log_error "$vm/$disk: el sondeo de solo lectura fallo con codigo $rc"
            guest_session_close "$vm"
            stage_end
            return "$rc"
        fi
        guest_snapshot "$vm" "$disk"
        storage_drift "$vm" "$disk" || drift=1
    done
    if ((drift == 1)); then
        if ! confirm "$vm: el invitado difiere del ultimo registro de la solucion. Forzar la sincronizacion con lo declarado?"; then
            guest_session_close "$vm"
            stage_end
            return "$VBOXDISK_E_CANCEL"
        fi
    fi

    for disk in "${todo_active[@]}"; do
        guest_disk_args "$vm" "$disk" converge declarado
        rc=0
        guest_run "$vm" "${GUEST_ARGS[@]}" || rc=$?
        guest_snapshot "$vm" "$disk"
        if ((rc != 0)); then
            log_error "$vm/$disk: la convergencia del almacenamiento fallo con codigo $rc"
            guest_session_close "$vm"
            stage_end
            return "$rc"
        fi
    done
    guest_session_close "$vm"
    stage_end

    # Etapa 5: verificacion final, retiro de los discos liberados y registro
    # en state.lock.
    stage_begin 5 "verificacion y registro de $vm"
    for disk in "${todo_active[@]}"; do
        guest_restore "$vm" "$disk"
        rc=0
        storage_verify_guest "$vm" "$disk" || rc=$?
        if ((rc != 0)); then
            stage_end
            return "$rc"
        fi
    done

    for disk in "${todo_release[@]}"; do
        if cfg_disk_keys "$vm" "$VBOXDISK_FILE" | grep -Fxq "$disk"; then
            file="$(storage_disk_file "$vm" "$disk")" || {
                stage_end
                return "$VBOXDISK_E_STORAGE"
            }
        else
            file="$(state_get_disk "$vm" "$disk" file || true)"
        fi
        [[ -n "$file" ]] || {
            stage_end
            log_error "$vm/$disk: no se conoce el fichero del disco para desprenderlo"
            return "$VBOXDISK_E_STORAGE"
        }
        rc=0
        storage_ensure_detached "$vm" "$file" || rc=$?
        if ((rc != 0)); then
            stage_end
            return "$rc"
        fi
        if in_list "$disk" "${todo_delete[@]}"; then
            rc=0
            storage_delete_medium "$vm" "$file" || rc=$?
            if ((rc != 0)); then
                stage_end
                return "$rc"
            fi
        fi
    done

    kv=("desired_hash=$desired" "fingerprint=$fp" "ip=$ip" "last_run=$(date '+%Y-%m-%d %H:%M:%S')")
    for disk in "${todo_active[@]}"; do
        file="$(storage_disk_file "$vm" "$disk")" || {
            stage_end
            return "$VBOXDISK_E_STORAGE"
        }
        size="$(cfg_disk_size_mb "$vm" "$disk")"
        att="$(storage_attachment "$vm" "$file" || true)"
        uuid="$(storage_medium_uuid "$vm" "$file" || true)"
        guest_restore "$vm" "$disk"
        kv+=(
            "disks.$disk.state=active"
            "disks.$disk.desired_hash=$(storage_disk_desired_hash "$vm" "$disk")"
            "disks.$disk.fingerprint=$(storage_disk_fingerprint "$vm" "$file")"
            "disks.$disk.file=$file"
            "disks.$disk.port=${att##* }"
            "disks.$disk.uuid=$uuid"
            "disks.$disk.size_mb=$size"
            "disks.$disk.label=$(cfg_disk_get "$vm" "$disk" label)"
            "disks.$disk.fs_type=$(cfg_disk_get "$vm" "$disk" fs_type)"
            "disks.$disk.mount_point=$(cfg_disk_get "$vm" "$disk" mount_point)"
            "disks.$disk.kv_device=$GUEST_DEVICE"
            "disks.$disk.kv_table=$GUEST_TABLE"
            "disks.$disk.kv_fstype=$GUEST_FSTYPE"
            "disks.$disk.kv_uuid=$GUEST_UUID"
            "disks.$disk.kv_mounted=$GUEST_MOUNTED"
            "disks.$disk.kv_fstab=$GUEST_FSTAB"
            "disks.$disk.table_b64=$(state_encode_table "$GUEST_TABLE_LINES")"
        )
    done
    for disk in "${declared[@]}"; do
        if [[ "$(cfg_disk_state "$vm" "$disk")" != "inactive" ]]; then
            continue
        fi
        file="$(storage_disk_file "$vm" "$disk" || true)"
        kv+=("disks.$disk.state=inactive")
        if [[ -n "$file" ]]; then
            kv+=("disks.$disk.file=$file")
        fi
        kv+=(
            "disks.$disk.size_mb=$(cfg_disk_size_mb "$vm" "$disk" || true)"
            "disks.$disk.label=$(cfg_disk_get "$vm" "$disk" label)"
            "disks.$disk.fs_type=$(cfg_disk_get "$vm" "$disk" fs_type)"
            "disks.$disk.mount_point=$(cfg_disk_get "$vm" "$disk" mount_point)"
        )
    done
    for disk in "${todo_release[@]}"; do
        if in_list "$disk" "${todo_delete[@]}"; then
            continue
        fi
        if ! in_list "$disk" "${declared[@]}"; then
            kv+=("disks.$disk.state=inactive")
        fi
    done
    state_update_vm "$vm" "${kv[@]}"
    for disk in "${todo_delete[@]}"; do
        state_remove_disk "$vm" "$disk"
    done
    stage_end
    log_info "$vm: convergencia verificada y registrada (disponible en ${ready_t}s)"
    return 0
}
