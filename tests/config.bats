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
