#!/usr/bin/env bash
# build_kernel.sh - Local kernel build script

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

# ─── Config ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLCHAIN_DIR="$SCRIPT_DIR/toolchain-src"
CLANG_VERSION="clang-r383902"
CLANG_DIR="$SCRIPT_DIR/prebuilts/clang/host/linux-x86/$CLANG_VERSION"
GCC_DIR="$SCRIPT_DIR/prebuilts/gcc/linux-x86/aarch64/aarch64-linux-android-4.9"

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

# ─── Defconfig picker ─────────────────────────────────────
pick_defconfig() {
  echo -e "\n${BOLD}Select defconfig:${NC}"
  for i in "${!DEFCONFIGS[@]}"; do
    printf "  ${CYAN}%2d)${NC} %s\n" "$((i+1))" "${DEFCONFIGS[$i]}"
  done
  echo ""

  while true; do
    read -rp "Enter number [1-${#DEFCONFIGS[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && \
       (( choice >= 1 && choice <= ${#DEFCONFIGS[@]} )); then
      DEFCONFIG="${DEFCONFIGS[$((choice-1))]}"
      success "Selected: $DEFCONFIG"
      break
    fi
    warn "Invalid choice, try again."
  done
}

# ─── Dependency check ─────────────────────────────────────
check_deps() {
  info "Checking dependencies..."
  local missing=()
  for cmd in bc bison flex git make python3 rsync zip curl lz4 dtc; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    warn "Missing: ${missing[*]}"
    info "Installing..."
    sudo apt-get update -qq
    sudo apt-get install -y bc bison build-essential ccache curl flex \
      git libelf-dev libssl-dev libncurses-dev lld make python3 \
      rsync unzip zip device-tree-compiler gcc g++ liblz4-tool
  fi
  success "Dependencies OK"
}

# ─── Toolchain setup (shallow clone) ──────────────────────
setup_toolchains() {
  mkdir -p "$TOOLCHAIN_DIR"

  # Clang
  if [[ ! -d "$CLANG_DIR" ]]; then
    info "Cloning Clang (shallow, sparse)..."
    mkdir -p "$TOOLCHAIN_DIR/clang"
    git clone \
      --depth=1 \
      --filter=blob:none \
      --sparse \
      https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
      "$TOOLCHAIN_DIR/clang"
    git -C "$TOOLCHAIN_DIR/clang" sparse-checkout set "$CLANG_VERSION"
    mkdir -p "$(dirname "$CLANG_DIR")"
    cp -a "$TOOLCHAIN_DIR/clang/$CLANG_VERSION" "$CLANG_DIR"
    success "Clang ready"
  else
    success "Clang already exists, skipping"
  fi

  # GCC
  if [[ ! -d "$GCC_DIR" ]]; then
    info "Cloning GCC (shallow)..."
    git clone \
      --depth=1 \
      https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 \
      --branch lineage-19.1 \
      "$TOOLCHAIN_DIR/gcc"
    mkdir -p "$GCC_DIR"
    cp -a "$TOOLCHAIN_DIR/gcc/." "$GCC_DIR/"
    success "GCC ready"
  else
    success "GCC already exists, skipping"
  fi

  # Verify
  local CLANG_BIN="$CLANG_DIR/bin"
  local GCC_BIN="$GCC_DIR/bin"

  chmod +x "$CLANG_BIN/clang"
  [[ -x "$CLANG_BIN/clang" ]]           || error "clang not found"
  [[ -x "$CLANG_BIN/ld.lld" ]]          || error "ld.lld not found"
  [[ -x "$GCC_BIN/aarch64-linux-androidkernel-gcc" ]] || error "gcc not found"

  echo -e "\n=== Clang ===" && "$CLANG_BIN/clang" --version
  echo "=== LLD ===" && "$CLANG_BIN/ld.lld" --version
  echo "=== GCC ===" && "$GCC_BIN/aarch64-linux-androidkernel-gcc" --version
}

# ─── Build ────────────────────────────────────────────────
build_kernel() {
  local CLANG_BIN="$CLANG_DIR/bin"
  local GCC_BIN="$GCC_DIR/bin"
  local CROSS_COMPILE="$GCC_BIN/aarch64-linux-androidkernel-"

  export PATH="$CLANG_BIN:$GCC_BIN:$PATH"
  export LD_LIBRARY_PATH="$CLANG_DIR/lib64:${LD_LIBRARY_PATH:-}"

  local BUILD_ARGS=(
    -j"$(nproc)"
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

  info "Generating config: $DEFCONFIG"
  make "${BUILD_ARGS[@]}" "$DEFCONFIG"

  info "Building Image.gz-dtb ($(nproc) threads)..."
  make "${BUILD_ARGS[@]}" Image.gz-dtb 2>&1 | tee build.log

  echo ""
  info "Build output:"
  find out/arch/arm64/boot -maxdepth 2 -type f | sort

  # Collect artifacts
  local OUT_DIR="$SCRIPT_DIR/out_artifacts"
  mkdir -p "$OUT_DIR"
  for f in Image Image.gz Image.gz-dtb; do
    local src="out/arch/arm64/boot/$f"
    [[ -f "$src" ]] && cp "$src" "$OUT_DIR/" && success "Saved: $OUT_DIR/$f"
  done

  success "Done! Artifacts in: $OUT_DIR"
}

# ─── Main ─────────────────────────────────────────────────
main() {
  cd "$SCRIPT_DIR"
  echo -e "${BOLD}╔══════════════════════════════╗${NC}"
  echo -e "${BOLD}║   Camellian Kernel Builder   ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════╝${NC}\n"

  pick_defconfig
  check_deps
  setup_toolchains
  build_kernel
}

main "$@"
