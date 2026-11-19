#!/usr/bin/env bash
#
# build-oss-kernel.sh
#
# Local mirror of the build OSS kernel workflow.
#
# Usage:
#   ./build-oss-kernel.sh
#   ./build-oss-kernel.sh camellian_gl_defconfig
#   ./build-oss-kernel.sh --list
#
# Options:
#   --clean
#   --clean-before
#   --skip-deps
#   --copy-toolchains
#   --list
#   -h, --help
#
# Environment:
#   KERNEL_ROOT
#   OUT_DIR
#   DEFCONFIG
#   SKIP_DEPS=1
#   COPY_TOOLCHAINS=1
#   CLANG_VERSION
#   CLANG_COMMIT
#   GCC_REPO_REF

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

KERNEL_ROOT="${KERNEL_ROOT:-$PWD}"
OUT_DIR="${OUT_DIR:-out}"

CLANG_VERSION="${CLANG_VERSION:-clang-r383902}"
CLANG_COMMIT="${CLANG_COMMIT:-4114ce222c83ba93e9c12c91c6ced2541b28f88c}"
GCC_REPO_REF="${GCC_REPO_REF:-lineage-19.1}"

CLANG_REPO="https://github.com/msft-mirror-aosp/platform.prebuilts.clang.host.linux-x86"
GCC_REPO="https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9"

TOOLCHAIN_SRC="$KERNEL_ROOT/toolchain-src"
PREBUILTS="$KERNEL_ROOT/prebuilts"

CLANG_PREBUILT="$PREBUILTS/clang/host/linux-x86/$CLANG_VERSION"
GCC_PREBUILT="$PREBUILTS/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"

CLEAN="${CLEAN:-0}"
CLEAN_BEFORE="${CLEAN_BEFORE:-0}"
SKIP_DEPS="${SKIP_DEPS:-0}"
COPY_TOOLCHAINS="${COPY_TOOLCHAINS:-0}"
SHOW_LIST="${SHOW_LIST:-0}"

AVAILABLE_DEFCONFIGS=(
    camellian_defconfig
    camellian_gl_defconfig
    camellian_id_defconfig
    camellian_in_eea_defconfig
    camellian_ru_defconfig
    camellian_tr_defconfig
)

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

log() {
    printf '\033[1;34m[build]\033[0m %s\n' "$*"
}

warn() {
    printf '\033[1;33m[build]\033[0m %s\n' "$*" >&2
}

die() {
    printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2
    exit 1
}

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
}

list_defconfigs() {
    printf '%s\n' "${AVAILABLE_DEFCONFIGS[@]}"
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------

POSITIONAL=()

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --list)
            SHOW_LIST=1
            shift
            ;;
        --clean)
            CLEAN=1
            shift
            ;;
        --clean-before)
            CLEAN_BEFORE=1
            shift
            ;;
        --skip-deps)
            SKIP_DEPS=1
            shift
            ;;
        --copy-toolchains)
            COPY_TOOLCHAINS=1
            shift
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            die "Unknown option: $1 (use --help)"
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

if [ "$SHOW_LIST" = "1" ]; then
    list_defconfigs
    exit 0
fi

# ------------------------------------------------------------------------------
# Defconfig resolution
# ------------------------------------------------------------------------------

resolve_defconfig() {

    if [ ${#POSITIONAL[@]} -gt 0 ]; then
        DEFCONFIG="${POSITIONAL[0]}"

        if [ ${#POSITIONAL[@]} -gt 1 ]; then
            warn "Extra positional args ignored: ${POSITIONAL[*]:1}"
        fi

        return
    fi

    if [ -n "${DEFCONFIG:-}" ]; then
        return
    fi

    if [ ! -t 0 ] || [ ! -t 1 ]; then
        die "No defconfig provided and no TTY to prompt on.
Use: ./build-oss-kernel.sh <defconfig>
Or: DEFCONFIG=<defconfig> ./build-oss-kernel.sh
List: ./build-oss-kernel.sh --list"
    fi

    printf '\n\033[1;34m[build]\033[0m Select a defconfig:\n\n'

    local i=1

    for d in "${AVAILABLE_DEFCONFIGS[@]}"; do
        printf '  \033[1;36m%2d)\033[0m %s\n' "$i" "$d"
        i=$((i + 1))
    done

    printf '\n'

    local choice

    while :; do
        read -r -p "Choice [1-${#AVAILABLE_DEFCONFIGS[@]}] (default 1): " choice

        choice="${choice:-1}"

        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            warn "Not a number — try again."
            continue
        fi

        if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#AVAILABLE_DEFCONFIGS[@]}" ]; then
            warn "Out of range — try again."
            continue
        fi

        DEFCONFIG="${AVAILABLE_DEFCONFIGS[$((choice - 1))]}"
        break
    done

    printf '\n'
    log "Selected defconfig: $DEFCONFIG"
}

resolve_defconfig

# ------------------------------------------------------------------------------
# Sanity checks
# ------------------------------------------------------------------------------

[ -f "$KERNEL_ROOT/Makefile" ] \
    || die "No Makefile in $KERNEL_ROOT"

[ -f "$KERNEL_ROOT/arch/arm64/configs/$DEFCONFIG" ] \
    || die "Defconfig not found: $DEFCONFIG"

command -v git >/dev/null 2>&1 || die "git is required"
command -v make >/dev/null 2>&1 || die "make is required"

cd "$KERNEL_ROOT"

# ------------------------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------------------------

install_deps() {

    if [ "$SKIP_DEPS" = "1" ]; then
        log "Skipping dependency installation"
        return
    fi

    local required=(
        bc bison flex make python3 rsync
        dtc unzip zip gcc g++ lz4 git curl
    )

    local missing=()

    for c in "${required[@]}"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        log "All build dependencies present"
        return
    fi

    log "Installing missing dependencies: ${missing[*]}"

    command -v apt-get >/dev/null 2>&1 \
        || die "apt-get not available"

    local sudo=""

    if [ "$(id -u)" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 \
            || die "Need sudo or root"

        sudo="sudo"
    fi

    $sudo apt-get update

    $sudo apt-get install -y \
        bc bison build-essential ccache \
        curl flex git libelf-dev libssl-dev \
        libncurses-dev lld make \
        python3 rsync unzip zip \
        device-tree-compiler \
        gcc g++ liblz4-tool
}

# ------------------------------------------------------------------------------
# Fetch Clang
# ------------------------------------------------------------------------------

fetch_clang() {

    local dest="$TOOLCHAIN_SRC/clang"

    if [ -x "$dest/$CLANG_VERSION/bin/clang" ]; then
        log "Clang already cached"
        return
    fi

    log "Fetching Clang $CLANG_VERSION"

    rm -rf "$dest"
    mkdir -p "$TOOLCHAIN_SRC"

    git clone --depth 1 --filter=blob:none --sparse \
        "$CLANG_REPO" "$dest"

    (
        cd "$dest"

        git sparse-checkout set "$CLANG_VERSION"

        git fetch --depth 1 origin "$CLANG_COMMIT"

        git reset --hard FETCH_HEAD
    ) || die "Failed to fetch Clang"

    [ -x "$dest/$CLANG_VERSION/bin/clang" ] \
        || die "Clang binary missing"
}

# ------------------------------------------------------------------------------
# Fetch GCC
# ------------------------------------------------------------------------------

fetch_gcc() {

    local dest="$TOOLCHAIN_SRC/gcc"

    if [ -x "$dest/bin/aarch64-linux-androidkernel-gcc" ]; then
        log "GCC already cached"
        return
    fi

    log "Fetching Android GCC 4.9"

    rm -rf "$dest"
    mkdir -p "$TOOLCHAIN_SRC"

    git clone --depth 1 --branch "$GCC_REPO_REF" \
        "$GCC_REPO" "$dest" \
        || die "Failed to fetch GCC"

    [ -x "$dest/bin/aarch64-linux-androidkernel-gcc" ] \
        || die "GCC kernel binary missing"
}

# ------------------------------------------------------------------------------
# Setup prebuilts
# ------------------------------------------------------------------------------

setup_prebuilts() {

    mkdir -p "$PREBUILTS/clang/host/linux-x86"
    mkdir -p "$PREBUILTS/gcc/linux-x86/aarch64"

    if [ ! -d "$CLANG_PREBUILT/bin" ]; then

        rm -f "$CLANG_PREBUILT"

        if [ "$COPY_TOOLCHAINS" = "1" ]; then
            log "Copying Clang"
            cp -a "$TOOLCHAIN_SRC/clang/$CLANG_VERSION" "$CLANG_PREBUILT"
        else
            log "Symlinking Clang"
            ln -s "$TOOLCHAIN_SRC/clang/$CLANG_VERSION" "$CLANG_PREBUILT"
        fi
    fi

    if [ ! -d "$GCC_PREBUILT/bin" ]; then

        rm -f "$GCC_PREBUILT"

        if [ "$COPY_TOOLCHAINS" = "1" ]; then
            log "Copying GCC"
            cp -a "$TOOLCHAIN_SRC/gcc" "$GCC_PREBUILT"
        else
            log "Symlinking GCC"
            ln -s "$TOOLCHAIN_SRC/gcc" "$GCC_PREBUILT"
        fi
    fi

    chmod +x "$CLANG_PREBUILT/bin/clang" 2>/dev/null || true

    test -x "$CLANG_PREBUILT/bin/clang" \
        || die "Clang missing"

    test -x "$CLANG_PREBUILT/bin/ld.lld" \
        || die "ld.lld missing"

    test -x "$GCC_PREBUILT/bin/aarch64-linux-androidkernel-gcc" \
        || die "GCC missing"

    log "Toolchain summary"

    "$CLANG_PREBUILT/bin/clang" --version | head -n1
    "$CLANG_PREBUILT/bin/ld.lld" --version | head -n1

    "$GCC_PREBUILT/bin/aarch64-linux-androidkernel-gcc" \
        --version | head -n1
}

# ------------------------------------------------------------------------------
# Build kernel
# ------------------------------------------------------------------------------

build_kernel() {

    local clang_dir="$CLANG_PREBUILT"
    local gcc_bin="$GCC_PREBUILT/bin"

    export PATH="$clang_dir/bin:$gcc_bin:$PATH"

    export LD_LIBRARY_PATH="$clang_dir/lib64:${LD_LIBRARY_PATH:-}"

    local cross_compile="$gcc_bin/aarch64-linux-androidkernel-"

    local build_args=(
        -j"$(nproc)"
        O="$OUT_DIR"
        ARCH=arm64
        CC=clang
        LD=ld.lld
        NM=llvm-nm
        OBJCOPY=llvm-objcopy
        AR=llvm-ar
        OBJDUMP=llvm-objdump
        STRIP=llvm-strip
        CLANG_TRIPLE=aarch64-linux-gnu-
        CROSS_COMPILE="$cross_compile"
    )

    # Generate configuration
    log "Generating config: $DEFCONFIG"

    make "${build_args[@]}" "$DEFCONFIG"

    # Build kernel images and DTBs
    log "Building Image, Image.gz, Image.gz-dtb and DTBs"

    make "${build_args[@]}" \
        Image \
        Image.gz \
        Image.gz-dtb \
        dtbs \
        2>&1 | tee build.log

    # Show generated artifacts
    log "Build artifacts:"

    find "$OUT_DIR/arch/arm64/boot" \
        -type f \
        \( \
            -name "Image" \
            -o -name "Image.gz" \
            -o -name "Image.gz-dtb" \
            -o -name "*.dtb" \
        \) \
        -printf '  %p (%s bytes)\n' 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------

clean_toolchains() {

    log "Removing toolchain caches"

    rm -rf "$TOOLCHAIN_SRC" "$PREBUILTS"
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {

    log "Kernel source : $KERNEL_ROOT"
    log "Defconfig     : $DEFCONFIG"
    log "Out dir       : $OUT_DIR"
    log "Clang         : $CLANG_VERSION @ ${CLANG_COMMIT:0:12}"

    if [ "$CLEAN_BEFORE" = "1" ]; then
        clean_toolchains
    fi

    install_deps
    fetch_clang
    fetch_gcc
    setup_prebuilts

    build_kernel

    if [ "$CLEAN" = "1" ]; then
        clean_toolchains
    fi

    log "Done."

    log "Kernel images:"

    for f in Image Image.gz Image.gz-dtb; do

        p="$OUT_DIR/arch/arm64/boot/$f"

        if [ -f "$p" ]; then
            log "  $p"
        fi
    done

    log "DTB files:"

    find "$OUT_DIR/arch/arm64/boot" \
        -type f -name "*.dtb" \
        -printf '  %p (%s bytes)\n' 2>/dev/null || true
}

main "$@"
