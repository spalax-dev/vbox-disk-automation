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
# config.sh: lectura, validacion y precedencia de vdisk.yml con yq.
# Precedencia: variables de entorno VBOXDISK_* > bloque en vdisk.yml > defecto.

# Claves admitidas y claves obligatorias de cada bloque de vdisk.yml.
VBOXDISK_KEYS=(vm_user vm_pass vm_pass_file disk_file disk_size_mb disk_device mount_point fs_type fs_label)
VBOXDISK_REQUIRED=(vm_user disk_file disk_size_mb mount_point fs_type)

# cfg_is_reserved <clave>: 0 si la clave pertenece al conjunto reservado.
cfg_is_reserved() {
    local key="$1" k
    for k in "${VBOXDISK_KEYS[@]}"; do
        if [[ "$key" == "$k" ]]; then
            return 0
        fi
    done
    return 1
}

# cfg_vms: nombres de primer nivel del archivo, es decir, las vm declaradas.
cfg_vms() {
    yq -r '. | keys | .[]' "$VBOXDISK_FILE"
}

# cfg_get <vm> <clave>: entorno > yml > cadena vacia.
cfg_get() {
    local vm="$1" key="$2" envkey val
    envkey="VBOXDISK_${key^^}"
    if [[ -n "${!envkey:-}" ]]; then
        printf '%s' "${!envkey}"
        return 0
    fi
    val="$(yq -r ".\"${vm}\".\"${key}\" // \"\"" "$VBOXDISK_FILE")"
    if [[ "$val" == "null" ]]; then
        val=""
    fi
    printf '%s' "$val"
}

# cfg_validate <fichero>: validacion completa antes de tocar el hipervisor.
# 1) existencia, lectura y sintaxis YAML; 2) nombres y claves reservadas;
# 3) obligatorias y credenciales; 4) valores concretos de cada clave.
cfg_validate() {
    local file="$1"
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        log_error "archivo declarativo ausente o ilegible: $file"
        return 1
    fi
    if ! yq eval '.' "$file" >/dev/null 2>&1; then
        log_error "archivo declarativo no es YAML valido: $file"
        return 1
    fi
    local vms
    # Se listan los nombres del fichero recibido, no del global VBOXDISK_FILE,
    # de modo que validate sirve tambien para examinar otro archivo.
    vms="$(yq -r '. | keys | .[]' "$file" 2>/dev/null || true)"
    if [[ -z "$vms" ]]; then
        log_error "no hay ninguna vm declarada en $file"
        return 1
    fi
    local errors=0 vm key val fs size mount dev pass pass_file
    for vm in $vms; do
        if [[ ! "$vm" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
            log_error "nombre de vm invalido en el archivo declarativo: $vm"
            errors=1
            continue
        fi
        while IFS= read -r key; do
            if [[ -z "$key" ]]; then
                continue
            fi
            if ! cfg_is_reserved "$key"; then
                log_error "$vm: clave no reservada '$key' (Tabla de variables reservadas)"
                errors=1
            fi
        done < <(yq -r ".\"${vm}\" | keys | .[]" "$file" 2>/dev/null || true)
        for key in "${VBOXDISK_REQUIRED[@]}"; do
            val="$(yq -r ".\"${vm}\".\"${key}\" // \"\"" "$file")"
            if [[ -z "$val" || "$val" == "null" ]]; then
                log_error "$vm: falta la variable obligatoria '$key'"
                errors=1
            fi
        done
        pass="$(yq -r ".\"${vm}\".vm_pass // \"\"" "$file")"
        pass_file="$(yq -r ".\"${vm}\".vm_pass_file // \"\"" "$file")"
        if [[ -z "$pass" || "$pass" == "null" ]] && [[ -z "$pass_file" || "$pass_file" == "null" ]]; then
            log_error "$vm: se requiere 'vm_pass' o 'vm_pass_file'"
            errors=1
        fi
        if [[ -n "$pass_file" && "$pass_file" != "null" && ! -r "$pass_file" ]]; then
            log_error "$vm: 'vm_pass_file' no se puede leer: $pass_file"
            errors=1
        fi
        fs="$(yq -r ".\"${vm}\".fs_type // \"\"" "$file")"
        if [[ -n "$fs" && "$fs" != "null" && "$fs" != "ext4" && "$fs" != "xfs" ]]; then
            log_error "$vm: 'fs_type' debe ser ext4 o xfs (valor: $fs)"
            errors=1
        fi
        size="$(yq -r ".\"${vm}\".disk_size_mb // \"\"" "$file")"
        if [[ -n "$size" && "$size" != "null" ]]; then
            if [[ ! "$size" =~ ^[0-9]+$ ]] || ((size <= 0)); then
                log_error "$vm: 'disk_size_mb' debe ser un entero positivo (valor: $size)"
                errors=1
            fi
        fi
        mount="$(yq -r ".\"${vm}\".mount_point // \"\"" "$file")"
        if [[ -n "$mount" && "$mount" != "null" && "$mount" != /* ]]; then
            log_error "$vm: 'mount_point' debe ser una ruta absoluta (valor: $mount)"
            errors=1
        fi
        dev="$(yq -r ".\"${vm}\".disk_device // \"\"" "$file")"
        if [[ -n "$dev" && "$dev" != "null" && ! "$dev" =~ ^/dev/[A-Za-z0-9]+$ ]]; then
            log_error "$vm: 'disk_device' invalido (valor: $dev)"
            errors=1
        fi
    done
    if ((errors != 0)); then
        return 1
    fi
    return 0
}

# cfg_each_vm: alias de cfg_vms para recorrer las maquinas declaradas.
cfg_each_vm() {
    cfg_vms
}
