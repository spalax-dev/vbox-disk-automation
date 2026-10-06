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
# El archivo declara una maquina por bloque y, dentro de cada una, la lista
# de discos de datos bajo la clave 'disks'; el esquema plano anterior
# (disk_file, disk_size_mb, disk_device, mount_point, fs_type, fs_label) se
# rechaza con una indicacion explicita de migracion.

# Claves admitidas y obligatorias de cada bloque de vdisk.yml.
VBOXDISK_KEYS=(vm_user vm_pass vm_pass_file disks)
VBOXDISK_REQUIRED=(vm_user disks)
# Claves admitidas y obligatorias de cada disco del bloque 'disks'.
VBOXDISK_DISK_KEYS=(label size fs_type mount_point file state)
VBOXDISK_DISK_REQUIRED=(label size fs_type mount_point)
# Claves del esquema anterior, todavia presentes en archivos antiguos.
VBOXDISK_LEGACY_KEYS=(disk_file disk_size_mb disk_device mount_point fs_type fs_label)

# @description Indica si una clave pertenece al conjunto reservado de vdisk.yml.
# @arg $1 string Clave a comprobar.
# @exitcode 0 La clave está reservada.
# @exitcode 1 La clave no está reservada.
cfg_is_reserved() {
    local key="$1" k
    for k in "${VBOXDISK_KEYS[@]}"; do
        if [[ "$key" == "$k" ]]; then
            return 0
        fi
    done
    return 1
}

# @description Indica si una clave pertenece al esquema anterior de discos planos.
# @arg $1 string Clave a comprobar.
# @exitcode 0 La clave es del esquema antiguo (disk_file, disk_size_mb, ...).
# @exitcode 1 La clave no pertenece al esquema antiguo.
cfg_is_legacy() {
    local key="$1" k
    for k in "${VBOXDISK_LEGACY_KEYS[@]}"; do
        if [[ "$key" == "$k" ]]; then
            return 0
        fi
    done
    return 1
}

# @description Indica si una clave pertenece al conjunto admitido de un disco.
# @arg $1 string Clave a comprobar.
# @exitcode 0 La clave es válida dentro del bloque 'disks'.
# @exitcode 1 La clave no es válida dentro del bloque 'disks'.
cfg_is_disk_key() {
    local key="$1" k
    for k in "${VBOXDISK_DISK_KEYS[@]}"; do
        if [[ "$key" == "$k" ]]; then
            return 0
        fi
    done
    return 1
}

# @description Enumera las claves de primer nivel de $VBOXDISK_FILE, es decir,
# las vm declaradas en el fichero.
# @noargs
# @stdout Un nombre de vm por línea.
# @see cfg_each_vm()
cfg_vms() {
    yq -r '. | keys | .[]' "$VBOXDISK_FILE"
}

# @description Lee una clave de una vm con la precedencia entorno VBOXDISK_* > yml > cadena vacía.
# La variable de entorno se forma en mayúsculas (vm_user -> VBOXDISK_VM_USER);
# si está definida pero vacía, manda el valor del yml.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave a leer (p. ej. vm_user, vm_pass_file).
# @stdout El valor resuelto, sin salto de línea; cadena vacía si no está definida en ninguna parte.
# @exitcode 0 Siempre.
# @example
#   cfg_get web vm_user  # imprime VBOXDISK_VM_USER o el valor de vdisk.yml
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

# @description Enumera las claves (nombres) de los discos que declara una vm.
# Los errores de yq se silencian: un bloque ausente produce salida vacía.
# @arg $1 string Nombre de la vm.
# @arg $2 path Fichero YAML del que leer (no usa $VBOXDISK_FILE).
# @stdout Un nombre de disco por línea; cadena vacía si no hay discos.
# @exitcode 0 Siempre.
cfg_disk_keys() {
    yq -r ".\"${1}\".disks // {} | keys | .[]" "$2" 2>/dev/null || true
}

# @description Lee una clave de un disco concreto de una vm.
# No aplica precedencia de variables de entorno, porque la precedencia rige
# solo a nivel de máquina.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco dentro de 'disks'.
# @arg $3 string Clave a leer (label, size, fs_type, mount_point, file, state).
# @arg $4 path Fichero YAML; por defecto $VBOXDISK_FILE. El cuarto argumento permite leer un fichero distinto del declarado, que es lo que hace la validación al examinar otro archivo.
# @stdout El valor o cadena vacía si la clave no existe.
# @exitcode 0 Siempre.
cfg_disk_get() {
    local vm="$1" disk="$2" key="$3" file="${4:-$VBOXDISK_FILE}" val
    val="$(yq -r ".\"${vm}\".disks.\"${disk}\".\"${key}\" // \"\"" "$file")"
    if [[ "$val" == "null" ]]; then
        val=""
    fi
    printf '%s' "$val"
}

# @description Tamaño de un disco convertido a megabytes.
# Admite un entero (megabytes) o una cifra con sufijo m|g|t.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco.
# @stdout Tamaño entero en MB, sin unidad ni salto de línea.
# @exitcode 0 El tamaño se pudo interpretar.
# @exitcode 1 La declaración no es un tamaño legible; no se imprime nada.
# @see size_to_mb()
cfg_disk_size_mb() {
    local raw mb
    raw="$(cfg_disk_get "$1" "$2" size)"
    mb="$(size_to_mb "$raw")" || return 1
    printf '%s' "$mb"
}

# @description Estado deseado de un disco; 'active' si la clave no está declarada.
# @arg $1 string Nombre de la vm.
# @arg $2 string Clave del disco.
# @stdout 'active' o el valor declarado en 'state'.
# @exitcode 0 Siempre.
cfg_disk_state() {
    local st
    st="$(cfg_disk_get "$1" "$2" state)"
    printf '%s' "${st:-active}"
}

# @description Comprueba existencia, lectura y sintaxis YAML de un fichero declarativo.
# Ninguna de estas comprobaciones toca el hipervisor; se detiene en el primer error.
# @arg $1 path Fichero YAML a examinar.
# @stderr Un log_error por el problema detectado.
# @exitcode 0 El fichero existe, es legible, es YAML válido y declara alguna vm.
# @exitcode 1 Alguna comprobación falló.
cfg_validate_file() {
    local file="$1"
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        log_error "archivo declarativo ausente o ilegible: $file"
        return 1
    fi
    if ! yq eval '.' "$file" >/dev/null 2>&1; then
        log_error "archivo declarativo no es YAML valido: $file"
        return 1
    fi
    # Se listan los nombres del fichero recibido, no del global VBOXDISK_FILE,
    # de modo que validate sirva tambien para examinar otro archivo.
    local vms
    vms="$(yq -r '. | keys | .[]' "$file" 2>/dev/null || true)"
    if [[ -z "$vms" ]]; then
        log_error "no hay ninguna vm declarada en $file"
        return 1
    fi
    return 0
}

# @description Comprueba la forma admitida de un nombre de vm:
# ^[A-Za-z_][A-Za-z0-9_-]*$ (letra o guion bajo al inicio; después letras,
# dígitos, '_' o '-').
# @arg $1 string Nombre de la vm a validar.
# @stderr log_error si el nombre no es válido.
# @exitcode 0 Nombre válido.
# @exitcode 1 Nombre inválido.
cfg_validate_name() {
    local vm="$1"
    if [[ ! "$vm" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
        log_error "nombre de vm invalido en el archivo declarativo: $vm"
        return 1
    fi
    return 0
}

# @description Valida que todas las claves del bloque de la vm sean reservadas
# y no pertenezcan al esquema anterior de discos planos.
# Acumula todos los errores del bloque, sin detenerse en el primero.
# @arg $1 string Nombre de la vm.
# @arg $2 path Fichero YAML del que leer.
# @stderr Un log_error por cada clave antigua o no reservada.
# @exitcode 0 Todas las claves del bloque son válidas.
# @exitcode 1 Hay alguna clave rechazada.
cfg_validate_keys() {
    local vm="$1" file="$2" key rc=0
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        if cfg_is_legacy "$key"; then
            log_error "$vm: '$key' pertenece al esquema anterior; declare los discos bajo la clave 'disks' (vdisk.yml.example)"
            rc=1
        elif ! cfg_is_reserved "$key"; then
            log_error "$vm: clave no reservada '$key' (Tabla de variables reservadas)"
            rc=1
        fi
    done < <(yq -r ".\"${vm}\" | keys | .[]" "$file" 2>/dev/null || true)
    return "$rc"
}

# @description Valida que las claves obligatorias estén presentes y que 'disks'
# sea un mapa con al menos un disco declarado.
# Acumula todos los errores del bloque, sin detenerse en el primero.
# @arg $1 string Nombre de la vm.
# @arg $2 path Fichero YAML del que leer.
# @stderr log_error por cada obligatoria ausente y por 'disks' mal formado.
# @exitcode 0 El bloque cumple lo obligatorio.
# @exitcode 1 Falta alguna clave obligatoria o 'disks' no es un mapa con discos.
cfg_validate_required() {
    local vm="$1" file="$2" key val type rc=0
    for key in "${VBOXDISK_REQUIRED[@]}"; do
        val="$(yq -r ".\"${vm}\".\"${key}\" // \"\"" "$file")"
        if [[ -z "$val" || "$val" == "null" ]]; then
            log_error "$vm: falta la variable obligatoria '$key'"
            rc=1
        fi
    done
    type="$(yq -r ".\"${vm}\".disks | type" "$file" 2>/dev/null || printf 'null')"
    case "$type" in
        "!!map")
            if [[ -z "$(cfg_disk_keys "$vm" "$file")" ]]; then
                log_error "$vm: 'disks' no declara ningun disco"
                rc=1
            fi
            ;;
        "!!null")
            # Ya reportada arriba como clave obligatoria ausente.
            ;;
        *)
            log_error "$vm: 'disks' debe ser un mapa de discos (no una lista ni un valor simple)"
            rc=1
            ;;
    esac
    return "$rc"
}

# @description Valida que exista una credencial declarada y legible: bien en
# claro con 'vm_pass' o en fichero con 'vm_pass_file'.
# Acumula ambos errores si los hay.
# @arg $1 string Nombre de la vm.
# @arg $2 path Fichero YAML del que leer.
# @stderr log_error si falta la credencial y/o si 'vm_pass_file' es ilegible.
# @exitcode 0 Hay una credencial declarada y legible.
# @exitcode 1 No hay credencial o 'vm_pass_file' no se puede leer.
cfg_validate_credentials() {
    local vm="$1" file="$2" pass pass_file rc=0
    pass="$(yq -r ".\"${vm}\".vm_pass // \"\"" "$file")"
    pass_file="$(yq -r ".\"${vm}\".vm_pass_file // \"\"" "$file")"
    if [[ -z "$pass" || "$pass" == "null" ]] && [[ -z "$pass_file" || "$pass_file" == "null" ]]; then
        log_error "$vm: se requiere 'vm_pass' o 'vm_pass_file'"
        rc=1
    fi
    if [[ -n "$pass_file" && "$pass_file" != "null" && ! -r "$pass_file" ]]; then
        log_error "$vm: 'vm_pass_file' no se puede leer: $pass_file"
        rc=1
    fi
    return "$rc"
}

# @description Valida la forma de cada disco declarado por la vm y la unicidad
# de etiqueta y de punto de montaje dentro de la máquina.
# Revisa nombre de clave, claves admitidas, obligatorias, label (máx. 12
# caracteres en xfs, 16 en ext4), size legible, fs_type (ext4|xfs),
# mount_point absoluto distinto de '/', file absoluto y state
# (active|inactive). Los discos 'inactive' no participan en la unicidad de
# montaje. Acumula los errores y sigue con el disco siguiente; si a un disco
# le falta una clave obligatoria se omiten el resto de sus comprobaciones.
# @arg $1 string Nombre de la vm.
# @arg $2 path Fichero YAML del que leer.
# @stderr Un log_error por cada defecto detectado.
# @exitcode 0 Todos los discos de la vm son válidos.
# @exitcode 1 Algún disco tiene defectos.
cfg_validate_disks() {
    local vm="$1" file="$2" disk dkey rc=0
    local label size fs mount fstate path
    local -A labels=() mounts=()
    while IFS= read -r disk; do
        [[ -n "$disk" ]] || continue
        if [[ ! "$disk" =~ ^[A-Za-z0-9._-]+$ ]] || ((${#disk} > 32)); then
            log_error "$vm: clave de disco invalida '$disk' (admitidos [A-Za-z0-9._-] y hasta 32 caracteres)"
            rc=1
            continue
        fi
        while IFS= read -r dkey; do
            [[ -n "$dkey" ]] || continue
            if ! cfg_is_disk_key "$dkey"; then
                log_error "$vm/$disk: clave no reservada '$dkey' (Tabla de variables de disco)"
                rc=1
            fi
        done < <(yq -r ".\"${vm}\".disks.\"${disk}\" | keys | .[]" "$file" 2>/dev/null || true)
        label="$(cfg_disk_get "$vm" "$disk" label "$file")"
        size="$(cfg_disk_get "$vm" "$disk" size "$file")"
        fs="$(cfg_disk_get "$vm" "$disk" fs_type "$file")"
        mount="$(cfg_disk_get "$vm" "$disk" mount_point "$file")"
        fstate="$(cfg_disk_get "$vm" "$disk" state "$file")"
        path="$(cfg_disk_get "$vm" "$disk" file "$file")"

        local key missing=""
        for key in "${VBOXDISK_DISK_REQUIRED[@]}"; do
            if [[ -z "$(cfg_disk_get "$vm" "$disk" "$key" "$file")" ]]; then
                missing="$key"
                break
            fi
        done
        if [[ -n "$missing" ]]; then
            log_error "$vm/$disk: falta la clave obligatoria '$missing'"
            rc=1
            continue
        fi
        if [[ ! "$label" =~ ^[A-Za-z0-9._-]+$ ]]; then
            log_error "$vm/$disk: 'label' solo admite [A-Za-z0-9._-] (valor: $label)"
            rc=1
        elif [[ "$fs" == "xfs" && ${#label} -gt 12 ]]; then
            log_error "$vm/$disk: 'label' no puede exceder 12 caracteres en xfs (valor: $label)"
            rc=1
        elif [[ "$fs" == "ext4" && ${#label} -gt 16 ]]; then
            log_error "$vm/$disk: 'label' no puede exceder 16 caracteres en ext4 (valor: $label)"
            rc=1
        fi
        if ! size_to_mb "$size" >/dev/null; then
            log_error "$vm/$disk: 'size' debe ser un entero de megabytes o una cifra con sufijo m|g|t (valor: $size)"
            rc=1
        fi
        if [[ "$fs" != "ext4" && "$fs" != "xfs" ]]; then
            log_error "$vm/$disk: 'fs_type' debe ser ext4 o xfs (valor: $fs)"
            rc=1
        fi
        if [[ "$mount" != /* || "$mount" == "/" ]]; then
            log_error "$vm/$disk: 'mount_point' debe ser una ruta absoluta distinta de '/' (valor: $mount)"
            rc=1
        fi
        if [[ -n "$path" && "$path" != /* ]]; then
            log_error "$vm/$disk: 'file' debe ser una ruta absoluta (valor: $path)"
            rc=1
        fi
        if [[ -n "$fstate" && "$fstate" != "active" && "$fstate" != "inactive" ]]; then
            log_error "$vm/$disk: 'state' debe ser active o inactive (valor: $fstate)"
            rc=1
        fi
        if [[ -n "${labels[$label]:-}" ]]; then
            log_error "$vm/$disk: la etiqueta '$label' ya se usa en el disco '${labels[$label]}'"
            rc=1
        else
            labels[$label]="$disk"
        fi
        if [[ "$fstate" != "inactive" && -n "${mounts[$mount]:-}" ]]; then
            log_error "$vm/$disk: el montaje '$mount' ya se usa en el disco '${mounts[$mount]}'"
            rc=1
        elif [[ "$fstate" != "inactive" ]]; then
            mounts[$mount]="$disk"
        fi
    done < <(cfg_disk_keys "$vm" "$file")
    return "$rc"
}

# @description Validación completa del fichero declarativo antes de tocar el hipervisor.
# Ordena por etapas: primero el fichero como tal (se detiene en su primer
# error) y, después, cada vm contra su nombre, sus claves, sus obligatorias,
# su credencial y sus discos. Acumula todos los errores del fichero y devuelve
# 1 si alguno falló, sin detenerse en el primero.
# @arg $1 path Fichero YAML a validar.
# @stderr Todos los errores acumulados, vía log_error.
# @exitcode 0 El fichero pasa todas las comprobaciones.
# @exitcode 1 Alguna comprobación falló.
cfg_validate() {
    local file="$1"
    cfg_validate_file "$file" || return 1
    local vms errors=0 vm
    vms="$(yq -r '. | keys | .[]' "$file" 2>/dev/null || true)"
    for vm in $vms; do
        if ! cfg_validate_name "$vm"; then
            errors=1
            continue
        fi
        cfg_validate_keys "$vm" "$file" || errors=1
        cfg_validate_required "$vm" "$file" || errors=1
        cfg_validate_credentials "$vm" "$file" || errors=1
        cfg_validate_disks "$vm" "$file" || errors=1
    done
    if ((errors != 0)); then
        return 1
    fi
    return 0
}

# @description Alias de cfg_vms() para recorrer las máquinas declaradas.
# @noargs
# @stdout Un nombre de vm por línea.
# @see cfg_vms()
cfg_each_vm() {
    cfg_vms
}
