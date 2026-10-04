#!/usr/bin/env bats
# state.bats: state.lock, bitacoras y huellas en el host.

setup() {
    export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/data"
    export VBOXDISK_STATE_DIR="$BATS_TEST_TMPDIR/state"
    source "$BATS_TEST_DIRNAME/../src/lib/common.sh"
    source "$BATS_TEST_DIRNAME/../src/lib/state.sh"
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
    state_set_vm VM1 "table_b64=$(state_encode_table "$table")"
    [ "$(state_table_b64 VM1)" = "$table" ]
}

@test "state_open_log crea una bitacora por corrida" {
    state_init_dirs
    state_open_log
    [ -n "$VBOXDISK_LOG_FILE" ]
    [ -f "$VBOXDISK_LOG_FILE" ]
    grep -q "bitacora de la corrida" "$VBOXDISK_LOG_FILE"
    grep -q "vboxdisk 1.0.0" "$VBOXDISK_LOG_FILE"
}

@test "la huella fisica es estable ante consultas repetidas" {
    local disk="$BATS_TEST_TMPDIR/disco.vdi" a b c
    printf 'contenido del disco' >"$disk"
    a="$(storage_fingerprint VM1 "$disk")"
    b="$(storage_fingerprint VM1 "$disk")"
    [ "$a" = "$b" ]
    [[ "$a" =~ ^[0-9a-f]{64}$ ]]
    printf ' y otros bytes' >>"$disk"
    c="$(storage_fingerprint VM1 "$disk")"
    [ "$a" != "$c" ]
}

@test "el hash declarado distingue a las maquinas y es estable" {
    VBOXDISK_FILE="$BATS_TEST_DIRNAME/fixtures/valid.yml"
    local hash1 hash2
    hash1="$(storage_desired_hash VM1)"
    hash2="$(storage_desired_hash VM2)"
    [ "$hash1" != "$hash2" ]
    [ "$(storage_desired_hash VM1)" = "$hash1" ]
}
