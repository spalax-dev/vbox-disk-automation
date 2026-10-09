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

# Credenciales pedidas en la corrida para una vm que el archivo declarativo ya
# no declara: state.lock no guarda secretos y el bloque de la vm desaparecio,
# de modo que solo existen en memoria y solo hasta que la sesion se abre.
VBOXDISK_CRED_USER=""
VBOXDISK_CRED_PASS=""
VBOXDISK_CRED_PASSFILE=""

# @description Ejecuta la orden apply: valida la configuracion, aplica
# --dry-run o recorre las vm una a una y agrega al final el codigo de mayor
# severidad de la corrida. Nunca retorna: siempre termina con exit.
# @noargs
# @stdout En modo --dry-run, una linea por vm con su plan de cambios.
# @stderr Registros de progreso (log_info/log_warn/log_error) y confirmaciones.
# @exitcode 0 Corrida sin incidencias o plan de --dry-run mostrado.
# @exitcode 1 Configuracion invalida o script invitado ausente (die_cfg).
# @exitcode 2 VBOXDISK_E_COMM: fallo de comunicacion con alguna vm.
# @exitcode 3 VBOXDISK_E_STORAGE: fallo de almacenamiento o verificacion.
# @exitcode 4 VBOXDISK_E_CANCEL: cancelado por el usuario.
# @see apply_vm()
cmd_apply() {
    validate_config 1
    local -A in_file=()
    local -a declared_vms=() vms=()
    local vm
    while IFS= read -r vm; do
        in_file["$vm"]=1
        declared_vms+=("$vm")
    done < <(cfg_vms)
    # Las vm registradas que el archivo ya no declara vienen primero: su
    # decision se toma antes de preparar cualquier otra maquina.
    while IFS= read -r vm; do
        [[ -n "${in_file[$vm]+x}" ]] || vms+=("$vm")
    done < <(state_vms)
    for vm in "${declared_vms[@]}"; do
        vms+=("$vm")
    done
    if ((DRY_RUN == 1)); then
        for vm in "${vms[@]}"; do
            storage_plan_vm "$vm"
        done
        exit "$VBOXDISK_OK"
    fi
    if [[ ! -f "$GUEST_SCRIPT" ]]; then
        die_cfg "no se encontro el script invitado: $GUEST_SCRIPT"
    fi
    state_init_dirs
    state_open_log
    total_start
    local -a codes=()
    local rc final
    for vm in "${vms[@]}"; do
        rc=0
        apply_vm "$vm" || rc=$?
        codes+=("$rc")
        if ((rc == VBOXDISK_E_CANCEL)); then
            log_warn "se detiene la corrida por cancelacion del usuario"
            break
        fi
    done
    final="$(aggregate_code "${codes[@]}")"
    log_info "resumen: tiempo total $(total_seconds)s; codigo de salida $final"
    exit "$final"
}

# @description Prepara la sesion con el invitado: credenciales, directorio
# temporal y copia unica del script invitado para todas las corridas de la
# maquina. Deja ademas la vm en VBOXDISK_CURRENT_VM, que es de donde
# vbox_guest_cleanup_all toma el destino de la limpieza si la corrida termina
# sin cerrar la sesion. Las credenciales pedidas a la terminal por
# guest_credentials_ask mandan sobre las del archivo, porque solo existen
# cuando ese archivo ya no declara la maquina.
# @arg $1 string Nombre de la vm.
# @set VBOXDISK_CURRENT_VM string Vm en curso, para vbox_guest_cleanup_all.
# @set VBOXDISK_GUEST_USER string Usuario del invitado, para vbox_guest_run.
# @set VBOXDISK_GUEST_PASSFILE string Fichero de credenciales, para vbox_guest_run.
# @set VBOXDISK_SESSION_DIR string Directorio temporal creado en el invitado.
# @set VBOXDISK_SESSION_PASS string Fichero de credenciales en el host.
# @stderr Errores si faltan las credenciales, Guest Control no acepta sesiones o la copia falla.
# @exitcode 0 Sesion preparada.
# @exitcode 2 VBOXDISK_E_COMM: sin credenciales, sin sesion del invitado o copia fallida.
# @see guest_credentials_ask()
guest_session_open() {
    local vm="$1" user pass_raw passfile guest_dir i
    # shellcheck disable=SC2034  # la lee vbox_guest_cleanup_all en vbox.sh.
    VBOXDISK_CURRENT_VM="$vm"
    if [[ -n "${VBOXDISK_CRED_USER:-}" ]]; then
        user="$VBOXDISK_CRED_USER"
        pass_raw="$VBOXDISK_CRED_PASS"
        passfile="$VBOXDISK_CRED_PASSFILE"
    else
        user="$(cfg_get "$vm" vm_user)"
        pass_raw="$(cfg_get "$vm" vm_pass)"
        passfile=""
    fi
    if [[ -n "$pass_raw" ]]; then
        passfile="$(mktemp "${TMPDIR:-/tmp}/vboxdisk.pass.XXXXXX")"
        chmod 600 "$passfile"
        printf '%s\n' "$pass_raw" >"$passfile"
        register_tmp "$passfile"
    elif [[ -z "$passfile" ]]; then
        passfile="$(cfg_get "$vm" vm_pass_file)"
    fi
    # Sin credencial no se reintentan sesiones que no van a abrirse: el motivo
    # se dice aqui, en vez del aviso generico de la etapa.
    if [[ -z "$user" || -z "$passfile" ]]; then
        log_error "$vm: no hay credenciales para abrir la sesion con el invitado"
        log_info "$vm: declare la maquina en $VBOXDISK_FILE o exporte VBOXDISK_VM_USER y VBOXDISK_VM_PASS"
        return "$VBOXDISK_E_COMM"
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

# @description Retira el directorio temporal del invitado; sin sesion abierta
# no hace nada.
# @arg $1 string Nombre de la vm.
# @set VBOXDISK_SESSION_DIR string Se vacia al cerrar la sesion.
# @exitcode 0 Siempre.
guest_session_close() {
    if [[ -z "${VBOXDISK_SESSION_DIR:-}" ]]; then
        return 0
    fi
    vbox_guest_rm "$1" "$VBOXDISK_SESSION_DIR"
    vbox_guest_untrack_dir "$VBOXDISK_SESSION_DIR"
    VBOXDISK_SESSION_DIR=""
    return 0
}

# @description Resuelve con que credencial abrir sesion con el invitado de una
# vm que el archivo declarativo ya no declara. state.lock no guarda secretos y
# el bloque de la vm desaparecio del fichero, de modo que, si ni el archivo ni
# el entorno ofrecen ninguna, se piden al usuario con la misma consulta que
# usa la sincronizacion, pero sin escribir el archivo: valen para la corrida en
# curso.
# @arg $1 string Nombre de la vm.
# @set VBOXDISK_CRED_USER string Usuario con el que abrir la sesion; vacio si manda el archivo.
# @set VBOXDISK_CRED_PASS string Contrasena en claro; vacia cuando la credencial es un fichero.
# @set VBOXDISK_CRED_PASSFILE string Ruta del fichero con la contrasena; vacia si se pidio en claro.
# @stderr El prompt de cada dato y los registros de respuestas incompletas.
# @exitcode 0 Credencial resuelta: la del archivo, la del entorno o la pedida al usuario.
# @exitcode 4 Cancelada: sin terminal, lectura interrumpida (VBOXDISK_E_CANCEL).
# @see sync_credentials()
# @see guest_session_open()
guest_credentials_ask() {
    local vm="$1"
    VBOXDISK_CRED_USER=""
    VBOXDISK_CRED_PASS=""
    VBOXDISK_CRED_PASSFILE=""
    if [[ -n "$(cfg_get "$vm" vm_user)" ]] &&
        [[ -n "$(cfg_get "$vm" vm_pass)$(cfg_get "$vm" vm_pass_file)" ]]; then
        return 0
    fi
    sync_credentials "$vm" || return $?
    VBOXDISK_CRED_USER="$SYNC_USER"
    VBOXDISK_CRED_PASS="$SYNC_PASS"
    VBOXDISK_CRED_PASSFILE="$SYNC_PASSFILE"
    return 0
}

# @description Compone los argumentos del script invitado en la variable
# GUEST_ARGS. El origen 'declarado' los lee del archivo declarativo y 'estado'
# de state.lock, que es de donde salen los discos registrados y ya ausentes
# del archivo.
# @arg $1 string Nombre de la vm.
# @arg $2 string Nombre del disco.
# @arg $3 string Modo del script invitado: "probe", "release" o "converge".
# @arg $4 string Origen de los datos: "declarado" o "estado"; no vacio.
# @set GUEST_ARGS array Argumentos para guest_run: --mount, --fstype, --label, --size-mb, --device (si hay pista) y el modo.
# @exitcode 0 Siempre.
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

# @description Una ejecucion del script invitado dentro de la sesion abierta.
# El fichero de credenciales se vuelve a copiar en cada corrida, porque el
# script lo destruye al terminar; la salida queda siempre en la bitacora y los
# campos GUEST_* analizados para el disco que acaba de correr. En pantalla solo
# pasan las notas "guest_ensure: " del propio script: el volcado clave=valor de
# emit_state y la salida de las herramientas (sfdisk, partx, resize2fs) se
# quedan registrados, y se imprimen completos cuando algo fallo, para que el
# motivo se vea sin abrir la bitacora. Con VBOXDISK_GUEST_QUIET no sale nada,
# como antes.
# @arg $1 string Nombre de la vm.
# @arg $@ array Resto de argumentos del script invitado (normalmente GUEST_ARGS); se les agrega --passfile.
# @set GUEST_EXIT string Codigo del script invitado; el resto de campos GUEST_* los rellena storage_parse_guest_output.
# @stderr Las notas guest_ensure de la corrida; con fallo, la salida cruda completa; y siempre los errores o advertencias.
# @exitcode 0 El script invitado termino con la centinela VBOXDISK_EXIT=0.
# @exitcode 1 Codigo propio distinto de 0 devuelto por el script invitado (VBOXDISK_EXIT).
# @exitcode 2 VBOXDISK_E_COMM: no se copio la credencial o VBoxManage no ejecuto el script.
# @exitcode 3 VBOXDISK_E_STORAGE: la salida no contiene la centinela VBOXDISK_EXIT.
# @see storage_parse_guest_output()
# @see guest_emit_raw()
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
        if [[ -z "${VBOXDISK_GUEST_QUIET:-}" && "$line" == "guest_ensure: "* ]]; then
            emit_line "$line"
        fi
    done <<<"$out"

    storage_parse_guest_output "$out"

    if [[ -z "$GUEST_EXIT" ]]; then
        guest_emit_raw "$out"
        if ((vb_rc != 0)); then
            log_error "$vm: Guest Control no ejecuto el script invitado (VBoxManage rc=$vb_rc)"
            return "$VBOXDISK_E_COMM"
        fi
        log_error "$vm: la salida del script invitado no contiene la centinela VBOXDISK_EXIT"
        return "$VBOXDISK_E_STORAGE"
    fi
    if [[ "$GUEST_EXIT" != "0" ]]; then
        # En modo silencioso quien invoca informa disco a disco, de modo que
        # ni la salida retenida ni la advertencia general se emiten aqui.
        if [[ -z "${VBOXDISK_GUEST_QUIET:-}" ]]; then
            guest_emit_raw "$out"
            log_warn "$vm: el script invitado termino con codigo $GUEST_EXIT"
        fi
        return "$GUEST_EXIT"
    fi
    return 0
}

# @description Pasa al terminal la salida cruda retenida de una corrida del
# invitado, la de emit_state y la de las herramientas, que en una corrida
# correcta solo se queda en la bitacora. Las notas "guest_ensure: " ya
# pasaron al leerla y no se repiten; con la salida retenida no imprime nada.
# @arg $1 string Salida completa de la corrida, multilinea.
# @stderr La salida con salto de linea, sin las notas guest_ensure.
# @exitcode 0 Siempre.
# @see guest_run()
guest_emit_raw() {
    local line
    if [[ -n "${VBOXDISK_GUEST_QUIET:-}" ]]; then
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == "guest_ensure: "* ]] && continue
        emit_line "$line"
    done <<<"$1"
    return 0
}

# @description Corrige en state.lock el tamano registrado de un disco cuando el
# hipervisor reporta otro. El registro describe el medio y no la intencion de la
# ultima corrida: una ampliacion deja de ser cierta en cuanto se produce y una
# falla posterior en la corrida no vuelve a escribirlo, de modo que el tamano
# guardado deja de existir. Ese tamano es ademas el que la sincronizacion
# importa al archivo declarativo, y declarar uno menor que el medio no se puede
# aplicar: VirtualBox rechaza reducir un medio. Se corrige en cuanto se observa
# la capacidad, y no al final de la corrida, para que ninguna falla conserve un
# registro que contradiga al hipervisor.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco.
# @arg $3 path Fichero del medio en el host.
# @stderr log_info cuando el registro cambia; el resto de los casos son mudos.
# @exitcode 0 Siempre: sin lectura posible el registro se conserva como esta.
# @see storage_medium_capacity()
# @see state_update_vm()
record_medium_size() {
    local vm="$1" disk="$2" file="$3"
    local cap stored
    [[ -n "$vm" && -n "$disk" && -n "$file" && -f "$file" ]] || return 0
    cap="$(storage_medium_capacity "$file" || true)"
    [[ "$cap" =~ ^[0-9]+$ ]] || return 0
    stored="$(state_get_disk "$vm" "$disk" size_mb || true)"
    # Solo se corrige un registro existente: inventar la clave de un disco que
    # nunca se registro dejaria una seccion incompleta en state.lock.
    [[ -n "$stored" && "$stored" != "$cap" ]] || return 0
    state_update_vm "$vm" "disks.$disk.size_mb=$cap"
    log_info "$vm/$disk: el medio mide $cap MB y el registro guardaba $stored MB; se corrige el registro"
    return 0
}

# @description Aplica a una vm las cinco etapas de la Subseccion del algoritmo:
# verificacion declarativa, disponibilidad, direccion IP, preparacion del
# almacenamiento en el invitado y verificacion con registro en state.lock.
# Discos registrados ausentes del archivo se resuelven antes de la primera
# etapa con [e]liminar, [i]nactivar, [s]incronizar (el archivo vuelve a
# recoger lo que el estado registra, con las credenciales que se pidan) u
# [o]mitir. Las decisiones que retiran el montaje necesitan entrar en el
# invitado, y como una vm ausente ya no declara credenciales, se piden en la
# misma etapa con guest_credentials_ask.
# @arg $1 string Nombre de la vm.
# @stderr Registro de cada etapa, avisos y preguntas de confirmacion.
# @exitcode 0 Sin cambios o convergencia verificada y registrada.
# @exitcode 1 VBOXDISK_E_CONFIG: validacion fallida en el invitado o sincronizacion invalida.
# @exitcode 2 VBOXDISK_E_COMM: encendido, VBoxService, IP o sesion con el invitado fallidos.
# @exitcode 3 VBOXDISK_E_STORAGE: fallo de almacenamiento o verificacion.
# @exitcode 4 VBOXDISK_E_CANCEL: decision o confirmacion rechazada por el usuario.
# @see guest_session_open()
# @see guest_credentials_ask()
# @see confirm_choice()
# @see cfg_sync_commit()
# @see storage_disk_changes()
apply_vm() {
    local vm="$1"
    local desired stored fp stored_fp power rc=0 ip ready_t=0
    local disk file size fstate att uuid drift=0 declared_vm=1 prompt cambios
    local -a declared=() orphans=() todo_active=() todo_release=() todo_delete=()
    local -a todo_sync=()
    local -a kv=()

    # Las credenciales pedidas son por vm: no se arrastran de la anterior.
    VBOXDISK_CRED_USER=""
    VBOXDISK_CRED_PASS=""
    VBOXDISK_CRED_PASSFILE=""

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
    cfg_vms | grep -Fxq "$vm" || declared_vm=0
    stage_begin 1 "verificacion declarativa de $vm"
    # Sin trabajo pendiente en el host no hay nada que converger: apagada la
    # maquina se despide aqui mismo y encendida se anuncia, porque el sondeo
    # del invitado sigue siendo el que detecta la deriva.
    if ((declared_vm)) &&
        [[ -n "$stored" && "$stored" == "$desired" && "$fp" == "$stored_fp" &&
            ${#orphans[@]} -eq 0 ]] && [[ -z "$(storage_pending_work "$vm")" ]]; then
        if [[ "$power" == "poweroff" ]]; then
            stage_end
            log_info "$vm: sin cambios; la maquina coincide con lo declarado y permanece apagada"
            return 0
        fi
        log_info "$vm: sin cambios; la maquina coincide con lo declarado y la corrida solo verificara el invitado"
    fi

    # Discos registrados que el archivo ya no declara: la decision del usuario
    # se toma antes de preparar nada, para que el retiro quede ordenado. Una
    # vm completa retirada del archivo se resuelve con la misma consulta,
    # disco a disco, y una vez decidida no vuelve a consultarse si no queda
    # ningun disco activo.
    for disk in "${orphans[@]}"; do
        if ((declared_vm)); then
            prompt="$vm: el disco '$disk' esta registrado y ya no figura en el archivo declarativo. Que se hace?"
        else
            prompt="$vm: la maquina ya no figura en el archivo declarativo y su disco '$disk' sigue registrado. Que se hace?"
        fi
        if ! confirm_choice "$prompt"; then
            stage_end "$VBOXDISK_E_CANCEL"
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
            s)
                todo_sync+=("$disk")
                ;;
        esac
    done

    # Discos decididos como sincronizar: el archivo declarativo vuelve a
    # recoger lo que el estado registra. La sincronizacion se resuelve antes
    # que cualquier otra decision de la rama ausente del archivo, porque de lo
    # contrario la salida temprana siguiente la descartaria, y despues de
    # escribirla la maquina ya esta declarada y su plan vuelve a calcularse
    # sobre el archivo nuevo.
    if ((${#todo_sync[@]} > 0)); then
        rc=0
        if ((declared_vm == 0)); then
            sync_credentials "$vm" || rc=$?
            if ((rc == 0)); then
                cfg_sync_vm "$vm" "$SYNC_USER" "$SYNC_PASS" "$SYNC_PASSFILE" || rc=$?
            fi
        fi
        if ((rc == 0)); then
            for disk in "${todo_sync[@]}"; do
                # Antes de declarar: lo que se importa del registro tiene que
                # seguir describiendo al medio, o el archivo quedaria con un
                # tamano que la verificacion rechazaria despues.
                record_medium_size "$vm" "$disk" "$(state_get_disk "$vm" "$disk" file || true)"
                cfg_sync_disk "$vm" "$disk" || {
                    rc=$?
                    break
                }
            done
        fi
        if ((rc != 0)); then
            cfg_sync_discard
            stage_end "$rc"
            return "$rc"
        fi
        cfg_sync_commit || {
            stage_end "$VBOXDISK_E_CONFIG"
            return "$VBOXDISK_E_CONFIG"
        }
        declared_vm=1
        declared=()
        while IFS= read -r disk; do
            [[ -n "$disk" ]] && declared+=("$disk")
        done < <(cfg_disk_keys "$vm" "$VBOXDISK_FILE")
        desired="$(storage_desired_hash "$vm")"
        log_info "$vm: archivo declarativo sincronizado con state.lock (${todo_sync[*]})"
    fi

    # Una vm ausente del archivo sin discos por resolver no se prepara ni se
    # enciende: si su seccion ya no contiene discos activos, se retira del
    # estado para que la siguiente corrida no vuelva a considerarla.
    if ((declared_vm == 0)) && ((${#todo_release[@]} == 0)); then
        stage_end
        if [[ -z "$(storage_orphan_disks "$vm")" ]]; then
            state_remove_vm "$vm"
            log_info "$vm: ausente del archivo declarativo; se retira su seccion de state.lock"
        else
            log_info "$vm: ausente del archivo declarativo; se conservan sus discos registrados"
        fi
        return 0
    fi

    # La vm va a entrar en el invitado para retirar sus montajes y el archivo
    # ya no declara ni su usuario ni su contrasena: se piden ahora, en la misma
    # etapa y antes de preparar nada, para que el resto de la corrida no vuelva
    # a interrumpirse por una sesion que no puede abrirse.
    if ((declared_vm == 0)) && ((${#todo_release[@]} > 0)); then
        rc=0
        guest_credentials_ask "$vm" || rc=$?
        if ((rc != 0)); then
            stage_end "$rc"
            return "$rc"
        fi
    fi

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
            stage_end "$VBOXDISK_E_STORAGE"
            return "$VBOXDISK_E_STORAGE"
        }
        size="$(cfg_disk_size_mb "$vm" "$disk")"
        cambios="$(storage_disk_changes "$vm" "$disk" largo)"
        if [[ -n "$cambios" ]]; then
            log_info "$vm/$disk: declarado difiere del registro: $cambios"
        fi
        # Antes: si el medio cambio por fuera desde la ultima corrida, el
        # registro se corrige aunque la comprobacion siguiente lo rechace.
        record_medium_size "$vm" "$disk" "$file"
        storage_ensure_medium "$vm" "$file" "$size" || rc=$?
        # Despues: esta corrida pudo ampliar el medio, y hasta aqui no lo
        # refleja ningun registro.
        record_medium_size "$vm" "$disk" "$file"
        if ((rc != 0)); then
            stage_end "$rc"
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
    stage_end "$rc"
    if ((rc != 0)); then
        return "$rc"
    fi
    log_info "$vm: VBoxService respondio; maquina disponible en ${ready_t}s"

    # Etapa 3: identificacion de la direccion IP en tiempo de ejecucion.
    stage_begin 3 "identificacion de la direccion IP de $vm"
    rc=0
    ip="$(vbox_detect_ip "$vm" "$VBOXDISK_IP_TIMEOUT")" || rc=$?
    stage_end "$rc"
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
        stage_end "$rc"
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
            stage_end "$rc"
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
            stage_end "$rc"
            return "$rc"
        fi
        guest_snapshot "$vm" "$disk"
        storage_drift "$vm" "$disk" || drift=1
    done
    if ((drift == 1)); then
        if ! confirm "$vm: el invitado difiere del ultimo registro de la solucion. Forzar la sincronizacion con lo declarado?"; then
            guest_session_close "$vm"
            stage_end "$VBOXDISK_E_CANCEL"
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
            stage_end "$rc"
            return "$rc"
        fi
        guest_summary "$vm" "$disk"
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
            stage_end "$rc"
            return "$rc"
        fi
    done

    for disk in "${todo_release[@]}"; do
        if cfg_disk_keys "$vm" "$VBOXDISK_FILE" | grep -Fxq "$disk"; then
            file="$(storage_disk_file "$vm" "$disk")" || {
                stage_end "$VBOXDISK_E_STORAGE"
                return "$VBOXDISK_E_STORAGE"
            }
        else
            file="$(state_get_disk "$vm" "$disk" file || true)"
        fi
        [[ -n "$file" ]] || {
            stage_end "$VBOXDISK_E_STORAGE"
            log_error "$vm/$disk: no se conoce el fichero del disco para desprenderlo"
            return "$VBOXDISK_E_STORAGE"
        }
        rc=0
        storage_ensure_detached "$vm" "$file" || rc=$?
        if ((rc != 0)); then
            stage_end "$rc"
            return "$rc"
        fi
        if in_list "$disk" "${todo_delete[@]}"; then
            rc=0
            storage_delete_medium "$vm" "$file" || rc=$?
            if ((rc != 0)); then
                stage_end "$rc"
                return "$rc"
            fi
        fi
    done

    # La huella se recalcula aqui: las etapas 1 a 4 pueden haber cambiado el
    # almacenamiento (creacion, adjuncion o ampliacion de un medio), y lo que se
    # registra es el estado con el que la maquina queda al terminar.
    fp="$(storage_fingerprint "$vm")"
    kv=("desired_hash=$desired" "fingerprint=$fp" "ip=$ip" "last_run=$(date '+%Y-%m-%d %H:%M:%S')")
    for disk in "${todo_active[@]}"; do
        file="$(storage_disk_file "$vm" "$disk")" || {
            stage_end "$VBOXDISK_E_STORAGE"
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
    # Una vm ausente del archivo cuyos discos quedaron eliminados o
    # inactivados no deja rastro en el estado.
    if ((declared_vm == 0)) && [[ -z "$(storage_orphan_disks "$vm")" ]]; then
        state_remove_vm "$vm"
    fi
    stage_end
    log_info "$vm: convergencia verificada y registrada (disponible en ${ready_t}s)"
    return 0
}
