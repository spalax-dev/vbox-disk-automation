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
# storage.bats: preparacion, desprendimiento y eliminacion de discos de datos
# sobre el doble de VBoxManage. Se cubren tambien las guardas que mantienen el
# disco del sistema fuera del alcance de la orden.

# Doble de VBoxManage, estado aislado y bibliotecas de la solucion.
setup() {
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
    export VBOXDISK_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export VBOXDISK_MOCK_STATE="$BATS_TEST_TMPDIR/adjuntos"
    export VBOXDISK_MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
    unset VBOXDISK_MOCK_ATTACHED VBOXDISK_ASSUME_YES 2>/dev/null || true
    REPO="$BATS_TEST_DIRNAME/.."
    export VBOXDISK_FILE="$BATS_TEST_DIRNAME/fixtures/valid.yml"
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/config.sh"
    source "$REPO/src/lib/state.sh"
    source "$REPO/src/lib/vbox.sh"
    source "$REPO/src/lib/storage.sh"
}

@test "confirm_choice con -y elige eliminar sin preguntar" {
    export VBOXDISK_ASSUME_YES=1
    confirm_choice "disco registrado y ausente del archivo"
    [ "$CHOICE" = "e" ]
}

@test "confirm_choice sin terminal cancela la corrida" {
    run confirm_choice "disco registrado y ausente del archivo"
    [ "$status" -eq 4 ]
    [[ "$output" == *"no es un terminal"* ]]
}

@test "storage_require_space rechaza un disco sin caber en el directorio" {
    run storage_require_space "$BATS_TEST_TMPDIR/disco.vdi" 999999999
    [ "$status" -eq 1 ]
    [[ "$output" == *"espacio insuficiente"* ]]
    run storage_require_space "$BATS_TEST_TMPDIR/disco.vdi" 64
    [ "$status" -eq 0 ]
}

@test "storage_pick_port salta el puerto ocupado por el disco del sistema" {
    local pick
    pick="$(storage_pick_port VM1)"
    [ "$pick" = "SATA 1" ]
}

@test "la adjuncion registrada informa controlador y puerto" {
    printf '%s\n' "/no/existe/VM1-disk1.vdi" >"$VBOXDISK_MOCK_STATE"
    [ "$(storage_attachment VM1 /no/existe/VM1-disk1.vdi)" = "SATA 1" ]
    [ "$(storage_medium_uuid VM1 /no/existe/VM1-disk1.vdi)" = "aaaaaaaa-0000-0000-0000-000000000001" ]
    run storage_attachment VM1 /no/existe/otro.vdi
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "storage_ensure_medium crea el disco y lo adjunta en el puerto libre" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    run storage_ensure_medium VM1 "$disk" 64
    [ "$status" -eq 0 ]
    [ -f "$disk" ]
    [ "$(storage_attachment VM1 "$disk")" = "SATA 1" ]
    # una segunda corrida no vuelve a crear ni a adjuntar
    run storage_ensure_medium VM1 "$disk" 64
    [ "$status" -eq 0 ]
    [[ "$output" == *"ya esta adjunto"* ]]
    [ "$(grep -c 'storageattach' "$VBOXDISK_MOCK_LOG" || true)" -eq 1 ]
}

@test "storage_ensure_detached retira el disco y conserva el fichero" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    : >"$disk"
    printf '%s\n' "$disk" >"$VBOXDISK_MOCK_STATE"
    run storage_ensure_detached VM1 "$disk"
    [ "$status" -eq 0 ]
    [ -f "$disk" ]
    run storage_disk_attached VM1 "$disk"
    [ "$status" -eq 1 ]
}

@test "storage_ensure_detached con el disco ausente no hace nada" {
    run storage_ensure_detached VM1 "$BATS_TEST_TMPDIR/nunca-adjunto.vdi"
    [ "$status" -eq 0 ]
}

@test "storage_delete_medium se niega a eliminar un medio adjunto" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    : >"$disk"
    printf '%s\n' "$disk" >"$VBOXDISK_MOCK_STATE"
    run storage_delete_medium VM1 "$disk"
    [ "$status" -eq 3 ]
    [[ "$output" == *"sigue adjunto"* ]]
    [ -f "$disk" ]
}

@test "storage_delete_medium se niega a eliminar algo que no es un vdi" {
    run storage_delete_medium VM1 "$BATS_TEST_TMPDIR/datos.raw"
    [ "$status" -eq 3 ]
    [[ "$output" == *"solo se admiten ficheros .vdi"* ]]
}

@test "storage_delete_medium borra un disco de datos ya desprendido" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    : >"$disk"
    run storage_delete_medium VM1 "$disk"
    [ "$status" -eq 0 ]
    [ ! -e "$disk" ]
}

@test "storage_delete_medium se niega a eliminar el fichero de configuracion" {
    local cfg="/home/jorge/.mvs/debian/VM1/VM1.vbox"
    run storage_delete_medium VM1 "$cfg"
    [ "$status" -eq 3 ]
    [[ "$output" == *"solo se admiten ficheros .vdi"* ]]
}

@test "storage_delete_medium se niega a eliminar el disco del sistema" {
    local boot="/home/jorge/.mvs/debian/VM1/VM1-disk1.qcow"
    run storage_delete_medium VM1 "$boot"
    [ "$status" -eq 3 ]
    [[ "$output" == *"solo se admiten ficheros .vdi"* ]]
}

@test "los discos declarados no confunden su fichero con el de otro" {
    [ "$(storage_disk_file VM1 disk1)" = "/no/existe/VM1-disk1.vdi" ]
    [ "$(storage_disk_file VM2 disk1)" = "/no/existe/VM2-disk1.vdi" ]
}

@test "la huella de la maquina refleja los discos declarados" {
    local a b
    a="$(storage_fingerprint VM1)"
    [[ "$a" =~ ^[0-9a-f]{64}$ ]]
    VBOXDISK_FILE="$BATS_TEST_DIRNAME/fixtures/same_size.yml"
    b="$(storage_fingerprint VM1)"
    [ "$a" != "$b" ]
}
