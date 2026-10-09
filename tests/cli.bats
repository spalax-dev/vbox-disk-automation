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

@test "dry-run sin orden senala la orden que falta y termina con 1" {
    run "$ENTRY" --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"quizas quiso decir: vboxdisk apply --dry-run"* ]]
    [[ "$output" == *"Uso: vboxdisk"* ]]
}

@test "-y sin orden senala la orden que falta y termina con 1" {
    run "$ENTRY" -y
    [ "$status" -eq 1 ]
    [[ "$output" == *"quizas quiso decir: vboxdisk apply -y"* ]]
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

@test "apply --dry-run atiende primero la vm registrada ausente del archivo" {
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '%s\n' '[VM9]' 'disks.viejo.state=active' \
        >"$VBOXDISK_STATE_DIR/state.lock"
    run "$ENTRY" apply --dry-run -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VM9: la vm ya no figura en el archivo declarativo; decision pendiente sobre sus discos registrados"* ]]
    [[ "$output" == *"viejo: sigue registrado y requiere decision"* ]]
    vm9="$(printf '%s\n' "$output" | grep -n '^VM9:' | cut -d: -f1)"
    vm1="$(printf '%s\n' "$output" | grep -n '^VM1:' | cut -d: -f1)"
    [ "$vm9" -lt "$vm1" ]
}

@test "apply --dry-run de una vm ausente sin discos activos no pide decision" {
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '%s\n' '[VM9]' 'disks.viejo.state=inactive' \
        >"$VBOXDISK_STATE_DIR/state.lock"
    run "$ENTRY" apply --dry-run -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *"VM9: la vm ya no figura en el archivo declarativo y no tiene decisiones pendientes"* ]]
    [[ "$output" != *"requiere decision"* ]]
}

@test "apply_vm se retira en una vm ausente cuyo registro ya no tiene discos activos" {
    export VBOXDISK_FILE="$FIX/valid.yml"
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/config.sh"
    source "$REPO/src/lib/state.sh"
    source "$REPO/src/lib/vbox.sh"
    source "$REPO/src/lib/storage.sh"
    source "$REPO/src/lib/apply.sh"
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '%s\n' '[VM9]' 'disks.viejo.state=inactive' \
        >"$VBOXDISK_STATE_DIR/state.lock"
    run apply_vm VM9
    [ "$status" -eq 0 ]
    [[ "$output" == *"VM9: ausente del archivo declarativo; se retira su seccion de state.lock"* ]]
    [[ "$output" != *"convergencia verificada"* ]]
    run state_vms
    [[ "$output" != *"VM9"* ]]
}

@test "apply_vm en una vm ausente formula la consulta y sin terminal cancela" {
    export VBOXDISK_FILE="$FIX/valid.yml"
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/config.sh"
    source "$REPO/src/lib/state.sh"
    source "$REPO/src/lib/vbox.sh"
    source "$REPO/src/lib/storage.sh"
    source "$REPO/src/lib/apply.sh"
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '%s\n' '[VM9]' 'disks.viejo.state=active' \
        >"$VBOXDISK_STATE_DIR/state.lock"
    run apply_vm VM9 </dev/null
    [ "$status" -eq 4 ]
    [[ "$output" == *"VM9: la maquina ya no figura en el archivo declarativo y su disco 'viejo' sigue registrado. Que se hace?"* ]]
    [[ "$output" == *"no hay terminal donde preguntar"* ]]
    [[ "$output" != *"convergencia verificada"* ]]
}

# Prepara una vm registrada que el archivo no declara, con un registro
# completo de su disco y un archivo declarativo propio de la prueba.
sync_env() {
    export VBOXDISK_FILE="$BATS_TEST_TMPDIR/vdisk.yml"
    export VBOXDISK_MOCK_STATE="$BATS_TEST_TMPDIR/adjuntos"
    export VBOXDISK_MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
    export GUEST_SCRIPT="$REPO/src/lib/guest_ensure.sh"
    unset VBOXDISK_MOCK_VMSTATE VBOXDISK_ASSUME_YES 2>/dev/null || true
    cp "$FIX/valid.yml" "$VBOXDISK_FILE"
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/config.sh"
    source "$REPO/src/lib/state.sh"
    source "$REPO/src/lib/vbox.sh"
    source "$REPO/src/lib/storage.sh"
    source "$REPO/src/lib/apply.sh"
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '%s\n' \
        '[VM9]' \
        'disks.viejo.state=active' \
        "disks.viejo.file=$BATS_TEST_TMPDIR/viejo.vdi" \
        'disks.viejo.size_mb=4096' \
        'disks.viejo.label=viejo-vm9' \
        'disks.viejo.fs_type=ext4' \
        'disks.viejo.mount_point=/mnt/viejo' \
        >"$VBOXDISK_STATE_DIR/state.lock"
    confirm_choice() {
        CHOICE="s"
        return 0
    }
}

@test "apply_vm sincroniza el archivo con state.lock y sigue la convergencia" {
    sync_env
    export VBOXDISK_MOCK_IP=192.168.1.16
    export VBOXDISK_MOCK_GA_VERSION=7.2.18
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
    run apply_vm VM9
    [ "$status" -eq 0 ]
    [[ "$output" == *"archivo declarativo sincronizado con state.lock (viejo)"* ]]
    [[ "$output" == *"convergencia verificada"* ]]
    [ "$(yq -r '.VM9.vm_user' "$VBOXDISK_FILE")" = "debian" ]
    [ "$(yq -r '.VM9.vm_pass' "$VBOXDISK_FILE")" = "secreto" ]
    [ "$(yq -r '.VM9.disks.viejo.size' "$VBOXDISK_FILE")" = "4096" ]
    [ "$(yq -r '.VM9.disks.viejo.file' "$VBOXDISK_FILE")" = "$BATS_TEST_TMPDIR/viejo.vdi" ]
    [ -f "$VBOXDISK_FILE.bak" ]
    cmp -s "$FIX/valid.yml" "$VBOXDISK_FILE.bak"
    grep -q "createmedium" "$VBOXDISK_MOCK_LOG"
    grep -q "startvm" "$VBOXDISK_MOCK_LOG"
    grep -q "^disks.viejo.state=active" "$VBOXDISK_STATE_DIR/state.lock"
    grep -q "^disks.viejo.kv_device=/dev/sdb" "$VBOXDISK_STATE_DIR/state.lock"
    grep -q "^desired_hash=" "$VBOXDISK_STATE_DIR/state.lock"
    [ "$(state_get VM9 desired_hash)" = "$(storage_desired_hash VM9)" ]
}

@test "apply_vm sin terminal para las credenciales cancela sin tocar el archivo" {
    sync_env
    run apply_vm VM9 </dev/null
    [ "$status" -eq 4 ]
    [[ "$output" == *"no hay terminal donde preguntar"* ]]
    [[ "$output" != *"sincronizado con state.lock"* ]]
    ! yq -e '.VM9' "$VBOXDISK_FILE" >/dev/null 2>&1
    [ ! -f "$VBOXDISK_FILE.bak" ]
    [ -z "$(ls "$BATS_TEST_TMPDIR"/vdisk.yml.sync.* 2>/dev/null)" ]
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
    # Sin terminal no se pinta nada: las columnas siguen cuadriculadas.
    [[ "$output" != *$'\x1b['* ]]
}

@test "status pinta la cabecera en negrita y el estado de sincronizacion" {
    export VBOXDISK_COLOR=always
    run "$ENTRY" status -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\x1b[1mMAQUINA'* ]]
    [[ "$output" == *$'\x1b[2msin estado'* ]]
    # El color envuelve la celda ya rellenada: los espacios de relleno quedan
    # dentro de la secuencia y la columna siguiente no se corre.
    grep -qP '\x1b\[2msin estado +\x1b\[0m' <<<"$output"
}

@test "apply --dry-run pinta el plan en terminal" {
    export VBOXDISK_COLOR=always
    run "$ENTRY" apply --dry-run -f "$FIX/valid.yml"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'\x1b['* ]]
    [[ "$output" == *$'\x1b[33mprimera aplicacion'* ]]
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

@test "ld sin registro con la vm apagada indica apply y termina con 1" {
    run "$ENTRY" ld VM1 -f "$FIX/valid.yml"
    [ "$status" -eq 1 ]
    [[ "$output" == *"la vm esta apagada"* ]]
    [[ "$output" == *"vboxdisk apply"* ]]
}

@test "ld sin registro consulta la tabla de la vm encendida" {
    export VBOXDISK_MOCK_VMSTATE=running
    export VBOXDISK_MOCK_LOG="$BATS_TEST_TMPDIR/vbox.log"
    run "$ENTRY" ld VM1 -f "$FIX/valid.yml"
    unset VBOXDISK_MOCK_VMSTATE VBOXDISK_MOCK_LOG
    [ "$status" -eq 0 ]
    [[ "$output" == *"sin corrida registrada"* ]]
    [[ "$output" == *"disco disk1"* ]]
    [[ "$output" == *"disco disk2"* ]]
    [[ "$output" == *"sdb"* ]]
    [[ "$output" == *"datos-vm1"* ]]
    ! grep -q "startvm" "$BATS_TEST_TMPDIR/vbox.log"
    grep -q -- '--target-directory=[^ ]*/ ' "$BATS_TEST_TMPDIR/vbox.log"
    grep -q -- '/bin/rm -rf /tmp/vboxdisk.MOCK0001' "$BATS_TEST_TMPDIR/vbox.log"
}

@test "ld en vivo informa los discos ausentes sin reportar fallo de comunicacion" {
    export VBOXDISK_MOCK_VMSTATE=running
    export VBOXDISK_MOCK_PROBE_EXIT=3
    run "$ENTRY" ld VM1 -f "$FIX/valid.yml"
    unset VBOXDISK_MOCK_VMSTATE VBOXDISK_MOCK_PROBE_EXIT
    [ "$status" -eq 0 ]
    [[ "$output" == *"no se identifico ningun disco"* ]]
    [[ "$output" == *"ejecute 'vboxdisk apply'"* ]]
    [[ "$output" != *"no se pudo consultar"* ]]
    [[ "$output" != *"consulta fallida"* ]]
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

@test "vbox_detect_ip obtiene la direccion de la propiedad del invitado" {
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/vbox.sh"
    export VBOXDISK_MOCK_IP=192.168.1.16
    run vbox_detect_ip VM1 0
    unset VBOXDISK_MOCK_IP
    [ "$status" -eq 0 ]
    [ "$output" = "192.168.1.16" ]
}

@test "vbox_wait_ready acepta la version publicada como GuestAdd" {
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/vbox.sh"
    export VBOXDISK_MOCK_GA_VERSION=7.2.20
    run vbox_wait_ready VM1 1
    [ "$status" -eq 0 ]
}

@test "vbox_wait_ready acepta tambien la version publicada como GuestAdditions" {
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/vbox.sh"
    export VBOXDISK_MOCK_GA_VERSION_LEGACY=7.2.18
    run vbox_wait_ready VM1 1
    [ "$status" -eq 0 ]
}

@test "vbox_wait_ready agota el tiempo sin ninguna version publicada" {
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/vbox.sh"
    run vbox_wait_ready VM1 0
    [ "$status" -eq 1 ]
}

@test "la salida clave=valor del invitado se interpreta con su centinela" {
    source "$REPO/src/lib/storage.sh"
    storage_parse_guest_output "$(printf '%s\n' \
        'DEVICE=/dev/sdb' \
        'SIZE_MB=4096' \
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
    [ "$GUEST_SIZE_MB" = "4096" ]
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
    [ -z "$GUEST_SIZE_MB" ]
}

@test "guest_snapshot y guest_restore conservan el tamano del invitado" {
    source "$REPO/src/lib/storage.sh"
    GUEST_SIZE_MB=8192
    guest_snapshot VM1 disk1
    GUEST_SIZE_MB=""
    guest_restore VM1 disk1
    [ "$GUEST_SIZE_MB" = "8192" ]
}

# Deja VM1 declarado con un unico disco en el tmpdir, registrado en state.lock
# con el tamano de siempre (4096 MB) y el medio ya creado con la capacidad
# indicada; sin capacidad (segundo argumento vacio) no se crea el fichero.
tamano_env() {
    local declarado="$1" capacidad="${2:-}" disk="$BATS_TEST_TMPDIR/disk1.vdi"
    export VBOXDISK_FILE="$BATS_TEST_TMPDIR/vdisk.yml"
    printf '%s\n' \
        'VM1:' \
        '  vm_user: debian' \
        '  vm_pass: "secreto"' \
        '  disks:' \
        '    disk1:' \
        "      size: $declarado" \
        '      fs_type: ext4' \
        '      mount_point: /mnt/datos' \
        '      label: datos-vm1' \
        "      file: $disk" \
        >"$VBOXDISK_FILE"
    mkdir -p "$VBOXDISK_STATE_DIR"
    printf '%s\n' \
        '[VM1]' \
        'disks.disk1.state=active' \
        'disks.disk1.size_mb=4096' \
        'disks.disk1.label=datos-vm1' \
        'disks.disk1.fs_type=ext4' \
        'disks.disk1.mount_point=/mnt/datos' \
        "disks.disk1.file=$disk" \
        >"$VBOXDISK_STATE_DIR/state.lock"
    if [[ -n "$capacidad" ]]; then
        printf '%s\n' "$capacidad" >"$disk"
    fi
}

@test "apply --dry-run senala el medio pequeno y el disco que cambio" {
    tamano_env 8192 4096
    run "$ENTRY" apply --dry-run -f "$VBOXDISK_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"disk1: declarado difiere del registro: tamano 4096 -> 8192 MB"* ]]
    [[ "$output" == *"disk1: el medio actual es de 4096 MB y lo declarado es de 8192 MB: se ampliara"* ]]
    [[ "$output" != *"no se puede reducir"* ]]
    # el plan no toca ni el medio ni el registro
    [ "$(cat "$BATS_TEST_TMPDIR/disk1.vdi")" = "4096" ]
    grep -q '^disks.disk1.size_mb=4096$' "$VBOXDISK_STATE_DIR/state.lock"
    [[ "$output" != *"modifymedium"* ]]
}

@test "apply --dry-run senala el medio mayor que lo declarado" {
    tamano_env 4096 8192
    run "$ENTRY" apply --dry-run -f "$VBOXDISK_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"disk1: el medio actual es de 8192 MB y lo declarado es de 4096 MB: no se puede reducir"* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/disk1.vdi")" = "8192" ]
}

@test "apply amplia el medio declarado y registra el tamano nuevo" {
    tamano_env 8192 4096
    export VBOXDISK_MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
    export VBOXDISK_MOCK_STATE="$BATS_TEST_TMPDIR/adjuntos"
    export VBOXDISK_MOCK_IP=192.168.1.16
    export VBOXDISK_MOCK_GA_VERSION=7.2.18
    export GUEST_SCRIPT="$REPO/src/lib/guest_ensure.sh"
    unset VBOXDISK_MOCK_VMSTATE VBOXDISK_ASSUME_YES 2>/dev/null || true
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/config.sh"
    source "$REPO/src/lib/state.sh"
    source "$REPO/src/lib/vbox.sh"
    source "$REPO/src/lib/storage.sh"
    source "$REPO/src/lib/apply.sh"
    run apply_vm VM1
    [ "$status" -eq 0 ]
    [[ "$output" == *"declarado difiere del registro: tamano 4096 -> 8192 MB"* ]]
    [[ "$output" == *"medio ampliado de 4096 a 8192 MB"* ]]
    [[ "$output" == *"convergencia verificada"* ]]
    grep -q "^modifymedium disk $BATS_TEST_TMPDIR/disk1.vdi --resize 8192$" "$VBOXDISK_MOCK_LOG"
    [ "$(cat "$BATS_TEST_TMPDIR/disk1.vdi")" = "8192" ]
    [ "$(state_get_disk VM1 disk1 size_mb)" = "8192" ]
    [ "$(state_get_disk VM1 disk1 fingerprint)" = "$(storage_disk_fingerprint VM1 "$BATS_TEST_TMPDIR/disk1.vdi")" ]
}

@test "apply termina con 3 cuando lo declarado es menor que el medio" {
    tamano_env 4096 8192
    export VBOXDISK_MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
    unset VBOXDISK_MOCK_VMSTATE VBOXDISK_ASSUME_YES 2>/dev/null || true
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/config.sh"
    source "$REPO/src/lib/state.sh"
    source "$REPO/src/lib/vbox.sh"
    source "$REPO/src/lib/storage.sh"
    source "$REPO/src/lib/apply.sh"
    run apply_vm VM1
    [ "$status" -eq 3 ]
    [[ "$output" == *"es menor que el medio actual"* ]]
    [[ "$output" != *"convergencia verificada"* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/disk1.vdi")" = "8192" ]
    if [[ -f "$VBOXDISK_MOCK_LOG" ]]; then
        ! grep -q '^modifymedium' "$VBOXDISK_MOCK_LOG"
    fi
}

@test "status detalla el disco que cambio cuando la vm esta desincronizada" {
    tamano_env 8192 4096
    printf '%s\n' 'desired_hash=que-no-coincide' >>"$VBOXDISK_STATE_DIR/state.lock"
    run "$ENTRY" status -f "$VBOXDISK_FILE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"desincronizada (disk1: tamano)"* ]]
}
