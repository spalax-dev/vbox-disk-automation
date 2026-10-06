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
# make.bats: guardas del sistema de construccion sobre un HOME aislado.
# uninstall debe retirar los ficheros instalados sin tocar jamas el perfil
# del usuario: el bloque del PATH que install anadio ha de sobrevivir
# intacto, tambien cuando no hay nada instalado.

# HOME aislado con un perfil que ya contiene el bloque del PATH.
setup() {
    REPO="$BATS_TEST_DIRNAME/.."
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_DATA_HOME="$HOME/.local/share"
    mkdir -p "$HOME/.local/bin" "$XDG_DATA_HOME/vboxdisk/lib"
    printf '# >>> vboxdisk >>>\nexport PATH="$HOME/.local/bin:$PATH"\n# <<< vboxdisk <<<\n' >"$HOME/.bashrc"
    cp "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.orig"
    cp "$REPO/src/vboxdisk" "$HOME/.local/bin/vboxdisk"
    : >"$XDG_DATA_HOME/vboxdisk/lib/common.sh"
}

@test "uninstall retira los ficheros instalados y conserva el perfil" {
    run make -C "$REPO" --no-print-directory uninstall
    [ "$status" -eq 0 ]
    [[ "$output" == *"retirado el ejecutable y las bibliotecas"* ]]
    [ ! -e "$HOME/.local/bin/vboxdisk" ]
    [ ! -e "$XDG_DATA_HOME/vboxdisk/lib" ]
    cmp -s "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.orig"
}

@test "uninstall sin instalacion previa termina bien y no escribe en el perfil" {
    rm -f "$HOME/.local/bin/vboxdisk"
    rm -rf "$XDG_DATA_HOME/vboxdisk/lib"
    run make -C "$REPO" --no-print-directory uninstall
    [ "$status" -eq 0 ]
    cmp -s "$HOME/.bashrc" "$BATS_TEST_TMPDIR/bashrc.orig"
}
