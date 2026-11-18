#!/usr/bin/env bash
#
# build-oss-kernel.sh — local mirror of the "build oss kernel" GitHub Actions workflow.
#
#   * Installs apt build dependencies (skippable)
#   * Shallow-clones clang-r383902 from msft-mirror-aosp (sparse: only that folder)
#   * Shallow-clones LineageOS gcc 4.9 (aarch64)
#   * Symlinks (default) or copies toolchains into prebuilts/
#   * Runs `make O=out ARCH=arm64 CC=clang ... Image Image.gz`
#
# Usage:
#   ./build-oss-kernel.sh                        # interactive defconfig picker
#   ./build-oss-kernel.sh <defconfig>            # non-interactive
#   ./build-oss-kernel.sh --list                 # show available defconfigs
#
# Options:
#   --clean              Remove toolchain-src/ and prebuilts/ after build
#   --clean-before       Remove toolchain caches before fetching
#   --skip-deps          Do not attempt to install apt packages
#   --copy-toolchains    Copy prebuilts instead of symlinking
#   --list               Print available defconfigs and exit
#   -h, --help           Show this help
#
# Env:
#   KERNEL_ROOT          Kernel source dir (default: $PWD)
#   OUT_DIR              Make O= directory (default: out)
#   DEFCONFIG            Skip prompt by pre-selecting a defconfig
#   SKIP_DEPS=1          Same as --skip-deps
#   COPY_TOOLCHAINS=1    Same as --copy-toolchains
#   CLANG_VERSION        default: clang-r383902
#   CLANG_COMMIT         default: 4114ce222c83ba93e9c12c91c6ced2541b28f88c
#   GCC_REPO_REF         default: lineage-19.1
#
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

# Available defconfigs (debug variants intentionally excluded)
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
log()  { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[build]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[build]\033[0m %s\n' "$*" >&2; exit 1; }

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
    -h|--help)         usage; exit 0 ;;
    --list)            SHOW_LIST=1; shift ;;
    --clean)           CLEAN=1; shift ;;
    --clean-before)    CLEAN_BEFORE=1; shift ;;
    --skip-deps)       SKIP_DEPS=1; shift ;;
    --copy-toolchains) COPY_TOOLCHAINS=1; shift ;;
    --)                shift; POSITIONAL+=("$@"); break ;;
    -*)                die "Unknown option: $1 (use --help)" ;;
    *)                 POSITIONAL+=("$1"); shift ;;
  esac
done

[ "$SHOW_LIST" = "1" ] && { list_defconfigs; exit 0; }

# ------------------------------------------------------------------------------
# Defconfig resolution (in order): positional arg > DEFCONFIG env > prompt
# ------------------------------------------------------------------------------
resolve_defconfig() {
  # 1) Positional
  if [ ${#POSITIONAL[@]} -gt 0 ]; then
    DEFCONFIG="${POSITIONAL[0]}"
    [ ${#POSITIONAL[@]} -gt 1 ] && warn "Extra positional args ignored: ${POSITIONAL[*]:1}"
    return
  fi

  # 2) Env
  if [ -n "${DEFCONFIG:-}" ]; then
    return
  fi

  # 3) Prompt (only if we have a terminal)
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    die "No defconfig provided and no TTY to prompt on.
  Use:  ./build-oss-kernel.sh <defconfig>
  Or:   DEFCONFIG=<defconfig> ./build-oss-kernel.sh
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
      warn "Out of range 1-${#AVAILABLE_DEFCONFIGS[@]} — try again."
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
[ -f "$KERNEL_ROOT/Makefile" ] || die "No Makefile in $KERNEL_ROOT — run from the kernel source root or set KERNEL_ROOT."
[ -f "$KERNEL_ROOT/arch/arm64/configs/$DEFCONFIG" ] \
  || die "Defconfig not found: arch/arm64/configs/$DEFCONFIG
  Available in source tree:
$(ls -1 "$KERNEL_ROOT/arch/arm64/configs" 2>/dev/null | sed 's/^/    /' || true)"

command -v git  >/dev/null || die "git is required"
command -v make >/dev/null || die "make is required"

cd "$KERNEL_ROOT"

# ------------------------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------------------------
install_deps() {
  if [ "$SKIP_DEPS" = "1" ]; then
    log "Skipping dependency install (--skip-deps / SKIP_DEPS=1)"
    return
  fi

  local required=(bc bison flex make python3 rsync dtc unzip zip gcc g++ lz4 git curl)
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
    || die "apt-get not available — please install manually: ${missing[*]}"

  local sudo=""
  if [ "$(id -u)" -ne 0 ]; then
    command -v sudo >/dev/null 2>&1 || die "Need sudo (or root) to install packages"
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
# Toolchain fetch (shallow + sparse)
# ------------------------------------------------------------------------------
fetch_clang() {
  local dest="$TOOLCHAIN_SRC/clang"

  if [ -x "$dest/$CLANG_VERSION/bin/clang" ]; then
    log "clang $CLANG_VERSION already cached in $dest"
    return
  fi

  log "Fetching clang $CLANG_VERSION (shallow + sparse)…"
  rm -rf "$dest"
  mkdir -p "$TOOLCHAIN_SRC"

  git clone --depth 1 --filter=blob:none --sparse \
    "$CLANG_REPO" "$dest"

  (
    cd "$dest"
    git sparse-checkout set "$CLANG_VERSION"
    git fetch --depth 1 origin "$CLANG_COMMIT"
    git reset --hard FETCH_HEAD
  ) || die "Failed to fetch clang $CLANG_VERSION"

  [ -x "$dest/$CLANG_VERSION/bin/clang" ] \
    || die "clang binary missing after checkout: $dest/$CLANG_VERSION/bin/clang"
}

fetch_gcc() {
  local dest="$TOOLCHAIN_SRC/gcc"

  if [ -x "$dest/bin/aarch64-linux-androidkernel-gcc" ]; then
    log "gcc 4.9 already cached in $dest"
    return
  fi

  log "Fetching Android GCC 4.9 ($GCC_REPO_REF, shallow)…"
  rm -rf "$dest"
  mkdir -p "$TOOLCHAIN_SRC"

  git clone --depth 1 --branch "$GCC_REPO_REF" "$GCC_REPO" "$dest" \
    || die "Failed to fetch gcc"

  [ -x "$dest/bin/aarch64-linux-androidkernel-gcc" ] \
    || die "aarch64-linux-androidkernel-gcc missing in $dest/bin"
}

# ------------------------------------------------------------------------------
# Prebuilts layout
# ------------------------------------------------------------------------------
setup_prebuilts() {
  mkdir -p "$PREBUILTS/clang/host/linux-x86"
  mkdir -p "$PREBUILTS/gcc/linux-x86/aarch64"

  if [ ! -d "$CLANG_PREBUILT/bin" ]; then
    rm -f "$CLANG_PREBUILT"
    if [ "$COPY_TOOLCHAINS" = "1" ]; then
      log "Copying clang prebuilt (large)…"
      cp -a "$TOOLCHAIN_SRC/clang/$CLANG_VERSION" "$CLANG_PREBUILT"
    else
      log "Symlinking clang prebuilt"
      ln -s "$TOOLCHAIN_SRC/clang/$CLANG_VERSION" "$CLANG_PREBUILT"
    fi
  fi

  if [ ! -d "$GCC_PREBUILT/bin" ]; then
    rm -f "$GCC_PREBUILT"
    if [ "$COPY_TOOLCHAINS" = "1" ]; then
      log "Copying gcc prebuilt"
      cp -a "$TOOLCHAIN_SRC/gcc" "$GCC_PREBUILT"
    else
      log "Symlinking gcc prebuilt"
      ln -s "$TOOLCHAIN_SRC/gcc" "$GCC_PREBUILT"
    fi
  fi

  chmod +x "$CLANG_PREBUILT/bin/clang" 2>/dev/null || true

  test -x "$CLANG_PREBUILT/bin/clang"                         || die "clang missing"
  test -x "$CLANG_PREBUILT/bin/ld.lld"                        || die "ld.lld missing"
  test -x "$GCC_PREBUILT/bin/aarch64-linux-androidkernel-gcc" || die "gcc kernel bin missing"

  log "Toolchain summary"
  "$CLANG_PREBUILT/bin/clang" --version | head -n1
  "$CLANG_PREBUILT/bin/ld.lld" --version | head -n1
  "$GCC_PREBUILT/bin/aarch64-linux-androidkernel-gcc" --version | head -n1
}

# ------------------------------------------------------------------------------
# Build
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

  log "Generating config: $DEFCONFIG"
  make "${build_args[@]}" "$DEFCONFIG"

  log "Building Image Image.gz (log: build.log)"
  make "${build_args[@]}" Image Image.gz 2>&1 | tee build.log

  log "Build artifacts:"
  find "$OUT_DIR/arch/arm64/boot" -maxdepth 2 -type f -printf '  %p (%s bytes)\n' 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------------------------
clean_toolchains() {
  log "Removing toolchain caches (toolchain-src/, prebuilts/)"
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

  [ "$CLEAN_BEFORE" = "1" ] && clean_toolchains

  install_deps
  fetch_clang
  fetch_gcc
  setup_prebuilts
  build_kernel

  [ "$CLEAN" = "1" ] && clean_toolchains

  log "Done."
  log "Kernel image(s):"
  for f in Image Image.gz; do
    p="$OUT_DIR/arch/arm64/boot/$f"
    [ -f "$p" ] && log "  $p"
  done
}

main
