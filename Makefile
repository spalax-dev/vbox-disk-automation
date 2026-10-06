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
# Makefile: sistema de construccion de vboxdisk.
# install encadena checkdeps, lint y test y solo entonces copia los ficheros
# en las rutas XDG del usuario, sin privilegios.

SHELL := /bin/bash
.DEFAULT_GOAL := help

HOME ?= $(shell echo $$HOME)
XDG_DATA_HOME ?= $(HOME)/.local/share
BINDIR := $(HOME)/.local/bin
DATADIR := $(XDG_DATA_HOME)/vboxdisk

.PHONY: help checkdeps lint test install uninstall

# help: lista de objetivos (objetivo por defecto).
help:
	@printf '%s\n' \
	'vboxdisk: make <objetivo>' \
	'' \
	'  help        Muestra esta ayuda (objetivo por defecto)' \
	'  checkdeps   Comprueba las dependencias de ejecucion y de desarrollo' \
	'  lint        Ejecuta ShellCheck sobre el punto de entrada y las bibliotecas' \
	'  test        Ejecuta las pruebas unitarias con BATS' \
	'  install     Verifica, prueba e instala en las rutas XDG del usuario' \
	'  uninstall   Retira el ejecutable y las bibliotecas instalados'

# checkdeps: comprueba dependencias de ejecucion y de desarrollo sin instalar nada.
checkdeps:
	@missing=""; \
	for d in bash VBoxManage yq ip; do \
		command -v "$$d" >/dev/null 2>&1 || missing="$$missing $$d"; \
	done; \
	for d in make shellcheck bats; do \
		command -v "$$d" >/dev/null 2>&1 || missing="$$missing $$d"; \
	done; \
	if [[ -n "$$missing" ]]; then \
		printf 'checkdeps: faltan dependencias:%s\n' "$$missing" >&2; \
		printf 'checkdeps: no se ha instalado nada\n' >&2; \
		exit 1; \
	fi; \
	printf 'checkdeps: dependencias de ejecucion y de desarrollo presentes\n'

# lint: ShellCheck sobre el punto de entrada y las bibliotecas.
lint:
	shellcheck src/vboxdisk src/lib/*.sh
	@printf 'lint: ShellCheck sin observaciones\n'

# test: pruebas unitarias con BATS.
test:
	bats tests/
	@printf 'test: pruebas unitarias superadas\n'

# install: encadena checkdeps, lint y test y solo entonces copia los ficheros
# a las rutas XDG del usuario y anade el directorio al PATH de los shells.
install:
	@$(MAKE) --no-print-directory checkdeps
	@$(MAKE) --no-print-directory lint
	@$(MAKE) --no-print-directory test
	install -d "$(BINDIR)" "$(DATADIR)/lib"
	install -m 0755 src/vboxdisk "$(BINDIR)/vboxdisk"
	install -m 0644 src/lib/*.sh "$(DATADIR)/lib/"
	install -m 0644 vdisk.yml.example "$(DATADIR)/"
	@for rc in "$(HOME)/.bashrc" "$(HOME)/.zshrc"; do \
		[[ -f "$$rc" ]] || continue; \
		grep -Fq '.local/bin' "$$rc" && continue; \
		printf '\n# >>> vboxdisk >>>\nexport PATH="$$HOME/.local/bin:$$PATH"\n# <<< vboxdisk <<<\n' >>"$$rc"; \
		printf 'install: PATH anadido en %s\n' "$$rc"; \
	done
	@printf 'install: ejecutable en %s\n' "$(BINDIR)/vboxdisk"
	@printf 'install: bibliotecas y plantilla en %s\n' "$(DATADIR)/"
	@printf 'install: abra una sesion nueva para usar la orden vboxdisk\n'

# uninstall: retira el ejecutable y las bibliotecas, conservando el perfil
# del usuario y state.lock, las bitacoras y vdisk.yml. El perfil (~/.bashrc,
# ~/.zshrc) no se toca: retirar de nuevo un bloque que el usuario pudo
# editar o que ya no pertenece a la solucion es delicado y queda en su mano.
uninstall:
	@rm -f "$(BINDIR)/vboxdisk"
	@rm -rf "$(DATADIR)/lib"
	@rm -f "$(DATADIR)/vdisk.yml.example"
	@printf 'uninstall: retirado el ejecutable y las bibliotecas\n'
	@printf 'uninstall: se conservan el perfil del usuario, state.lock, las bitacoras y vdisk.yml\n'
