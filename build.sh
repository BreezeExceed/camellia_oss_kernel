
#!/usr/bin/env bash
set -Eeuo pipefail

# ==================================================
# CAMELLIAN OSS KERNEL BUILDER
# Kernel       : 4.14.186
# Architecture : arm64
# Clang        : r383902
# GCC          : Android GCC 4.9
# ==================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# ==================================================
# CONFIGURATION
# ==================================================

CLANG_REPO="https://github.com/msft-mirror-aosp/platform.prebuilts.clang.host.linux-x86.git"
CLANG_COMMIT="4114ce222c83ba93e9c12c91c6ced2541b28f88c"
CLANG_VERSION="clang-r383902"

GCC_REPO="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9.git"
GCC_BRANCH="lineage-19.1"

TOOLCHAIN="$ROOT/toolchain-src"
PREBUILTS="$ROOT/prebuilts"

CLANG_SRC="$TOOLCHAIN/clang"
GCC_SRC="$TOOLCHAIN/gcc"

CLANG_DIR="$PREBUILTS/clang/host/linux-x86/$CLANG_VERSION"
GCC_DIR="$PREBUILTS/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"

OUT="$ROOT/out"
ARTIFACTS="$ROOT/artifacts"
BOOT="$OUT/arch/arm64/boot"

ARCH=arm64
JOBS="$(nproc)"

# ==================================================
# ERROR HANDLER
# ==================================================

trap 'echo; echo "ERROR: Failed at line $LINENO"; exit 1' ERR

# ==================================================
# DOWNLOAD MODE MENU
# ==================================================

echo
echo "=========================================="
echo "       CAMELLIAN OSS KERNEL BUILDER"
echo "=========================================="
echo
echo "[1] Shallow Clone (Less download)"
echo "[2] Normal Clone  (Full history)"
echo

while true; do
    read -rp "Select download mode [1/2]: " MODE

    case "$MODE" in
        1)
            SHALLOW=1
            echo "Selected: SHALLOW CLONE"
            break
            ;;
        2)
            SHALLOW=0
            echo "Selected: NORMAL CLONE"
            break
            ;;
        *)
            echo "Invalid selection. Choose 1 or 2."
            ;;
    esac
done

# ==================================================
# DEFCONFIG MENU
# ==================================================

DEFCONFIGS=(
    camellian_defconfig
    camellian_debug_defconfig
    camellian_gl_defconfig
    camellian_gl_debug_defconfig
    camellian_id_defconfig
    camellian_id_debug_defconfig
    camellian_in_eea_defconfig
    camellian_in_eea_debug_defconfig
    camellian_ru_defconfig
    camellian_ru_debug_defconfig
    camellian_tr_defconfig
    camellian_tr_debug_defconfig
)

echo
echo "=========================================="
echo "             SELECT DEFCONFIG"
echo "=========================================="

for i in "${!DEFCONFIGS[@]}"; do
    printf " [%2d] %s\n" "$((i+1))" "${DEFCONFIGS[$i]}"
done

echo

while true; do
    read -rp "Select defconfig [1-12, default 1]: " D

    D="${D:-1}"

    if [[ "$D" =~ ^[0-9]+$ ]] &&
       (( D >= 1 && D <= ${#DEFCONFIGS[@]} )); then
        DEFCONFIG="${DEFCONFIGS[$((D-1))]}"
        break
    fi

    echo "Invalid selection."
done

# ==================================================
# DIRECTORY SETUP
# ==================================================

echo
echo "=== CREATING DIRECTORIES ==="

mkdir -p \
    "$TOOLCHAIN" \
    "$PREBUILTS" \
    "$OUT" \
    "$ARTIFACTS"

# ==================================================
# SUDO SUPPORT
# ==================================================

if [ "$(id -u)" -eq 0 ]; then
    SUDO=()
else
    SUDO=(sudo)
fi

# ==================================================
# DEPENDENCIES
# ==================================================

echo
echo "=== CHECKING DEPENDENCIES ==="

if command -v apt-get >/dev/null 2>&1; then

    PACKAGES=(
        bc
        bison
        build-essential
        ccache
        curl
        flex
        git
        libelf-dev
        libssl-dev
        libncurses-dev
        lld
        make
        python3
        rsync
        unzip
        zip
        device-tree-compiler
        gcc
        g++
        lz4
    )

    echo "Updating package lists..."

    "${SUDO[@]}" apt-get update

    echo "Installing required packages..."

    "${SUDO[@]}" apt-get install -y "${PACKAGES[@]}"

else
    echo "ERROR: apt-get not found."
    echo "Install dependencies manually."
    exit 1
fi

# ==================================================
# SYSTEM CHECK
# ==================================================

echo
echo "=== SYSTEM INFORMATION ==="

uname -a
echo "CPU threads: $JOBS"

AVAILABLE_GB="$(df -BG "$ROOT" | awk 'NR==2 {gsub(/G/,"",$4); print $4}')"

echo "Available disk: ${AVAILABLE_GB} GB"

if (( AVAILABLE_GB < 10 )); then
    echo "WARNING: Low disk space."
fi

# ==================================================
# GIT HELPER
# ==================================================

git_download() {
    local REPO="$1"
    local DEST="$2"
    local REF="$3"

    if [ ! -d "$DEST/.git" ]; then

        echo "Cloning: $REPO"

        mkdir -p "$(dirname "$DEST")"

        if [ "$SHALLOW" -eq 1 ]; then

            git clone \
                --depth=1 \
                --single-branch \
                --no-tags \
                --branch "$REF" \
                "$REPO" "$DEST"

        else

            git clone \
                --branch "$REF" \
                "$REPO" "$DEST"

        fi

    else

        echo "Repository exists: $DEST"

        if [ "$SHALLOW" -eq 1 ]; then

            git -C "$DEST" fetch \
                --depth=1 \
                --no-tags \
                origin "$REF"

        else

            if [ "$(git -C "$DEST" rev-parse --is-shallow-repository)" = "true" ]; then
                git -C "$DEST" fetch --unshallow origin
            else
                git -C "$DEST" fetch origin
            fi

            git -C "$DEST" fetch origin "$REF"

        fi

        git -C "$DEST" checkout --detach FETCH_HEAD

    fi
}

# ==================================================
# CLANG DOWNLOAD
# ==================================================

echo
echo "=========================================="
echo "             CLANG TOOLCHAIN"
echo "=========================================="

if [ -x "$CLANG_DIR/bin/clang" ] &&
   [ -x "$CLANG_DIR/bin/ld.lld" ]; then

    echo "Clang already exists. Skipping download."

else

    echo "Clang toolchain missing. Downloading..."

    if [ ! -d "$CLANG_SRC/.git" ]; then

        mkdir -p "$CLANG_SRC"

        git init "$CLANG_SRC"
        git -C "$CLANG_SRC" remote add origin "$CLANG_REPO"

    fi

    if [ "$SHALLOW" -eq 1 ]; then

        git -C "$CLANG_SRC" fetch \
            --depth=1 \
            --no-tags \
            origin "$CLANG_COMMIT"

    else

        if [ "$(git -C "$CLANG_SRC" rev-parse --is-shallow-repository)" = "true" ]; then
            git -C "$CLANG_SRC" fetch --unshallow origin
        else
            git -C "$CLANG_SRC" fetch origin
        fi

        git -C "$CLANG_SRC" fetch origin "$CLANG_COMMIT"

    fi

    git -C "$CLANG_SRC" checkout --detach FETCH_HEAD

    test -d "$CLANG_SRC/$CLANG_VERSION"

    mkdir -p "$(dirname "$CLANG_DIR")"

    TEMP_CLANG="${CLANG_DIR}.tmp"

    rm -rf "$TEMP_CLANG"

    cp -a "$CLANG_SRC/$CLANG_VERSION" "$TEMP_CLANG"

    test -x "$TEMP_CLANG/bin/clang"
    test -x "$TEMP_CLANG/bin/ld.lld"

    rm -rf "$CLANG_DIR"
    mv "$TEMP_CLANG" "$CLANG_DIR"

fi

# ==================================================
# GCC DOWNLOAD
# ==================================================

echo
echo "=========================================="
echo "              GCC TOOLCHAIN"
echo "=========================================="

if [ -x "$GCC_DIR/bin/aarch64-linux-androidkernel-gcc" ]; then

    echo "GCC already exists. Skipping download."

else

    echo "GCC toolchain missing. Downloading..."

    git_download "$GCC_REPO" "$GCC_SRC" "$GCC_BRANCH"

    test -x "$GCC_SRC/bin/aarch64-linux-androidkernel-gcc"

    mkdir -p "$(dirname "$GCC_DIR")"

    TEMP_GCC="${GCC_DIR}.tmp"

    rm -rf "$TEMP_GCC"

    cp -a "$GCC_SRC" "$TEMP_GCC"

    test -x "$TEMP_GCC/bin/aarch64-linux-androidkernel-gcc"

    rm -rf "$GCC_DIR"
    mv "$TEMP_GCC" "$GCC_DIR"

fi

# ==================================================
# TOOLCHAIN SETUP
# ==================================================

echo
echo "=== TOOLCHAIN SETUP ==="

CLANG_BIN="$CLANG_DIR/bin"
GCC_BIN="$GCC_DIR/bin"

chmod +x "$CLANG_BIN/clang"

export PATH="$CLANG_BIN:$GCC_BIN:$PATH"
export LD_LIBRARY_PATH="$CLANG_DIR/lib64:${LD_LIBRARY_PATH:-}"

for TOOL in \
    clang \
    ld.lld \
    llvm-nm \
    llvm-objcopy \
    llvm-ar \
    llvm-objdump \
    llvm-strip
do

    command -v "$TOOL" >/dev/null 2>&1 || {
        echo "ERROR: Missing tool: $TOOL"
        exit 1
    }

done

test -x "$GCC_BIN/aarch64-linux-androidkernel-gcc"

echo
echo "=== CLANG VERSION ==="
clang --version

echo
echo "=== LLD VERSION ==="
ld.lld --version

echo
echo "=== GCC VERSION ==="
aarch64-linux-androidkernel-gcc --version

# ==================================================
# KERNEL VALIDATION
# ==================================================

echo
echo "=== KERNEL SOURCE VALIDATION ==="

grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)' Makefile

VERSION="$(awk '$1=="VERSION" {print $3; exit}' Makefile)"
PATCHLEVEL="$(awk '$1=="PATCHLEVEL" {print $3; exit}' Makefile)"
SUBLEVEL="$(awk '$1=="SUBLEVEL" {print $3; exit}' Makefile)"

if [ "$VERSION.$PATCHLEVEL.$SUBLEVEL" != "4.14.186" ]; then
    echo "ERROR: Expected kernel 4.14.186"
    exit 1
fi

echo "Kernel version verified: 4.14.186"

test -f "arch/arm64/configs/$DEFCONFIG"

echo "Selected defconfig: $DEFCONFIG"

# ==================================================
# BUILD CONFIGURATION
# ==================================================

CROSS_COMPILE="$GCC_BIN/aarch64-linux-androidkernel-"

BUILD_ARGS=(
    -j"$JOBS"
    O=out
    ARCH=arm64
    CC=clang
    LD=ld.lld
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    AR=llvm-ar
    OBJDUMP=llvm-objdump
    STRIP=llvm-strip
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE="$CROSS_COMPILE"
)

# ==================================================
# GENERATE CONFIG
# ==================================================

echo
echo "=========================================="
echo "           GENERATING CONFIG"
echo "=========================================="

make "${BUILD_ARGS[@]}" "$DEFCONFIG"

test -f "$OUT/.config"

# ==================================================
# BUILD KERNEL
# ==================================================

echo
echo "=========================================="
echo "             BUILDING KERNEL"
echo "=========================================="

START_TIME="$(date +%s)"

set -o pipefail

make "${BUILD_ARGS[@]}" Image.gz-dtb 2>&1 | tee build.log

END_TIME="$(date +%s)"
DURATION=$((END_TIME - START_TIME))

# ==================================================
# OUTPUT VALIDATION
# ==================================================

echo
echo "=========================================="
echo "             BUILD OUTPUT"
echo "=========================================="

test -f "$BOOT/Image" || {
    echo "ERROR: Image not found."
    exit 1
}

mkdir -p "$ARTIFACTS"

cp -f "$BOOT/Image" "$ARTIFACTS/"

for FILE in Image.gz Image.gz-dtb; do
    if [ -f "$BOOT/$FILE" ]; then
        cp -f "$BOOT/$FILE" "$ARTIFACTS/"
    fi
done

# ==================================================
# BUILD INFORMATION
# ==================================================

cat > "$ARTIFACTS/build-info.txt" <<EOF
Kernel Version: 4.14.186
Architecture: arm64
Defconfig: $DEFCONFIG
Download Mode: $([ "$SHALLOW" -eq 1 ] && echo Shallow || echo Normal)
Clang: $CLANG_VERSION
GCC: Android GCC 4.9
Build Date: $(date)
Build Duration: ${DURATION}s
EOF

# ==================================================
# FINAL REPORT
# ==================================================

echo
echo "=========================================="
echo "          BUILD SUCCESSFUL"
echo "=========================================="

echo
echo "Defconfig: $DEFCONFIG"
echo "Kernel: 4.14.186"
echo "Build time: ${DURATION}s"

echo
echo "=== ARTIFACTS ==="

ls -lh "$ARTIFACTS"

echo
echo "Output directory:"
echo "$ARTIFACTS"

echo
echo "=========================================="
