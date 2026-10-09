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
    # stdin forzado a no terminal: la prueba debe ser valida tambien cuando la
    # suite se lanza desde una terminal interactiva.
    run confirm_choice "disco registrado y ausente del archivo" </dev/null
    [ "$status" -eq 4 ]
    [[ "$output" == *"no hay terminal donde preguntar"* ]]
    [[ "$output" != *"use -y"* ]]
}

@test "confirm sin terminal cancela la corrida con 4" {
    run confirm "continuar con la operacion" </dev/null
    [ "$status" -eq 4 ]
    [[ "$output" == *"no hay terminal donde preguntar"* ]]
    [[ "$output" == *"continuar con la operacion"* ]]
    [[ "$output" != *"use -y"* ]]
}

@test "confirm con -y se omite sin preguntar" {
    export VBOXDISK_ASSUME_YES=1
    run confirm "continuar con la operacion" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"confirmacion omitida por -y"* ]]
}

@test "confirm_choice sincroniza con s, sincronizar o sync" {
    local ans
    for ans in s sincronizar sync; do
        read_answer() { printf '%s' "$ans"; }
        confirm_choice "disco registrado y ausente del archivo"
        [ "$CHOICE" = "s" ]
    done
}

@test "confirm_choice omite con o, omitir, saltar o sin respuesta" {
    local ans
    for ans in o omitir saltar ""; do
        read_answer() { printf '%s' "$ans"; }
        confirm_choice "disco registrado y ausente del archivo"
        [ "$CHOICE" = "o" ]
    done
}

@test "confirm_choice rechaza una respuesta desconocida y vuelve a preguntar" {
    local tries="$BATS_TEST_TMPDIR/intentos" resp="$BATS_TEST_TMPDIR/respuestas"
    printf '%s\n' zap s >"$resp"
    read_answer() {
        local n=0 line
        if [[ -f "$tries" ]]; then
            n="$(cat "$tries")"
        fi
        n=$((n + 1))
        printf '%s\n' "$n" >"$tries"
        line="$(head -n1 "$resp")"
        sed -i 1d "$resp"
        printf '%s' "$line"
    }
    confirm_choice "disco registrado y ausente del archivo" 2>/dev/null
    [ "$CHOICE" = "s" ]
    [ "$(cat "$tries")" = "2" ]
}

@test "sync_credentials pide usuario y contrasena en claro" {
    local resp="$BATS_TEST_TMPDIR/respuestas" tries="$BATS_TEST_TMPDIR/intentos"
    printf '%s\n' debian secreto >"$resp"
    read_answer() {
        local n=0 line
        if [[ -f "$tries" ]]; then
            n="$(cat "$tries")"
        fi
        n=$((n + 1))
        printf '%s\n' "$n" >"$tries"
        if ((n > 4)); then
            return 1
        fi
        line="$(head -n1 "$resp")"
        sed -i 1d "$resp"
        printf '%s' "$line"
    }
    sync_credentials VM9
    [ "$SYNC_USER" = "debian" ]
    [ "$SYNC_PASS" = "secreto" ]
    [ -z "$SYNC_PASSFILE" ]
}

@test "sync_credentials acepta un fichero con la contrasena" {
    local resp="$BATS_TEST_TMPDIR/respuestas" tries="$BATS_TEST_TMPDIR/intentos"
    printf '%s\n' debian "" /etc/hostname >"$resp"
    read_answer() {
        local n=0 line
        if [[ -f "$tries" ]]; then
            n="$(cat "$tries")"
        fi
        n=$((n + 1))
        printf '%s\n' "$n" >"$tries"
        if ((n > 5)); then
            return 1
        fi
        line="$(head -n1 "$resp")"
        sed -i 1d "$resp"
        printf '%s' "$line"
    }
    sync_credentials VM9
    [ "$SYNC_USER" = "debian" ]
    [ "$SYNC_PASSFILE" = "/etc/hostname" ]
    [ -z "$SYNC_PASS" ]
}

@test "sync_credentials sin terminal cancela la corrida con 4" {
    run sync_credentials VM9 </dev/null
    [ "$status" -eq 4 ]
    [[ "$output" == *"no hay terminal donde preguntar"* ]]
}

@test "guest_session_open deja la vm en VBOXDISK_CURRENT_VM para la limpieza" {
    source "$REPO/src/lib/apply.sh"
    GUEST_SCRIPT="$REPO/src/lib/guest_ensure.sh"
    guest_session_open VM1
    [ "$VBOXDISK_CURRENT_VM" = "VM1" ]
    guest_session_close VM1
    cleanup_tmps
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

@test "storage_pick_port cuenta un puerto existente sin medio como libre" {
    export VBOXDISK_MOCK_SATA_NONE=1
    local pick
    pick="$(storage_pick_port VM1)"
    [ "$pick" = "SATA 1" ]
}

@test "storage_ensure_medium amplia el PortCount cuando el puerto queda fuera del rango" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    run storage_ensure_medium VM1 "$disk" 64
    [ "$status" -eq 0 ]
    # El doble nace con PortCount=1 (solo el disco del sistema): adjuntar
    # en el puerto 1 exige ampliarlo antes, como en la maquina real.
    grep -q '^storagectl VM1 --name SATA --portcount 2$' "$VBOXDISK_MOCK_LOG"
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

@test "storage_medium_capacity lee la capacidad fijada al crear el medio" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    run VBoxManage createmedium disk --filename "$disk" --size 4096 --format VDI
    [ "$status" -eq 0 ]
    [ "$(storage_medium_capacity "$disk")" = "4096" ]
}

@test "storage_medium_capacity sin un fichero legible no devuelve capacidad" {
    local disk="$BATS_TEST_TMPDIR/sin-capacidad.vdi"
    : >"$disk"
    run storage_medium_capacity "$disk"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run storage_medium_capacity "$BATS_TEST_TMPDIR/nunca-existio.vdi"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "storage_ensure_size amplia un medio menor que lo declarado" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    printf '4096\n' >"$disk"
    run storage_ensure_size VM1 "$disk" 8192
    [ "$status" -eq 0 ]
    [[ "$output" == *"medio ampliado de 4096 a 8192 MB"* ]]
    [ "$(storage_medium_capacity "$disk")" = "8192" ]
    grep -q "^modifymedium disk $disk --resize 8192$" "$VBOXDISK_MOCK_LOG"
}

@test "storage_ensure_size con el tamano declarado no vuelve a tocar el medio" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    printf '4096\n' >"$disk"
    run storage_ensure_size VM1 "$disk" 4096
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    sin_ampliacion
}

@test "storage_ensure_size sin capacidad publicada no toca el medio" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    : >"$disk"
    run storage_ensure_size VM1 "$disk" 8192
    [ "$status" -eq 0 ]
    [[ "$output" == *"no se pudo leer la capacidad"* ]]
    sin_ampliacion
}

@test "storage_ensure_size se niega a reducir un medio" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    printf '8192\n' >"$disk"
    run storage_ensure_size VM1 "$disk" 4096
    [ "$status" -eq 3 ]
    [[ "$output" == *"VirtualBox no admite reducir un medio"* ]]
    [ "$(storage_medium_capacity "$disk")" = "8192" ]
    sin_ampliacion
}

@test "storage_ensure_size detiene la maquina encendida sin preguntar" {
    unset VBOXDISK_MOCK_VMSTATE 2>/dev/null || true
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    printf '4096\n' >"$disk"
    printf 'running\n' >"$VBOXDISK_MOCK_STATE.vmstate"
    run storage_ensure_size VM1 "$disk" 8192
    [ "$status" -eq 0 ]
    [[ "$output" == *"deteniendo la maquina para ampliar"* ]]
    grep -q '^controlvm VM1 acpipowerbutton$' "$VBOXDISK_MOCK_LOG"
    grep -q '^modifymedium disk ' "$VBOXDISK_MOCK_LOG"
    [ "$(cat "$VBOXDISK_MOCK_STATE.vmstate")" = "poweroff" ]
}

@test "storage_ensure_medium amplia el medio existente antes de adjuntarlo" {
    local disk="$BATS_TEST_TMPDIR/VM1-datos.vdi"
    printf '4096\n' >"$disk"
    run storage_ensure_medium VM1 "$disk" 8192
    [ "$status" -eq 0 ]
    [ "$(storage_medium_capacity "$disk")" = "8192" ]
    [ "$(storage_attachment VM1 "$disk")" = "SATA 1" ]
}

# La bitacora del doble no contiene ninguna ampliacion de medio.
sin_ampliacion() {
    if [[ -f "$VBOXDISK_MOCK_LOG" ]]; then
        ! grep -q '^modifymedium' "$VBOXDISK_MOCK_LOG"
    fi
}

# Deja declarado VM1/disk1 y su registro en state.lock, con valid.yml tal cual.
cambios_env() {
    export VBOXDISK_FILE="$BATS_TEST_TMPDIR/vdisk.yml"
    cp "$BATS_TEST_DIRNAME/fixtures/valid.yml" "$VBOXDISK_FILE"
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '%s\n' \
        '[VM1]' \
        'disks.disk1.state=active' \
        'disks.disk1.size_mb=4096' \
        'disks.disk1.label=datos-vm1' \
        'disks.disk1.fs_type=ext4' \
        'disks.disk1.mount_point=/mnt/datos' \
        'disks.disk1.file=/no/existe/VM1-disk1.vdi' \
        >"$VBOXDISK_STATE_DIR/state.lock"
}

@test "storage_disk_changes sin declaracion que cambiar devuelve vacio" {
    cambios_env
    [ -z "$(storage_disk_changes VM1 disk1 largo)" ]
}

@test "storage_disk_changes reporta los campos que cambiaron" {
    cambios_env
    yq -i '.VM1.disks.disk1.size = 8192' "$VBOXDISK_FILE"
    yq -i '.VM1.disks.disk1.mount_point = "/mnt/otro"' "$VBOXDISK_FILE"
    [ "$(storage_disk_changes VM1 disk1 largo)" = "tamano 4096 -> 8192 MB; montaje /mnt/datos -> /mnt/otro" ]
    [ "$(storage_disk_changes VM1 disk1 corto)" = "tamano; montaje" ]
}

@test "storage_disk_changes sin registro previo del disco no reporta nada" {
    cambios_env
    printf '[VM1]\n' >"$VBOXDISK_STATE_DIR/state.lock"
    yq -i '.VM1.disks.disk1.size = 8192' "$VBOXDISK_FILE"
    [ -z "$(storage_disk_changes VM1 disk1 largo)" ]
}

@test "storage_require_size admite un megabyte de diferencia" {
    GUEST_SIZE_MB=4097
    run storage_require_size "VM1/disk1" 4096
    [ "$status" -eq 0 ]
    GUEST_SIZE_MB=4100
    run storage_require_size "VM1/disk1" 4096
    [ "$status" -eq 1 ]
    [[ "$output" == *"el invitado ve 4100 MB y lo declarado es 4096 MB"* ]]
}

@test "storage_require_size sin tamano informado por el invitado falla" {
    GUEST_SIZE_MB=""
    run storage_require_size "VM1/disk1" 4096
    [ "$status" -eq 1 ]
    [[ "$output" == *"no informo el tamano del disco"* ]]
}
