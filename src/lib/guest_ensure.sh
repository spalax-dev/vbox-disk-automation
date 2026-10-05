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
# guardas de almacenamiento (tabla, sistema de archivos y montaje).
# Modos: --probe (solo lectura) y convergencia. Termina siempre con la centinela
# VBOXDISK_EXIT=<n> en la salida estandar.
set -uo pipefail

ORIG_ARGS=("$@")
PROBE=0
DEVICE_OPT=""
SIZE_MB=""
MOUNT=""
FSTYPE=""
LABEL=""
PASSFILE=""

usage() {
    cat <<'EOF'
Uso: guest_ensure.sh [--probe] --size-mb N --mount /ruta --fstype ext4|xfs
                     [--label ETIQUETA] [--device /dev/sdX] [--passfile archivo]
EOF
}

# Analisis de los argumentos del script invitado.
while (($#)); do
    case "$1" in
        --probe)
            PROBE=1
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

# finish <codigo>: destruye el fichero de credenciales, emite la centinela
# VBOXDISK_EXIT=<codigo> por stdout y termina con ese mismo codigo.
finish() {
    local rc="$1"
    if [[ -n "${PASSFILE:-}" && -f "${PASSFILE:-}" ]]; then
        shred -u "$PASSFILE" 2>/dev/null || rm -f "$PASSFILE"
    fi
    echo "VBOXDISK_EXIT=$rc"
    exit "$rc"
}

# validate_args: validacion de los argumentos obligatorios antes de
# cualquier accion. Cada comprobacion reporta su propio motivo de rechazo
# y termina con la centinela; ninguna toca el sistema de archivos.
validate_args() {
    if [[ -z "$SIZE_MB" || -z "$MOUNT" || -z "$FSTYPE" ]]; then
        usage >&2
        finish 1
    fi
    if [[ "$FSTYPE" != "ext4" && "$FSTYPE" != "xfs" ]]; then
        echo "fs_type invalido: $FSTYPE (se espera ext4 o xfs)" >&2
        finish 1
    fi
    if [[ "$MOUNT" != /* ]]; then
        echo "mount_point invalido: $MOUNT" >&2
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

# emit_state: vuelca el estado observado en pares clave=valor por stdout,
# terminando con la tabla de lsblk como lineas TABLE_LINE=.
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

# fail <mensaje> [codigo]: mensaje de error en stderr y fin con la centinela
# (codigo 3, almacenamiento, si no se indica otro).
fail() {
    echo "guest_ensure: $1" >&2
    finish "${2:-3}"
}

# detect_device: el indicado con --device, o el disco libre cuyo tamano
# coincide con el declarado (tolerancia de 1 MB).
detect_device() {
    local name size type want tol diff best=""
    if [[ -n "$DEVICE_OPT" ]]; then
        if [[ ! -b "$DEVICE_OPT" ]]; then
            fail "dispositivo inexistente: $DEVICE_OPT" 1
        fi
        G_DEV="$DEVICE_OPT"
        return 0
    fi
    want=$((SIZE_MB * 1024 * 1024))
    tol=$((1024 * 1024))
    while read -r name size type; do
        if [[ "$type" != "disk" ]]; then
            continue
        fi
        if lsblk -nrpo MOUNTPOINT "/dev/$name" 2>/dev/null | grep -q '[^[:space:]]'; then
            continue
        fi
        diff=$((size - want))
        if ((diff < 0)); then
            diff=$((-diff))
        fi
        if ((diff <= tol)); then
            best="/dev/$name"
            break
        fi
    done < <(lsblk -b -dn -o NAME,SIZE,TYPE)
    if [[ -z "$best" ]]; then
        fail "no se identifico ningun disco de ${SIZE_MB} MB libre de montajes" 3
    fi
    G_DEV="$best"
}

# collect: observa el dispositivo actual sin modificarlo y rellena las
# variables G_* (tabla, particion, fs, UUID, montaje y fstab).
collect() {
    local pttype
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

# wait_for_partition: aguarda hasta 15 s a que udev publique la particion
# recien creada por parted.
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

# ensure_label: aplica la etiqueta declarada si difiere de la actual
# (e2label en ext4, xfs_admin en xfs).
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

# ensure_fstab: anade la entrada UUID al montar solo si aun no existe;
# pass 0 en xfs y 2 en ext4, segun la convencion de fsck.
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

# converge: aplicacion de las tres guardas en orden, cada una tras comprobar
# que su condicion aun no se cumple.
converge() {
    # Guarda 1: tabla de particiones.
    collect
    if [[ "$G_TABLE" == "none" ]]; then
        echo "guest_ensure: creando tabla GPT en $G_DEV" >&2
        parted -s "$G_DEV" mklabel gpt mkpart primary 1MiB 100% ||
            fail "parted fallo al crear la tabla de particiones en $G_DEV"
        partprobe "$G_DEV" 2>/dev/null || true
        udevadm settle 2>/dev/null || true
        wait_for_partition ||
            fail "la particion no aparecio tras parted en $G_DEV"
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

# Flujo principal: detectar el disco y, segun el modo, solo sondear o
# converger; en ambos casos se emite siempre el estado y la centinela.
detect_device

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
