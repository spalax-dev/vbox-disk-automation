#!/usr/bin/env bats
# config.bats: validacion y precedencia de vdisk.yml con yq.

setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    FIX="$BATS_TEST_DIRNAME/fixtures"
    source "$REPO/src/lib/common.sh"
    source "$REPO/src/lib/config.sh"
    unset VBOXDISK_MOUNT_POINT VBOXDISK_VM_USER 2>/dev/null || true
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

@test "cfg_get lee el valor del archivo declarativo" {
    VBOXDISK_FILE="$FIX/valid.yml"
    [ "$(cfg_get VM1 mount_point)" = "/mnt/datos" ]
    [ "$(cfg_get VM2 fs_type)" = "xfs" ]
}

@test "una clave opcional ausente devuelve cadena vacia" {
    VBOXDISK_FILE="$FIX/valid.yml"
    [ "$(cfg_get VM1 disk_device)" = "" ]
}

@test "la variable de entorno prevalece sobre el archivo" {
    VBOXDISK_FILE="$FIX/valid.yml"
    export VBOXDISK_MOUNT_POINT=/env/datos
    [ "$(cfg_get VM1 mount_point)" = "/env/datos" ]
}
