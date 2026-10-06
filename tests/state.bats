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
# state.bats: state.lock, bitacoras y huellas en el host.

# Estado aislado en tmp y carga de las bibliotecas de comun, estado y almacenamiento.
setup() {
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
    export VBOXDISK_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export VBOXDISK_FILE="$BATS_TEST_DIRNAME/fixtures/valid.yml"
    source "$BATS_TEST_DIRNAME/../src/lib/common.sh"
    source "$BATS_TEST_DIRNAME/../src/lib/config.sh"
    source "$BATS_TEST_DIRNAME/../src/lib/state.sh"
    source "$BATS_TEST_DIRNAME/../src/lib/vbox.sh"
    source "$BATS_TEST_DIRNAME/../src/lib/storage.sh"
}

@test "state_set_vm y state_get componen una entrada por maquina" {
    state_set_vm VM1 "desired_hash=abc" "ip=192.168.1.51"
    [ "$(state_get VM1 desired_hash)" = "abc" ]
    [ "$(state_get VM1 ip)" = "192.168.1.51" ]
    run state_get VM1 faltante
    [ "$status" -eq 1 ]
}

@test "reescribir una entrada no duplica bloques ni afecta a las demas" {
    state_set_vm VM1 "a=1"
    state_set_vm VM2 "b=2"
    state_set_vm VM1 "a=3"
    [ "$(state_get VM1 a)" = "3" ]
    [ "$(state_get VM2 b)" = "2" ]
    [ "$(grep -c '^\[VM1\]$' "$VBOXDISK_STATE_DIR/state.lock")" = "1" ]
}

@test "la tabla de particiones sobrevive al codigo base64" {
    local table=$'NAME    SIZE FSTYPE LABEL\ndev     4G   ext4   datos'
    state_set_vm VM1 "disks.disk1.table_b64=$(state_encode_table "$table")"
    [ "$(state_table_b64 VM1 disk1)" = "$table" ]
    run state_table_b64 VM1 disk9
    [ "$status" -eq 1 ]
}

@test "state_open_log crea una bitacora por corrida" {
    state_init_dirs
    state_open_log
    [ -n "$VBOXDISK_LOG_FILE" ]
    [ -f "$VBOXDISK_LOG_FILE" ]
    grep -q "bitacora de la corrida" "$VBOXDISK_LOG_FILE"
    grep -q "vboxdisk 1.0.0" "$VBOXDISK_LOG_FILE"
}

@test "la huella fisica de un disco es estable ante consultas repetidas" {
    local disk="$BATS_TEST_TMPDIR/disco.vdi" a b c
    printf 'contenido del disco' >"$disk"
    a="$(storage_disk_fingerprint VM1 "$disk")"
    b="$(storage_disk_fingerprint VM1 "$disk")"
    [ "$a" = "$b" ]
    [[ "$a" =~ ^[0-9a-f]{64}$ ]]
    printf ' y otros bytes' >>"$disk"
    c="$(storage_disk_fingerprint VM1 "$disk")"
    [ "$a" != "$c" ]
}

@test "la huella de la maquina cubre sus discos declarados" {
    local a b
    a="$(storage_fingerprint VM1)"
    b="$(storage_fingerprint VM1)"
    [ "$a" = "$b" ]
    [[ "$a" =~ ^[0-9a-f]{64}$ ]]
}

@test "state_disk_keys lista los discos registrados en orden" {
    state_set_vm VM1 "disks.disk1.state=active" "disks.disk2.state=active" "ip=192.168.1.16"
    [ "$(state_disk_keys VM1 | tr '\n' ' ')" = "disk1 disk2 " ]
    [ "$(state_get_disk VM1 disk2 state)" = "active" ]
    run state_disk_keys VM9
    [ "$status" -eq 0 ]
}

@test "state_vms lista las secciones registradas en orden" {
    state_set_vm VM1 "ip=192.168.1.16"
    state_set_vm VM2 "ip=192.168.1.18"
    run state_vms
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "VM1" ]
    [ "${lines[1]}" = "VM2" ]
}

@test "state_vms sin state.lock termina sin salida" {
    run state_vms
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "state_update_vm fusiona sin borrar las claves existentes" {
    state_update_vm VM1 "disks.disk1.state=active" "disks.disk1.uuid=aaa" "ip=192.168.1.16"
    state_update_vm VM1 "disks.disk1.uuid=bbb"
    [ "$(state_get VM1 ip)" = "192.168.1.16" ]
    [ "$(state_get_disk VM1 disk1 state)" = "active" ]
    [ "$(state_get_disk VM1 disk1 uuid)" = "bbb" ]
    [ "$(grep -c '^\[VM1\]$' "$VBOXDISK_STATE_DIR/state.lock")" = "1" ]
}

@test "state_remove_disk retira el registro de un disco y conserva al resto" {
    state_update_vm VM1 "disks.disk1.state=active" "disks.disk2.state=active" "ip=192.168.1.16"
    state_remove_disk VM1 disk1
    run state_get_disk VM1 disk1 state
    [ "$status" -eq 1 ]
    [ "$(state_get_disk VM1 disk2 state)" = "active" ]
    [ "$(state_get VM1 ip)" = "192.168.1.16" ]
}

@test "state_remove_vm retira la seccion completa y conserva a las demas" {
    state_update_vm VM1 "ip=192.168.1.16"
    state_update_vm VM2 "ip=192.168.1.18"
    state_remove_vm VM1
    run state_get VM1 ip
    [ "$status" -eq 1 ]
    [ "$(state_get VM2 ip)" = "192.168.1.18" ]
    run state_vms
    [ "${lines[0]}" = "VM2" ]
}

@test "el hash declarado distingue a las maquinas y es estable" {
    local hash1 hash2
    hash1="$(storage_desired_hash VM1)"
    hash2="$(storage_desired_hash VM2)"
    [ "$hash1" != "$hash2" ]
    [ "$(storage_desired_hash VM1)" = "$hash1" ]
}

@test "el hash de cada disco distingue a los discos de una maquina" {
    local d1 d2
    d1="$(storage_disk_desired_hash VM1 disk1)"
    d2="$(storage_disk_desired_hash VM1 disk2)"
    [ "$d1" != "$d2" ]
    [ "$(storage_disk_desired_hash VM1 disk1)" = "$d1" ]
}

@test "el fichero del disco sale de la declaracion" {
    [ "$(storage_disk_file VM1 disk1)" = "/no/existe/VM1-disk1.vdi" ]
    [ "$(storage_disk_file VM1 disk2)" = "/no/existe/VM1-disk2.vdi" ]
}

@test "los discos registrados ausentes del archivo se declaran huerfanos" {
    state_set_vm VM1 "disks.disk1.state=active" "disks.viejo.state=active" "disks.retirado.state=inactive"
    [ "$(storage_orphan_disks VM1 | tr '\n' ' ')" = "viejo " ]
}
