#!/usr/bin/env bash
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
# guest_ensure.sh: se copia al invitado en cada corrida y aplica las tres
# guardas de almacenamiento (tabla, sistema de archivos y montaje) sobre un
# solo disco, el declarado por el host.
# Modos: --probe (solo lectura), convergencia y --release (desmonta y retira
# la entrada de /etc/fstab, sin modificar el disco). Termina siempre con la
# centinela VBOXDISK_EXIT=<n> en la salida estandar.
set -uo pipefail

# Guest Control arranca el script sin los directorios sbin, donde viven
# sfdisk, blockdev, blkid, mkfs y e2label; se completan antes de cualquier
# llamada.
PATH="/usr/local/sbin:/usr/sbin:/sbin:$PATH"
export PATH

ORIG_ARGS=("$@")
PROBE=0
RELEASE=0
DEVICE_OPT=""
SIZE_MB=""
MOUNT=""
FSTYPE=""
LABEL=""
PASSFILE=""

# @description Texto de uso del script invitado; quien invoca lo redirige a
# stderr cuando reporta un argumento invalido.
# @noargs
# @stdout Una linea con el uso y sus opciones obligatorias y opcionales.
usage() {
    cat <<'EOF'
Uso: guest_ensure.sh [--probe | --release] --size-mb N --mount /ruta
                     --fstype ext4|xfs --label ETIQUETA
                     [--device /dev/sdX] [--passfile archivo]
EOF
}

# Analisis de los argumentos del script invitado.
while (($#)); do
    case "$1" in
        --probe)
            PROBE=1
            ;;
        --release)
            RELEASE=1
            ;;
        --size-mb)
            SIZE_MB="${2:-}"
            shift
            ;;
        --mount)
            MOUNT="${2:-}"
            shift
            ;;
        --fstype)
            FSTYPE="${2:-}"
            shift
            ;;
        --label)
            LABEL="${2:-}"
            shift
            ;;
        --device)
            DEVICE_OPT="${2:-}"
            shift
            ;;
        --passfile)
            PASSFILE="${2:-}"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "argumento desconocido: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# @description Destruye el fichero de credenciales, emite la centinela
# VBOXDISK_EXIT=<codigo> por stdout y termina con ese mismo codigo.
# @arg $1 int Codigo de salida: 0 ok, 1 validacion o elevacion, 3 almacenamiento.
# @stdout La centinela VBOXDISK_EXIT=<codigo>.
# @exitcode 0 Terminacion correcta.
# @exitcode 1 Argumentos invalidos o elevacion con sudo fallida.
# @exitcode 3 Fallo de almacenamiento (codigo por defecto de fail).
finish() {
    local rc="$1"
    if [[ -n "${PASSFILE:-}" && -f "${PASSFILE:-}" ]]; then
        shred -u "$PASSFILE" 2>/dev/null || rm -f "$PASSFILE"
    fi
    echo "VBOXDISK_EXIT=$rc"
    exit "$rc"
}

# @description Validacion de los argumentos obligatorios antes de cualquier
# accion. Cada comprobacion reporta su propio motivo de rechazo y termina con
# la centinela; ninguna toca el sistema de archivos.
# @option --probe | --release Modos incompatibles entre si.
# @option --mount /ruta Punto de montaje obligatorio, absoluto y distinto de /.
# @option --size-mb N Tamano en MB obligatorio, salvo en --release.
# @option --fstype ext4|xfs Tipo de sistema de archivos obligatorio, salvo en --release.
# @option --label ETIQUETA Obligatoria salvo en --release; [A-Za-z0-9._-], hasta 16 caracteres en ext4 y 12 en xfs.
# @stderr Motivo del rechazo o el texto de uso.
# @exitcode 0 Argumentos validos.
# @exitcode 1 Argumentos invalidos: termina via finish con la centinela.
validate_args() {
    if ((PROBE == 1 && RELEASE == 1)); then
        echo "--probe y --release son incompatibles" >&2
        finish 1
    fi
    if [[ -z "$MOUNT" ]]; then
        usage >&2
        finish 1
    fi
    if [[ "$MOUNT" != /* || "$MOUNT" == "/" ]]; then
        echo "mount_point invalido: $MOUNT" >&2
        finish 1
    fi
    if ((RELEASE == 1)); then
        return 0
    fi
    if [[ -z "$SIZE_MB" || -z "$FSTYPE" || -z "$LABEL" ]]; then
        usage >&2
        finish 1
    fi
    if [[ "$FSTYPE" != "ext4" && "$FSTYPE" != "xfs" ]]; then
        echo "fs_type invalido: $FSTYPE (se espera ext4 o xfs)" >&2
        finish 1
    fi
    if [[ ! "$LABEL" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "label invalido: $LABEL (solo se admiten [A-Za-z0-9._-])" >&2
        finish 1
    fi
    if [[ "$FSTYPE" == "xfs" && ${#LABEL} -gt 12 ]]; then
        echo "label invalido: $LABEL no puede exceder 12 caracteres en xfs" >&2
        finish 1
    fi
    if [[ "$FSTYPE" == "ext4" && ${#LABEL} -gt 16 ]]; then
        echo "label invalido: $LABEL no puede exceder 16 caracteres en ext4" >&2
        finish 1
    fi
    return 0
}
validate_args

# Elevacion unica: sudo lee la contraseña del fichero copiado al invitado.
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
if [[ "$EUID" -ne 0 && "${VBOXDISK_ROOTED:-0}" != "1" ]]; then
    if [[ -n "$PASSFILE" && -f "$PASSFILE" ]]; then
        chmod 600 "$PASSFILE" 2>/dev/null || true
        exec sudo -S -p '' env VBOXDISK_ROOTED=1 bash "$SCRIPT_PATH" "${ORIG_ARGS[@]}" <"$PASSFILE"
        echo "no se pudo elevar con sudo (contraseña rechazada o sudo ausente)" >&2
        finish 1
    fi
    exec sudo -n env VBOXDISK_ROOTED=1 bash "$SCRIPT_PATH" "${ORIG_ARGS[@]}"
    echo "no se pudo elevar con sudo sin contraseña" >&2
    finish 1
fi

# Estado observado del dispositivo: lo completa collect() y lo vuelca emit_state().
G_DEV=""
G_PART=""
G_TABLE="none"
G_FSTYPE=""
G_UUID=""
G_MOUNTED="no"
G_FSTAB="no"
G_SIZE_MB=0

# @description Vuelca el estado observado en pares clave=valor por stdout,
# terminando con la tabla de lsblk como lineas TABLE_LINE=.
# @noargs
# @stdout DEVICE, SIZE_MB, TABLE, PART, FSTYPE, UUID, MOUNTED, MOUNTPOINT y FSTAB, y luego TABLE_LINE=<linea> por cada renglon de lsblk.
emit_state() {
    echo "DEVICE=$G_DEV"
    echo "SIZE_MB=$G_SIZE_MB"
    echo "TABLE=$G_TABLE"
    echo "PART=$G_PART"
    echo "FSTYPE=$G_FSTYPE"
    echo "UUID=$G_UUID"
    echo "MOUNTED=$G_MOUNTED"
    echo "MOUNTPOINT=$MOUNT"
    echo "FSTAB=$G_FSTAB"
    if [[ -n "$G_DEV" && -b "$G_DEV" ]]; then
        lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$G_DEV" 2>/dev/null |
            while IFS= read -r line; do
                echo "TABLE_LINE=$line"
            done
    fi
}

# @description Mensaje de error en stderr y fin con la centinela (codigo 3,
# almacenamiento, si no se indica otro).
# @arg $1 string Mensaje del fallo; se antepone "guest_ensure: ".
# @arg $2 int Codigo de salida opcional; por defecto 3.
# @stderr El mensaje del fallo con el prefijo "guest_ensure: ".
# @exitcode 3 Codigo por defecto cuando no se indica otro.
# @exitcode 1 Codigo explicito en $2 (el unico que se pasa en este script).
# @see finish()
fail() {
    echo "guest_ensure: $1" >&2
    finish "${2:-3}"
}

# @description El destino nunca es el disco que contiene la raiz; si lo es,
# la corrida se detiene sin tocar nada.
# @arg $1 string Dispositivo objetivo; si esta vacio o no es de bloque no hace nada.
# @stderr Mensaje de rechazo cuando el destino es el disco del sistema.
# @exitcode 0 El destino no es el disco del sistema (o no es de bloque).
# @exitcode 1 Termina via fail cuando el destino es o contiene la raiz.
assert_not_system_disk() {
    local target="$1" root_src root_disk resolved
    [[ -n "$target" && -b "$target" ]] || return 0
    resolved="$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")"
    if lsblk -nrpo MOUNTPOINT "$target" 2>/dev/null | grep -qx '/'; then
        fail "$target es el disco del sistema: la solucion se niega a modificarlo" 1
    fi
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    root_src="$(readlink -f "$root_src" 2>/dev/null || printf '%s' "$root_src")"
    if [[ -z "$root_src" || ! -b "$root_src" ]]; then
        return 0
    fi
    if [[ "$root_src" == "$resolved" ]]; then
        fail "$target es el disco del sistema: la solucion se niega a modificarlo" 1
    fi
    root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
    if [[ -n "$root_disk" && "/dev/$root_disk" == "$resolved" ]]; then
        fail "$target es el disco del sistema: la solucion se niega a modificarlo" 1
    fi
    return 0
}

# @description Disco que contiene el sistema de archivos con esa etiqueta; la
# particion se eleva a su disco contenedor, porque las guardas se aplican
# siempre sobre el disco completo.
# @arg $1 string Etiqueta del sistema de archivos.
# @stdout El dispositivo (/dev/sdX) sin salto de linea.
# @exitcode 0 Encontro el disco.
# @exitcode 1 No hay ningun dispositivo de bloque con esa etiqueta.
device_from_label() {
    local dev parent
    dev="$(blkid -L "$1" 2>/dev/null || true)"
    if [[ -z "$dev" || ! -b "$dev" ]]; then
        return 1
    fi
    parent="$(lsblk -no PKNAME "$dev" 2>/dev/null || true)"
    if [[ -n "$parent" ]]; then
        dev="/dev/$parent"
    fi
    printf '%s' "$dev"
    return 0
}

# @description La pista del host solo vale si el dispositivo existe y su
# tamano coincide con el declarado en SIZE_MB (tolerancia de 1 MB); en
# cualquier otro caso la deteccion sigue por el tamano.
# @arg $1 string Dispositivo sugerido por el host, p. ej. /dev/sdb.
# @exitcode 0 El dispositivo existe y su tamano difiere 1 MB o menos.
# @exitcode 1 No es un dispositivo de bloque o el tamano difiere mas de 1 MB.
device_hint_ok() {
    local dev="$1" want tol diff actual
    if [[ ! -b "$dev" ]]; then
        return 1
    fi
    want=$((SIZE_MB * 1024 * 1024))
    tol=$((1024 * 1024))
    actual="$(blockdev --getsize64 "$dev" 2>/dev/null || echo 0)"
    diff=$((actual - want))
    if ((diff < 0)); then
        diff=$((-diff))
    fi
    ((diff <= tol))
}

# @description El disco cuyo tamano coincide con el declarado (SIZE_MB,
# tolerancia de 1 MB), siempre que no tenga etiqueta (esa se identifica por su
# etiqueta), ni montajes, ni la raiz; dos candidatos iguales no se desempatan
# a ciegas.
# @noargs
# @set G_DEV string Disco identificado.
# @stderr Explica la ambiguedad o la ausencia de candidatos.
# @exitcode 0 Un unico candidato; deja el disco en G_DEV.
# @exitcode 1 Ningun candidato o varios candidatos sin desempatar.
detect_by_size() {
    local name size type tol diff best="" found=0
    local want=$((SIZE_MB * 1024 * 1024))
    tol=$((1024 * 1024))
    while read -r name size type; do
        if [[ "$type" != "disk" ]]; then
            continue
        fi
        if lsblk -nrpo LABEL "/dev/$name" 2>/dev/null | grep -q '[^[:space:]]'; then
            continue
        fi
        if lsblk -nrpo MOUNTPOINT "/dev/$name" 2>/dev/null | grep -q '[^[:space:]]'; then
            continue
        fi
        diff=$((size - want))
        if ((diff < 0)); then
            diff=$((-diff))
        fi
        if ((diff > tol)); then
            continue
        fi
        if ((found == 1)); then
            echo "guest_ensure: hay varios discos de ${SIZE_MB} MB sin etiqueta; identifique el disco con la etiqueta declarada o con --device" >&2
            return 1
        fi
        best="/dev/$name"
        found=1
    done < <(lsblk -b -dn -o NAME,SIZE,TYPE)
    if ((found == 0)); then
        echo "guest_ensure: no se identifico ningun disco de ${SIZE_MB} MB libre de montajes y sin etiqueta" >&2
        return 1
    fi
    G_DEV="$best"
    return 0
}

# @description La etiqueta declarada, y si el disco aun no la tiene, la pista
# del host y despues el tamano. Devuelve 1 sin tocar el sistema; quien decide
# si el fallo detiene la corrida es el flujo principal.
# @noargs
# @set G_DEV string Disco identificado.
# @exitcode 0 Disco identificado.
# @exitcode 1 Ningun metodo identifico el disco.
# @see device_from_label()
# @see device_hint_ok()
detect_device() {
    local dev
    if [[ -n "$LABEL" ]] && dev="$(device_from_label "$LABEL")"; then
        G_DEV="$dev"
        return 0
    fi
    if [[ -n "$DEVICE_OPT" ]] && device_hint_ok "$DEVICE_OPT"; then
        G_DEV="$DEVICE_OPT"
        return 0
    fi
    detect_by_size
}

# @description Observa el dispositivo actual sin modificarlo y rellena las
# variables G_* (tabla, particion, fs, UUID, montaje y fstab).
# @noargs
# @set G_PART string Primera particion del disco, o la que lleva la etiqueta declarada si pertenece a el; vacia si no hay.
# @set G_TABLE string Tipo de tabla de particiones (gpt, dos) o none.
# @set G_FSTYPE string Sistema de archivos de la particion, vacio si no existe.
# @set G_UUID string UUID de la particion, vacio si no existe.
# @set G_MOUNTED string "yes" si MOUNT esta montado, "no" en caso contrario.
# @set G_FSTAB string "yes" si /etc/fstab ya declara el UUID, "no" en caso contrario.
# @set G_SIZE_MB int Tamano del disco en MB; 0 si el dispositivo no existe.
# @exitcode 0 Siempre.
collect() {
    local pttype lp parent
    G_PART=""
    G_TABLE="none"
    G_FSTYPE=""
    G_UUID=""
    G_MOUNTED="no"
    G_FSTAB="no"
    G_SIZE_MB=0
    if [[ -z "$G_DEV" || ! -b "$G_DEV" ]]; then
        return 0
    fi
    G_SIZE_MB=$(($(blockdev --getsize64 "$G_DEV" 2>/dev/null || echo 0) / 1024 / 1024))
    pttype="$(blkid -p -s PTTYPE -o value "$G_DEV" 2>/dev/null || true)"
    if [[ -n "$pttype" ]]; then
        G_TABLE="$pttype"
    fi
    G_PART="$(lsblk -nrpo NAME,TYPE "$G_DEV" 2>/dev/null | awk '$2 == "part" { print $1; exit }')"
    # La particion que ya lleva la etiqueta declarada es la propia del disco,
    # aunque no sea la primera de la lista.
    if [[ -n "$LABEL" ]]; then
        lp="$(blkid -L "$LABEL" 2>/dev/null || true)"
        if [[ -n "$lp" && -b "$lp" ]]; then
            parent="$(lsblk -no PKNAME "$lp" 2>/dev/null || true)"
            if [[ -n "$parent" && "/dev/$parent" == "$(readlink -f "$G_DEV")" ]]; then
                G_PART="$lp"
            elif [[ -z "$parent" && "$lp" == "$G_DEV" ]]; then
                G_PART="$lp"
            fi
        fi
    fi
    if [[ -n "$G_PART" && -b "$G_PART" ]]; then
        G_FSTYPE="$(blkid -o value -s TYPE "$G_PART" 2>/dev/null || true)"
        G_UUID="$(blkid -o value -s UUID "$G_PART" 2>/dev/null || true)"
    fi
    if findmnt --mountpoint "$MOUNT" >/dev/null 2>&1; then
        G_MOUNTED="yes"
    fi
    if [[ -n "$G_UUID" ]] && grep -qE "^[[:space:]]*UUID=${G_UUID}[[:space:]]" /etc/fstab 2>/dev/null; then
        G_FSTAB="yes"
    fi
    return 0
}

# @description Aguarda hasta 15 s a que udev publique la particion recien
# creada por sfdisk.
# @noargs
# @set G_PART string Particion publicada por el kernel.
# @exitcode 0 La particion aparecio en el plazo.
# @exitcode 1 No aparecio tras 15 segundos.
wait_for_partition() {
    local i
    for ((i = 0; i < 15; i++)); do
        G_PART="$(lsblk -nrpo NAME,TYPE "$G_DEV" 2>/dev/null | awk '$2 == "part" { print $1; exit }')"
        if [[ -n "$G_PART" && -b "$G_PART" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# @description Aplica la etiqueta declarada si difiere de la actual (e2label en
# ext4, xfs_admin en xfs); no hace nada sin etiqueta declarada ni sin particion.
# @noargs
# @exitcode 0 Siempre; un fallo de la herramienta no detiene la corrida.
ensure_label() {
    local current
    [[ -n "$LABEL" && -n "$G_PART" ]] || return 0
    current="$(blkid -o value -s LABEL "$G_PART" 2>/dev/null || true)"
    if [[ "$current" == "$LABEL" ]]; then
        return 0
    fi
    case "$G_FSTYPE" in
        ext4)
            e2label "$G_PART" "$LABEL" || true
            ;;
        xfs)
            xfs_admin -L "$LABEL" "$G_PART" || true
            ;;
    esac
    return 0
}

# @description Anade la entrada UUID a /etc/fstab al montar solo si aun no
# existe; pass 0 en xfs y 2 en ext4, segun la convencion de fsck.
# @noargs
# @stderr Confirma la entrada agregada.
# @exitcode 0 Siempre; sin entrada que agregar tambien.
ensure_fstab() {
    local opts pass line
    grep -qE "^[[:space:]]*UUID=${G_UUID}[[:space:]]" /etc/fstab 2>/dev/null && return 0
    if [[ "$FSTYPE" == "xfs" ]]; then
        opts="defaults"
        pass="0"
    else
        opts="defaults"
        pass="2"
    fi
    line="UUID=$G_UUID $MOUNT $FSTYPE $opts $pass"
    printf '%s\n' "$line" >>/etc/fstab
    echo "guest_ensure: entrada agregada en /etc/fstab: $line" >&2
    return 0
}

# @description Retira de /etc/fstab las lineas que declaran el punto de
# montaje (o la etiqueta, si se conoce); no cambia los permisos del fichero
# porque el contenido se reescribe sobre el mismo inode.
# @noargs
# @stderr Confirma la entrada retirada para el punto de montaje.
# @exitcode 0 Siempre; sin entrada que retirar tambien.
remove_fstab_entries() {
    local tmp
    if [[ ! -r /etc/fstab ]]; then
        return 0
    fi
    tmp="$(mktemp)"
    if awk -v m="$MOUNT" -v l="$LABEL" '
        /^[[:space:]]*#/ || NF == 0 { print; next }
        (l != "" && $1 == "LABEL=" l) { hit = 1; next }
        $2 == m { hit = 1; next }
        { print }
        END { if (hit) exit 0; exit 1 }
    ' /etc/fstab >"$tmp"; then
        cat "$tmp" >/etc/fstab
        echo "guest_ensure: entrada retirada de /etc/fstab para $MOUNT" >&2
    fi
    rm -f "$tmp"
    return 0
}

# @description El retiro total de un disco inactivo o eliminado: desmonta el
# punto declarado y borra su entrada persistente, sin modificar el disco.
# @noargs
# @stderr Avisa del desmontaje o de que el punto no estaba montado.
# @exitcode 0 Desmontaje y fstab resueltos (o ya resueltos).
# @exitcode 3 Termina via fail si el desmontaje no se pudo completar.
release_mount() {
    if findmnt --mountpoint "$MOUNT" >/dev/null 2>&1; then
        echo "guest_ensure: desmontando $MOUNT" >&2
        umount "$MOUNT" || fail "no se pudo desmontar $MOUNT"
    else
        echo "guest_ensure: $MOUNT no esta montado" >&2
    fi
    remove_fstab_entries
    return 0
}

# @description Aplicacion de las tres guardas en orden (tabla de particiones,
# sistema de archivos, montaje y fstab), cada una tras comprobar que su
# condicion aun no se cumple.
# @noargs
# @stderr Progreso de cada guarda, avisos de montaje y el resumen con df -h.
# @exitcode 0 Las tres guardas quedaron satisfechas.
# @exitcode 3 Termina via fail ante cualquier guarda fallida.
converge() {
    # Guarda 1: tabla de particiones.
    collect
    if [[ "$G_TABLE" == "none" ]]; then
        echo "guest_ensure: creando tabla GPT en $G_DEV" >&2
        # sfdisk viene con el fdisk de util-linux, presente en toda
        # distro; parte la particion de 1MiB al final del disco y pide
        # al kernel que relea la tabla.
        printf 'label: gpt\nstart=1MiB\n' | sfdisk --quiet "$G_DEV" ||
            fail "sfdisk fallo al crear la tabla de particiones en $G_DEV"
        blockdev --rereadpt "$G_DEV" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        wait_for_partition ||
            fail "la particion no aparecio tras sfdisk en $G_DEV"
        collect
    fi
    if [[ -z "$G_PART" ]]; then
        fail "no se identifico la particion de $G_DEV"
    fi

    # Guarda 2: sistema de archivos.
    collect
    if [[ -z "$G_FSTYPE" ]]; then
        echo "guest_ensure: creando $FSTYPE en $G_PART" >&2
        if [[ "$FSTYPE" == "ext4" ]]; then
            if [[ -n "$LABEL" ]]; then
                mkfs.ext4 -F -L "$LABEL" "$G_PART" || fail "mkfs.ext4 fallo en $G_PART"
            else
                mkfs.ext4 -F "$G_PART" || fail "mkfs.ext4 fallo en $G_PART"
            fi
        else
            if [[ -n "$LABEL" ]]; then
                mkfs.xfs -f -L "$LABEL" "$G_PART" || fail "mkfs.xfs fallo en $G_PART"
            else
                mkfs.xfs -f "$G_PART" || fail "mkfs.xfs fallo en $G_PART"
            fi
        fi
        collect
    fi
    ensure_label

    # Guarda 3: punto de montaje y entrada persistente en /etc/fstab; solo se
    # actua si el montaje no esta ni declarado ni activo.
    collect
    if [[ "$G_MOUNTED" == "yes" && "$G_FSTAB" == "yes" ]]; then
        echo "guest_ensure: montaje ya declarado y activo en $MOUNT" >&2
        return 0
    fi
    if [[ -z "$G_UUID" ]]; then
        fail "la particion $G_PART no tiene UUID tras formatear"
    fi
    mkdir -p "$MOUNT" || fail "no se pudo crear el punto de montaje $MOUNT"
    ensure_fstab
    mount -a || fail "mount -a fallo"
    collect
    if ! findmnt --mountpoint "$MOUNT" >/dev/null 2>&1; then
        fail "$MOUNT no quedo montado tras mount -a"
    fi
    echo "guest_ensure: almacenamiento disponible en $MOUNT" >&2
    df -h "$MOUNT" >&2 || true
    return 0
}

# Flujo principal: el modo --release solo retira el montaje y su entrada; en
# los demas se identifica el disco, se comprueba que no es el del sistema y,
# segun el modo, solo se sondea o se converge. Siempre se emite el estado y
# la centinela.
if ((RELEASE == 1)); then
    if ! detect_device; then
        echo "guest_ensure: no se identifico el disco; se retira solo el montaje declarado" >&2
        G_DEV=""
    fi
    if [[ -n "$G_DEV" ]]; then
        assert_not_system_disk "$G_DEV"
    fi
    release_mount
    collect
    emit_state
    finish 0
fi

if ! detect_device; then
    finish 3
fi
assert_not_system_disk "$G_DEV"

if ((PROBE == 1)); then
    collect
    emit_state
    finish 0
fi

rc=0
converge || rc=$?
if ((rc != 0)); then
    collect
    emit_state
    finish "$rc"
fi
collect
emit_state
finish 0
