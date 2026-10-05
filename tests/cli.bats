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
# cli.bats: analisis de argumentos, codigos de salida, ordenes de solo lectura
# y plan de cambios. Usa el doble de VBoxManage de tests/bin.

# PATH con los dobles de tests/bin y estado aislado por prueba en tmp.
setup() {
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
    export VBOXDISK_STATE_DIR="$BATS_TEST_TMPDIR/state"
    REPO="$BATS_TEST_DIRNAME/.."
    ENTRY="$REPO/src/vboxdisk"
    FIX="$BATS_TEST_DIRNAME/fixtures"
}

@test "sin argumentos muestra el uso y termina con 1" {
    run "$ENTRY"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Uso: vboxdisk"* ]]
}

@test "--help muestra el uso y termina con 0" {
    run "$ENTRY" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Uso: vboxdisk"* ]]
}

@test "--version informa la version y termina con 0" {
    run "$ENTRY" --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"vboxdisk 1.0.0"* ]]
}

@test "una bandera desconocida termina con 1" {
    run "$ENTRY" --parada
    [ "$status" -eq 1 ]
    [[ "$output" == *"bandera desconocida"* ]]
}

@test "una orden desconocida termina con 1" {
    run "$ENTRY" chapucear
    [ "$status" -eq 1 ]
    [[ "$output" == *"argumento inesperado"* ]]
}

@test "dos ordenes en la misma corrida terminan con 1" {
    run "$ENTRY" apply status
    [ "$status" -eq 1 ]
    [[ "$output" == *"solo se admite una orden"* ]]
}

@test "ld sin nombre de maquina termina con 1" {
    run "$ENTRY" ld
    [ "$status" -eq 1 ]
    [[ "$output" == *"requiere el nombre"* ]]
}

@test "dry-run fuera de apply termina con 1" {
    run "$ENTRY" status --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"solo aplica a la orden apply"* ]]
}

@test "apply con archivo declarativo inexistente termina con 1" {
    run "$ENTRY" apply -f "$BATS_TEST_TMPDIR/vdisk.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no supera la validacion"* ]]
}

@test "apply --dry-run elabora el plan sin crear estado" {
    run "$ENTRY" apply --dry-run -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"primera aplicacion"* ]]
    [[ "$output" == *"VM1:"* ]]
    [[ "$output" == *"VM2:"* ]]
    [[ "$output" == *"disk1: se creara y adjuntara el disco de 4096 MB"* ]]
    [[ "$output" == *"disk2: se creara y adjuntara el disco de 1024 MB"* ]]
    [ ! -e "$XDG_DATA_HOME/vboxdisk" ]
    [ ! -e "$VBOXDISK_STATE_DIR" ]
}

@test "apply --dry-run senala el disco registrado y ausente del archivo" {
    export VBOXDISK_FILE="$FIX/valid.yml"
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/config.sh"
    source "$REPO/src/lib/state.sh"
    source "$REPO/src/lib/vbox.sh"
    source "$REPO/src/lib/storage.sh"
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '%s\n' \
        '[VM1]' \
        "desired_hash=$(storage_desired_hash VM1)" \
        "fingerprint=$(storage_fingerprint VM1)" \
        'disks.viejo.state=active' \
        >"$VBOXDISK_STATE_DIR/state.lock"
    run "$ENTRY" apply --dry-run -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"viejo: registrado y ausente del archivo declarativo; requiere decision"* ]]
    [[ "$output" == *"discos registrados pendientes de decision"* ]]
}

@test "el disco inactivo registrado no se declara huerfano" {
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '[VM1]\ndisks.viejo.state=inactive\n' >"$VBOXDISK_STATE_DIR/state.lock"
    run "$ENTRY" apply --dry-run -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" != *"requiere decision"* ]]
}

@test "apply --dry-run con vm ausente en el hipervisor termina con 1" {
    run "$ENTRY" apply --dry-run -f "$FIX/unknown_vm.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no existe en el hipervisor"* ]]
}

@test "status lista las maquinas declaradas con su estado" {
    run "$ENTRY" status -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"MAQUINA"* ]]
    [[ "$output" == *"DISCOS"* ]]
    [[ "$output" == *"VM1"* ]]
    [[ "$output" == *"VM2"* ]]
    [[ "$output" == *"sin estado"* ]]
    [[ "$output" == *"2 sin registrar"* ]]
    [[ "$output" == *"1 sin registrar"* ]]
}

@test "status refleja los discos registrados en state.lock" {
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '[VM1]\nlast_run=2026-10-03 12:00:00\ndisks.disk1.state=active\ndisks.disk2.state=active\n' \
        >"$VBOXDISK_STATE_DIR/state.lock"
    run "$ENTRY" status -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 activos"* ]]
}

@test "ld muestra el registro de state.lock" {
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '[VM1]\nlast_run=2026-10-03 12:00:00\n' >"$VBOXDISK_STATE_DIR/state.lock"
    run "$ENTRY" ld VM1 -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"registro de VM1: 2026-10-03 12:00:00"* ]]
    [[ "$output" == *"sin discos registrados"* ]]
}

@test "ld muestra la tabla de particiones de cada disco" {
    local table=$'NAME  SIZE FSTYPE LABEL\nsdb   4.0G ext4   datos-vm1'
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '%s\n' \
        '[VM1]' \
        'last_run=2026-10-03 12:00:00' \
        'disks.disk1.state=active' \
        'disks.disk1.size_mb=4096' \
        'disks.disk1.label=datos-vm1' \
        'disks.disk1.mount_point=/mnt/datos' \
        'disks.disk1.fs_type=ext4' \
        "disks.disk1.table_b64=$(printf '%s' "$table" | base64 -w0)" \
        >"$VBOXDISK_STATE_DIR/state.lock"
    run "$ENTRY" ld VM1 -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"disco disk1 (active, 4096 MB, ext4, etiqueta datos-vm1, montado en /mnt/datos)"* ]]
    [[ "$output" == *"sdb"* ]]
}

@test "ld de una maquina sin registro termina con 1" {
    run "$ENTRY" ld VM1 -f "$FIX/valid.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ningun registro"* ]]
}

@test "ld de una maquina no declarada termina con 1" {
    run "$ENTRY" ld VM9 -f "$FIX/valid.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no esta declarada"* ]]
}

@test "aggregate_code respeta el orden de severidad de la tabla" {
    source "$REPO/src/lib/common.sh"
    [ "$(aggregate_code)" = "0" ]
    [ "$(aggregate_code 0 2)" = "2" ]
    [ "$(aggregate_code 3 2)" = "3" ]
    [ "$(aggregate_code 4 3)" = "4" ]
    [ "$(aggregate_code 1 4)" = "1" ]
    [ "$(aggregate_code 1 2 3 4)" = "1" ]
}

@test "la identificacion de IP sin respaldo disponible termina sin hallar direccion" {
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/vbox.sh"
    run vbox_detect_ip VM1 0
    [ "$status" -eq 1 ]
}

@test "la salida clave=valor del invitado se interpreta con su centinela" {
    source "$REPO/src/lib/storage.sh"
    storage_parse_guest_output "$(printf '%s\n' \
        'DEVICE=/dev/sdb' \
        'TABLE=gpt' \
        'FSTYPE=ext4' \
        'UUID=abcd-1234' \
        'MOUNTED=yes' \
        'MOUNTPOINT=/mnt/datos' \
        'FSTAB=yes' \
        'TABLE_LINE=sdb 4.0G ext4 datos /mnt/datos' \
        'VBOXDISK_EXIT=0')"
    [ "$GUEST_EXIT" = "0" ]
    [ "$GUEST_DEVICE" = "/dev/sdb" ]
    [ "$GUEST_TABLE" = "gpt" ]
    [ "$GUEST_FSTYPE" = "ext4" ]
    [ "$GUEST_UUID" = "abcd-1234" ]
    [ "$GUEST_MOUNTED" = "yes" ]
    [ "$GUEST_FSTAB" = "yes" ]
    [ "$GUEST_TABLE_LINES" = "sdb 4.0G ext4 datos /mnt/datos" ]
}

@test "una salida sin centinela queda sin interpretar" {
    source "$REPO/src/lib/storage.sh"
    storage_parse_guest_output "mensaje de error del servicio Guest Control"
    [ -z "$GUEST_EXIT" ]
    [ -z "$GUEST_DEVICE" ]
}
