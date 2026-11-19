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
  local missing_pkgs=()

  declare -A DEP_MAP=(
    [bc]="bc"
    [bison]="bison"
    [flex]="flex"
    [git]="git"
    [make]="make"
    [python3]="python3"
    [rsync]="rsync"
    [zip]="zip"
    [curl]="curl"
    [lz4]="liblz4-tool"
    [dtc]="device-tree-compiler"
  )

  for cmd in "${!DEP_MAP[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      warn "Missing command: $cmd (package: ${DEP_MAP[$cmd]})"
      missing_pkgs+=("${DEP_MAP[$cmd]}")
    fi
  done

  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    local unique_pkgs
    mapfile -t unique_pkgs < <(printf '%s\n' "${missing_pkgs[@]}" | sort -u)
    info "Installing: ${unique_pkgs[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y \
      bc bison build-essential ccache curl flex \
      git libelf-dev libssl-dev libncurses-dev lld make \
      python3 rsync unzip zip device-tree-compiler \
      gcc g++ liblz4-tool
  fi

  success "Dependencies OK"
}

# ─── Clang setup ──────────────────────────────────────────
setup_clang() {
  if [[ -f "$CLANG_DIR/bin/clang" ]]; then
    success "Clang already exists, skipping"
    return
  fi

  info "Cloning Clang (shallow, sparse)..."

  local CLANG_SRC="$TOOLCHAIN_DIR/clang"
  rm -rf "$CLANG_SRC"
  mkdir -p "$CLANG_SRC"

  git clone \
    --filter=blob:none \
    --no-checkout \
    --depth=1 \
    --sparse \
    https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
    "$CLANG_SRC"

  git -C "$CLANG_SRC" sparse-checkout init --cone
  git -C "$CLANG_SRC" sparse-checkout set "$CLANG_VERSION"
  git -C "$CLANG_SRC" checkout

  # Fallback: full subtree checkout
  if [[ ! -d "$CLANG_SRC/$CLANG_VERSION" ]]; then
    warn "Sparse checkout failed, trying fallback..."
    rm -rf "$CLANG_SRC"
    mkdir -p "$CLANG_SRC"
    git clone \
      --filter=blob:none \
      --no-checkout \
      https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
      "$CLANG_SRC"
    git -C "$CLANG_SRC" checkout HEAD -- "$CLANG_VERSION"
  fi

  [[ -d "$CLANG_SRC/$CLANG_VERSION" ]] || error "Clang source dir missing after clone!"

  mkdir -p "$(dirname "$CLANG_DIR")"
  cp -a "$CLANG_SRC/$CLANG_VERSION/." "$CLANG_DIR/"

  [[ -f "$CLANG_DIR/bin/clang" ]] || error "Clang binary missing after copy!"
  success "Clang ready → $CLANG_DIR"
}

# ─── GCC setup ────────────────────────────────────────────
setup_gcc() {
  if [[ -f "$GCC_DIR/bin/aarch64-linux-androidkernel-gcc" ]]; then
    success "GCC already exists, skipping"
    return
  fi

  info "Cloning GCC (shallow)..."

  local GCC_SRC="$TOOLCHAIN_DIR/gcc"
  rm -rf "$GCC_SRC"
  mkdir -p "$GCC_SRC"

  git clone \
    --depth=1 \
    --branch lineage-19.1 \
    https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 \
    "$GCC_SRC"

  [[ -d "$GCC_SRC/bin" ]] || error "GCC source bin dir missing!"

  mkdir -p "$GCC_DIR"
  cp -a "$GCC_SRC/." "$GCC_DIR/"

  [[ -f "$GCC_DIR/bin/aarch64-linux-androidkernel-gcc" ]] || error "GCC binary missing after copy!"
  success "GCC ready → $GCC_DIR"
}

# ─── Toolchain verify ─────────────────────────────────────
verify_toolchains() {
  local CLANG_BIN="$CLANG_DIR/bin"
  local GCC_BIN="$GCC_DIR/bin"

  chmod +x "$CLANG_BIN/clang"

  [[ -x "$CLANG_BIN/clang" ]]           || error "clang not executable"
  [[ -x "$CLANG_BIN/ld.lld" ]]          || error "ld.lld not executable"
  [[ -x "$GCC_BIN/aarch64-linux-androidkernel-gcc" ]] || error "gcc not executable"

  echo ""
  echo "=== Clang ===" && "$CLANG_BIN/clang" --version
  echo "=== LLD ===" && "$CLANG_BIN/ld.lld" --version
  echo "=== GCC ===" && "$GCC_BIN/aarch64-linux-androidkernel-gcc" --version
  echo ""
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

  info "Verifying defconfig exists..."
  [[ -f "$SCRIPT_DIR/arch/arm64/configs/$DEFCONFIG" ]] || \
    error "Defconfig not found: arch/arm64/configs/$DEFCONFIG"

  info "Generating config: $DEFCONFIG"
  make "${BUILD_ARGS[@]}" "$DEFCONFIG"

  info "Building kernel ($(nproc) threads)..."
  make "${BUILD_ARGS[@]}" Image.gz-dtb 2>&1 | tee build.log

  echo ""
  info "Build output:"
  find out/arch/arm64/boot -maxdepth 2 -type f 2>/dev/null | sort || \
    warn "No files found in out/arch/arm64/boot"

  # Collect artifacts
  local OUT_DIR="$SCRIPT_DIR/out_artifacts"
  mkdir -p "$OUT_DIR"

  local found=0
  for f in Image Image.gz Image.gz-dtb; do
    local src="out/arch/arm64/boot/$f"
    if [[ -f "$src" ]]; then
      cp "$src" "$OUT_DIR/"
      success "Saved: $OUT_DIR/$f"
      found=$((found+1))
    fi
  done

  [[ $found -gt 0 ]] || error "No kernel images found! Check build.log"
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

  mkdir -p "$TOOLCHAIN_DIR"
  mkdir -p "$(dirname "$CLANG_DIR")"
  mkdir -p "$GCC_DIR"

  setup_clang
  setup_gcc
  verify_toolchains
  build_kernel
}

main "$@"
