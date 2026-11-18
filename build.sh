#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

# ==========================================
# CONFIGURATION
# ==========================================

DEFCONFIG="${1:-camellian_id_defconfig}"
ARCH=arm64
CLANG_VERSION=clang-r383902

CLANG_REPO="https://github.com/msft-mirror-aosp/platform.prebuilts.clang.host.linux-x86.git"
CLANG_COMMIT="4114ce222c83ba93e9c12c91c6ced2541b28f88c"

GCC_REPO="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9.git"
GCC_BRANCH="lineage-19.1"

TOOLCHAIN="$ROOT/toolchain-src"
CLANG_SRC="$TOOLCHAIN/clang"
GCC_SRC="$TOOLCHAIN/gcc"

PREBUILTS="$ROOT/prebuilts"
CLANG_DIR="$PREBUILTS/clang/host/linux-x86/$CLANG_VERSION"
GCC_DIR="$PREBUILTS/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"

OUT="$ROOT/out"
ARTIFACTS="$ROOT/artifacts"

JOBS="$(nproc)"

# ==========================================
# ERROR HANDLER
# ==========================================

trap 'echo "ERROR: Build failed at line $LINENO"' ERR

echo "=========================================="
echo "       CAMELLIAN OSS KERNEL BUILDER"
echo "=========================================="

# ==========================================
# DEPENDENCIES
# ==========================================

if command -v apt-get >/dev/null 2>&1; then
    echo "=== CHECKING DEPENDENCIES ==="

    sudo apt-get update

    sudo apt-get install -y \
        bc bison build-essential ccache \
        curl flex git libelf-dev libssl-dev \
        libncurses-dev lld make \
        python3 rsync unzip zip \
        device-tree-compiler \
        gcc g++ liblz4-tool
fi

# ==========================================
# DIRECTORY SETUP
# ==========================================

mkdir -p "$TOOLCHAIN" "$PREBUILTS" "$OUT" "$ARTIFACTS"

# ==========================================
# DOWNLOAD CLANG
# ==========================================

if [ -x "$CLANG_DIR/bin/clang" ] &&
   [ -x "$CLANG_DIR/bin/ld.lld" ]; then

    echo "=== CLANG ALREADY EXISTS: SKIPPING ==="

else
    echo "=== DOWNLOADING CLANG ==="

    mkdir -p "$CLANG_SRC"

    if [ ! -d "$CLANG_SRC/.git" ]; then
        git clone "$CLANG_REPO" "$CLANG_SRC"
    fi

    git -C "$CLANG_SRC" fetch --depth=1 origin "$CLANG_COMMIT"

    git -C "$CLANG_SRC" checkout --detach FETCH_HEAD

    mkdir -p "$(dirname "$CLANG_DIR")"

    rm -rf "$CLANG_DIR"

    cp -a "$CLANG_SRC/$CLANG_VERSION" "$CLANG_DIR"
fi

# ==========================================
# DOWNLOAD GCC
# ==========================================

if [ -x "$GCC_DIR/bin/aarch64-linux-androidkernel-gcc" ]; then

    echo "=== GCC ALREADY EXISTS: SKIPPING ==="

else
    echo "=== DOWNLOADING GCC ==="

    mkdir -p "$GCC_SRC"

    if [ ! -d "$GCC_SRC/.git" ]; then
        git clone --depth=1 --branch "$GCC_BRANCH" \
            "$GCC_REPO" "$GCC_SRC"
    else
        git -C "$GCC_SRC" fetch --depth=1 origin "$GCC_BRANCH"
        git -C "$GCC_SRC" checkout FETCH_HEAD
    fi

    mkdir -p "$(dirname "$GCC_DIR")"

    rm -rf "$GCC_DIR"

    cp -a "$GCC_SRC/." "$GCC_DIR/"
fi

# ==========================================
# TOOLCHAIN SETUP
# ==========================================

CLANG_BIN="$CLANG_DIR/bin"
GCC_BIN="$GCC_DIR/bin"

chmod +x "$CLANG_BIN/clang"

export PATH="$CLANG_BIN:$GCC_BIN:$PATH"
export LD_LIBRARY_PATH="$CLANG_DIR/lib64:${LD_LIBRARY_PATH:-}"

for TOOL in clang ld.lld llvm-nm llvm-objcopy llvm-ar \
            llvm-objdump llvm-strip; do
    command -v "$TOOL" >/dev/null 2>&1 || {
        echo "Missing tool: $TOOL"
        exit 1
    }
done

test -x "$GCC_BIN/aarch64-linux-androidkernel-gcc"

# ==========================================
# VERIFY
# ==========================================

echo "=== KERNEL VERSION ==="

grep -E '^(VERSION|PATCHLEVEL|SUBLEVEL|EXTRAVERSION)' Makefile

echo "=== DEFCONFIG ==="

test -f "arch/arm64/configs/$DEFCONFIG"
echo "$DEFCONFIG"

echo "=== CLANG ==="
clang --version

echo "=== GCC ==="
aarch64-linux-androidkernel-gcc --version

# ==========================================
# BUILD CONFIGURATION
# ==========================================

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

# ==========================================
# GENERATE CONFIG
# ==========================================

echo "=== GENERATING CONFIG ==="

make "${BUILD_ARGS[@]}" "$DEFCONFIG"

# ==========================================
# BUILD KERNEL
# ==========================================

echo "=== BUILDING KERNEL ==="

make "${BUILD_ARGS[@]}" Image.gz-dtb 2>&1 | tee build.log

# ==========================================
# ARTIFACTS
# ==========================================

BOOT="$OUT/arch/arm64/boot"

for FILE in Image Image.gz Image.gz-dtb; do
    if [ -f "$BOOT/$FILE" ]; then
        cp -f "$BOOT/$FILE" "$ARTIFACTS/"
    fi
done

echo "=========================================="
echo "           BUILD SUCCESSFUL"
echo "=========================================="

ls -lh "$ARTIFACTS"