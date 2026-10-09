#!/usr/bin/env bats
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
# config.bats: validacion y precedencia de vdisk.yml con yq.

# Bibliotecas bajo prueba y limpieza de variables de entorno heredadas.
setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIX="$BATS_TEST_DIRNAME/fixtures"
    export VBOXDISK_FILE="$FIX/valid.yml"
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/config.sh"
    unset VBOXDISK_MOUNT_POINT VBOXDISK_VM_USER 2>/dev/null || true
}

@test "la plantilla del repositorio solo pide crear el fichero de contrasena" {
    run cfg_validate "$REPO/vdisk.yml.example"
    [ "$status" -eq 1 ]
    [[ "$output" == *"vm_pass_file"* ]]
    [ "$(printf '%s\n' "$output" | grep -c ERROR)" -eq 1 ]
}

@test "un archivo valido supera la validacion" {
    run cfg_validate "$FIX/valid.yml"
    [ "$status" -eq 0 ]
}

@test "una clave no reservada se rechaza" {
    run cfg_validate "$FIX/unknown_key.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"clave no reservada"* ]]
}

@test "una variable obligatoria ausente se rechaza" {
    run cfg_validate "$FIX/missing_required.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"falta la variable obligatoria"* ]]
}

@test "un fs_type fuera de ext4 y xfs se rechaza" {
    run cfg_validate "$FIX/bad_fs.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"debe ser ext4 o xfs"* ]]
}

@test "un bloque sin credenciales se rechaza" {
    run cfg_validate "$FIX/no_creds.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"vm_pass"* ]]
}

@test "un vm_pass_file ilegible se rechaza" {
    run cfg_validate "$FIX/unreadable.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no se puede leer"* ]]
}

@test "un fichero que no es YAML valido se rechaza" {
    run cfg_validate "$FIX/invalid.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"YAML valido"* ]]
}

@test "un nombre de maquina invalido se rechaza" {
    run cfg_validate "$FIX/bad_name.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nombre de vm invalido"* ]]
}

@test "cfg_vms enumera las maquinas declaradas" {
    run cfg_vms
    [ "$status" -eq 0 ]
    [[ "$output" == *"VM1"* ]]
    [[ "$output" == *"VM2"* ]]
}

@test "una vm declara varios discos con sus claves" {
    VBOXDISK_FILE="$FIX/valid.yml"
    [ "$(cfg_get VM1 vm_user)" = "debian" ]
    [ "$(cfg_disk_keys VM1 "$FIX/valid.yml" | wc -l)" -eq 2 ]
    [ "$(cfg_disk_get VM1 disk1 mount_point)" = "/mnt/datos" ]
    [ "$(cfg_disk_get VM1 disk2 mount_point)" = "/mnt/respaldo" ]
    [ "$(cfg_disk_get VM2 disk1 fs_type)" = "xfs" ]
}

@test "una clave opcional ausente devuelve cadena vacia" {
    VBOXDISK_FILE="$FIX/valid.yml"
    [ "$(cfg_get VM2 vm_pass)" = "" ]
    [ "$(cfg_disk_get VM1 disk2 state)" = "" ]
}

@test "la variable de entorno prevalece sobre el archivo" {
    VBOXDISK_FILE="$FIX/valid.yml"
    export VBOXDISK_VM_USER=deploy
    [ "$(cfg_get VM1 vm_user)" = "deploy" ]
}

@test "size_to_mb acepta sufijos y rechaza lo que no es tamano" {
    [ "$(size_to_mb 4096)" = "4096" ]
    [ "$(size_to_mb 4g)" = "4096" ]
    [ "$(size_to_mb 1GB)" = "1024" ]
    [ "$(size_to_mb 512m)" = "512" ]
    [ "$(size_to_mb 1t)" = "1048576" ]
    run size_to_mb 4giguas
    [ "$status" -eq 1 ]
    run size_to_mb 0
    [ "$status" -eq 1 ]
}

@test "el tamano declarado se convierte a megabytes" {
    VBOXDISK_FILE="$FIX/valid.yml"
    [ "$(cfg_disk_size_mb VM1 disk1)" = "4096" ]
    [ "$(cfg_disk_size_mb VM1 disk2)" = "1024" ]
    [ "$(cfg_disk_size_mb VM2 disk1)" = "3072" ]
}

@test "el estado de un disco es active por defecto" {
    VBOXDISK_FILE="$FIX/valid.yml"
    [ "$(cfg_disk_state VM1 disk1)" = "active" ]
}

@test "los dos discos de la misma vm conviven en valid.yml" {
    run cfg_validate "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    local sizes
    sizes="$(cfg_disk_size_mb VM1 disk1) $(cfg_disk_size_mb VM1 disk2)"
    [ "$sizes" = "4096 1024" ]
}

@test "dos discos con el mismo tamano no generan ambiguedad" {
    run cfg_validate "$FIX/same_size.yml"
    [ "$status" -eq 0 ]
}

@test "el esquema plano anterior se rechaza con indicacion de migracion" {
    run cfg_validate "$FIX/legacy.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"esquema anterior"* ]]
    [[ "$output" == *"disks"* ]]
}

@test "un size ilegible se rechaza" {
    run cfg_validate "$FIX/bad_size.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"'size' debe ser"* ]]
}

@test "un state distinto de active e inactive se rechaza" {
    run cfg_validate "$FIX/bad_state.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"'state' debe ser active o inactive"* ]]
}

@test "montar sobre la raiz del sistema se rechaza" {
    run cfg_validate "$FIX/mount_root.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ruta absoluta distinta de '/'"* ]]
}

@test "dos discos que repiten la etiqueta se rechazan" {
    run cfg_validate "$FIX/dup_label.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ya se usa en el disco"* ]]
}

@test "una clave no reservada dentro de un disco se rechaza" {
    run cfg_validate "$FIX/unknown_disk_key.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"disk1: clave no reservada 'capacidad_extra'"* ]]
}

@test "disks que no es un mapa se rechaza" {
    run cfg_validate "$FIX/not_map.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"debe ser un mapa de discos"* ]]
}

# Copia del archivo declarativo sobre la que se sincroniza, con el estado que
# alimenta a cfg_sync_disk: el original del repositorio jamas se modifica.
sync_env() {
    source "$REPO/src/lib/state.sh"
    export VBOXDISK_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export VBOXDISK_FILE="$BATS_TEST_TMPDIR/vdisk.yml"
    cp "$FIX/valid.yml" "$VBOXDISK_FILE"
}

@test "cfg_sync_disk redeclara el disco a partir de state.lock" {
    sync_env
    state_set_vm VM1 \
        "disks.viejo.state=active" \
        "disks.viejo.file=$BATS_TEST_TMPDIR/viejo.vdi" \
        "disks.viejo.size_mb=6144" \
        "disks.viejo.label=viejo-vm1" \
        "disks.viejo.fs_type=xfs" \
        "disks.viejo.mount_point=/mnt/viejo"
    cfg_sync_disk VM1 viejo
    local tmp="$VBOXDISK_SYNC_TMP"
    [ -n "$tmp" ]
    [ "$(yq -r '.VM1.disks.viejo.size' "$tmp")" = "6144" ]
    [ "$(yq -r '.VM1.disks.viejo.size | type' "$tmp")" = "!!int" ]
    [ "$(yq -r '.VM1.disks.viejo.label' "$tmp")" = "viejo-vm1" ]
    [ "$(yq -r '.VM1.disks.viejo.fs_type' "$tmp")" = "xfs" ]
    [ "$(yq -r '.VM1.disks.viejo.mount_point' "$tmp")" = "/mnt/viejo" ]
    [ "$(yq -r '.VM1.disks.viejo.file' "$tmp")" = "$BATS_TEST_TMPDIR/viejo.vdi" ]
    [ "$(yq -r '.VM1.disks.viejo.state // "sin-state"' "$tmp")" = "sin-state" ]
    run cfg_validate "$tmp"
    [ "$status" -eq 0 ]
    cfg_sync_discard
    [ -z "$VBOXDISK_SYNC_TMP" ]
}

@test "cfg_sync_disk exige el registro completo y no abre copia alguna" {
    sync_env
    state_set_vm VM1 "disks.viejo.state=active"
    run cfg_sync_disk VM1 viejo
    [ "$status" -eq 1 ]
    [[ "$output" == *"no guarda tamano"* ]]
    [ -z "$(ls "$BATS_TEST_TMPDIR"/vdisk.yml.sync.* 2>/dev/null)" ]
    [ ! -f "$VBOXDISK_FILE.bak" ]
}

@test "cfg_sync_vm declara la vm ausente y respeta la ya declarada" {
    sync_env
    cfg_sync_vm VM9 debian secreto ""
    local tmp="$VBOXDISK_SYNC_TMP"
    [ "$(yq -r '.VM9.vm_user' "$tmp")" = "debian" ]
    [ "$(yq -r '.VM9.vm_pass' "$tmp")" = "secreto" ]
    cfg_sync_vm VM1 otra clave ""
    [ "$(yq -r '.VM1.vm_user' "$tmp")" = "debian" ]
    [ "$(yq -r '.VM1.vm_pass' "$tmp")" = "secreto" ]
    cfg_sync_discard
}

@test "cfg_sync_vm con fichero de credencial deja vm_pass_file" {
    sync_env
    cfg_sync_vm VM9 debian "" /etc/hostname
    [ "$(yq -r '.VM9.vm_pass_file' "$VBOXDISK_SYNC_TMP")" = "/etc/hostname" ]
    cfg_sync_discard
}

@test "cfg_sync_commit reemplaza el archivo y guarda el respaldo" {
    sync_env
    state_set_vm VM9 \
        "disks.viejo.state=active" \
        "disks.viejo.file=$BATS_TEST_TMPDIR/viejo.vdi" \
        "disks.viejo.size_mb=6144" \
        "disks.viejo.label=viejo-vm9" \
        "disks.viejo.fs_type=ext4" \
        "disks.viejo.mount_point=/mnt/viejo"
    cfg_sync_vm VM9 debian secreto ""
    cfg_sync_disk VM9 viejo
    cfg_sync_commit
    [ -z "$VBOXDISK_SYNC_TMP" ]
    [ "$(yq -r '.VM9.disks.viejo.size' "$VBOXDISK_FILE")" = "6144" ]
    [ "$(yq -r '.VM9.vm_user' "$VBOXDISK_FILE")" = "debian" ]
    [ -f "$VBOXDISK_FILE.bak" ]
    cmp -s "$FIX/valid.yml" "$VBOXDISK_FILE.bak"
    [ -z "$(ls "$BATS_TEST_TMPDIR"/vdisk.yml.sync.* 2>/dev/null)" ]
    run cfg_validate "$VBOXDISK_FILE"
    [ "$status" -eq 0 ]
}

@test "cfg_sync_commit descarta la sincronizacion invalida" {
    sync_env
    local before
    before="$(cat "$VBOXDISK_FILE")"
    cfg_sync_vm VM9 debian "" /no/existe/clave.pass
    run cfg_sync_commit
    [ "$status" -eq 1 ]
    [[ "$output" == *"sincronizacion invalida"* ]]
    [[ "$output" == *"vm_pass_file"* ]]
    [ "$(cat "$VBOXDISK_FILE")" = "$before" ]
    [ -z "$(ls "$BATS_TEST_TMPDIR"/vdisk.yml.sync.* 2>/dev/null)" ]
}
