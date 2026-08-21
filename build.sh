#!/usr/bin/env bash
# build.sh — Build Levion kernel for Motorola E32s (MediaTek)
#
# Run './build.sh --help' (or '-h') for full usage and flag documentation.
#
# Expected directory layout:
#   /home/tony/moto/
#   ├── Motorola_E32s_Levion_kernel/     ← kernel source — script lives here
#   │   └── build.sh
#   ├── AnyKernel3/                      ← flashable template dir
#   ├── android_prebuilts_clang_host_linux-x86_clang-6443078/
#   └── android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Paths — derived from script location, nothing hardcoded
# ──────────────────────────────────────────────────────────────

KDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # kernel source root
PARENT="$(dirname "${KDIR}")"                             # /home/tony/moto

CLANG_DIR="${PARENT}/android_prebuilts_clang_host_linux-x86_clang-6443078/bin"
GCC_DIR="${PARENT}/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/bin"

AK3_DIR="${PARENT}/AnyKernel3"
OUT_ZIP="${PARENT}/AnyKernel3-motoe32s.zip"

BUILT_IMAGE="${KDIR}/out/arch/arm64/boot/Image.gz"
BUILD_MODULES_DIR="${KDIR}/out/modules"

DEFCONFIG="p410ae_defconfig"

# ──────────────────────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────────────────────

print_help() {
    cat << 'HELP'
build.sh — Build Levion kernel for Motorola E32s (MediaTek)

Usage:
  ./build.sh [options]

Options:
  (no flags)      Full build (DEFAULT): clean + defconfig + Image.gz
                  + modules (built, stripped, staged) -> AnyKernel3 -> zip

  --no-modules    Skip building/staging modules; zip ships Image.gz only.
                  Also wipes any modules left in AnyKernel3/ from a prior run.

  --kernel-only   Stop after building Image.gz — no modules, no AnyKernel3,
                  no zip. Use when you just want to check the kernel builds.

  --modules-only  Skip clean/defconfig/kernel build entirely — just runs
                  modules_install against the EXISTING out/ tree, strips,
                  stages into AnyKernel3, and repackages the zip. Requires
                  a prior successful kernel build (out/ + Image.gz must
                  already exist); errors out with a clear message if not.
                  --skip-clean is a no-op here since this mode never cleans.

  --skip-clean    Skip `make clean` / `make mrproper` (incremental build).
                  Applies to the default and --kernel-only modes.

  --debug         Verbose, keep intermediate state.

  -h, --help      Show this help and exit.

Flags can be combined, e.g.:
  ./build.sh --no-modules --skip-clean
  ./build.sh --kernel-only --skip-clean

--kernel-only, --modules-only, and --no-modules are mutually exclusive in
combinations that don't make sense (e.g. --modules-only --no-modules) —
the script refuses to run rather than guess what you meant.

Expected directory layout:
  /home/tony/moto/
  ├── Motorola_E32s_Levion_kernel/     ← kernel source — script lives here
  │   └── build.sh
  ├── AnyKernel3/                      ← flashable template dir
  ├── android_prebuilts_clang_host_linux-x86_clang-6443078/
  └── android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9/
HELP
}

# ──────────────────────────────────────────────────────────────
# Parse args
# ──────────────────────────────────────────────────────────────

MODE="all"        # all | kernel-only | modules-only
BUILD_MODULES=1   # on by default — pass --no-modules to opt out
SKIP_CLEAN=0
DEBUG=0

KERNEL_ONLY_FLAG=0
MODULES_ONLY_FLAG=0
NO_MODULES_FLAG=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)      print_help; exit 0 ;;
        --kernel-only)  KERNEL_ONLY_FLAG=1;  shift ;;
        --modules-only) MODULES_ONLY_FLAG=1; shift ;;
        --no-modules)   NO_MODULES_FLAG=1;   shift ;;
        --skip-clean)   SKIP_CLEAN=1;        shift ;;
        --debug)        DEBUG=1;             shift ;;
        *) echo "Unknown arg: $1"; echo "Run './build.sh --help' for usage."; exit 1 ;;
    esac
done

# ── Reject combinations that contradict each other ──
if [ "${KERNEL_ONLY_FLAG}" -eq 1 ] && [ "${MODULES_ONLY_FLAG}" -eq 1 ]; then
    echo "Error: --kernel-only and --modules-only are mutually exclusive."
    exit 1
fi
if [ "${MODULES_ONLY_FLAG}" -eq 1 ] && [ "${NO_MODULES_FLAG}" -eq 1 ]; then
    echo "Error: --modules-only and --no-modules are mutually exclusive."
    exit 1
fi
if [ "${KERNEL_ONLY_FLAG}" -eq 1 ] && [ "${NO_MODULES_FLAG}" -eq 1 ]; then
    echo "Error: --kernel-only already skips modules — --no-modules is redundant with it."
    exit 1
fi

if [ "${MODULES_ONLY_FLAG}" -eq 1 ]; then
    MODE="modules-only"
    BUILD_MODULES=1
elif [ "${KERNEL_ONLY_FLAG}" -eq 1 ]; then
    MODE="kernel-only"
    BUILD_MODULES=0
elif [ "${NO_MODULES_FLAG}" -eq 1 ]; then
    BUILD_MODULES=0
fi

[[ "${DEBUG}" -eq 1 ]] && set -x

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

green()  { { set +x; } 2>/dev/null; echo -e "\e[1;32m$*\e[0m"; [[ "${DEBUG}" -eq 1 ]] && set -x || true; }
yellow() { { set +x; } 2>/dev/null; echo -e "\e[1;93m$*\e[0m"; [[ "${DEBUG}" -eq 1 ]] && set -x || true; }
red()    { { set +x; } 2>/dev/null; echo -e "\e[1;31m$*\e[0m"; [[ "${DEBUG}" -eq 1 ]] && set -x || true; }

# ──────────────────────────────────────────────────────────────
# Toolchain
# ──────────────────────────────────────────────────────────────

for d in "${CLANG_DIR}" "${GCC_DIR}"; do
    if [ ! -d "${d}" ]; then
        red "[✗] Toolchain dir not found: ${d}"
        exit 1
    fi
done
export PATH="${CLANG_DIR}:${GCC_DIR}:${PATH}"

# ──────────────────────────────────────────────────────────────
# Common make flags
# ──────────────────────────────────────────────────────────────

MAKE_FLAGS=(
    O=out
    ARCH=arm64
    LLVM=1
    CC=clang
    LD=ld.lld
    AR=llvm-ar
    NM=llvm-nm
    OBJCOPY=llvm-objcopy
    OBJDUMP=llvm-objdump
    READELF=llvm-readelf
    OBJSIZE=llvm-size
    STRIP=llvm-strip
    CROSS_COMPILE=aarch64-linux-gnu-
)

cd "${KDIR}"

if [[ "${MODE}" == "modules-only" ]]; then

    yellow "[*] --modules-only set — skipping clean, defconfig, and kernel build"
    [[ "${SKIP_CLEAN}" -eq 1 ]] && yellow "    (--skip-clean is a no-op here — this mode never cleans)"

    # ── Preconditions: a prior successful kernel build must already exist ──
    if [ ! -d "${KDIR}/out" ]; then
        red "[✗] No out/ directory found at ${KDIR}/out — kernel hasn't been compiled yet."
        red "    Run a full build or './build.sh --kernel-only' first."
        exit 1
    fi

    if [ ! -f "${BUILT_IMAGE}" ]; then
        red "[✗] ${BUILT_IMAGE} not found — kernel hasn't been compiled yet."
        red "    Run a full build or './build.sh --kernel-only' first."
        exit 1
    fi

    green "[✓] Found existing out/ tree and Image.gz — proceeding to modules"

else

    # ══════════════════════════════════════════════════════════════
    # CLEAN
    # ══════════════════════════════════════════════════════════════

    if [ "${SKIP_CLEAN}" -eq 0 ]; then
        yellow "[*] Cleaning build tree..."
        make "${MAKE_FLAGS[@]}" clean || yellow "    [~] clean exited non-zero (ignored)"
        make "${MAKE_FLAGS[@]}" mrproper || yellow "    [~] mrproper exited non-zero (ignored)"
        git status
        green "[✓] Clean done"
    else
        yellow "[*] --skip-clean set, leaving out/ as-is"
    fi

    # ══════════════════════════════════════════════════════════════
    # DEFCONFIG
    # ══════════════════════════════════════════════════════════════

    yellow "[*] Loading defconfig (${DEFCONFIG})..."
    make "${MAKE_FLAGS[@]}" "${DEFCONFIG}"
    green "[✓] Defconfig loaded"

    # ══════════════════════════════════════════════════════════════
    # KERNEL BUILD
    # ══════════════════════════════════════════════════════════════

    yellow "[*] Building kernel ($(nproc) threads)..."
    make -j"$(nproc)" "${MAKE_FLAGS[@]}"
    green "[✓] Kernel built"

    if [ ! -f "${BUILT_IMAGE}" ]; then
        red "[✗] Image.gz not found at ${BUILT_IMAGE}"
        exit 1
    fi

fi

# ══════════════════════════════════════════════════════════════
# MODULES  (on by default — build, strip, and stage into AnyKernel3;
#           pass --no-modules or --kernel-only to skip)
# ══════════════════════════════════════════════════════════════

if [ "${BUILD_MODULES}" -eq 0 ] && [[ "${MODE}" == "all" ]]; then
    # Not building modules this run (--no-modules) — but AnyKernel3/ may still
    # have modules staged from a PREVIOUS run with modules enabled. If we
    # don't clear it, those stale .ko files (and modules.dep/alias/load) get
    # zipped again even though this build never touched them.
    AK3_MODULES_DIR="${AK3_DIR}/modules/vendor/lib/modules"
    if [ -d "${AK3_MODULES_DIR}" ]; then
        yellow "[*] --no-modules set, clearing stale modules from ${AK3_MODULES_DIR}..."
        rm -rf "${AK3_MODULES_DIR}"
        green "[✓] Stale modules removed"
    fi
fi

if [ "${BUILD_MODULES}" -eq 1 ]; then

    if [ ! -d "${AK3_DIR}" ]; then
        red "[✗] AnyKernel3 directory not found: ${AK3_DIR}"
        exit 1
    fi

    # NOTE: no separate `make modules` step — the .ko files are already produced
    # by the main kernel build above (same as the OP9 script). Going straight to
    # modules_install, matching the exact command that works on this tree.
    #
    # Wipe any previous INSTALL_MOD_PATH tree first. modules_install namespaces
    # its output under lib/modules/<kernelrelease>/, and <kernelrelease> embeds
    # the current commit hash (e.g. 4.19.191-gXXXXXXX-dirty) — every commit
    # produces a DIFFERENT directory, and old ones are never cleaned up on
    # their own. Left alone, a later build picking "whichever directory comes
    # first" (as this script used to) can silently grab a stale one from a
    # previous run instead of the kernel that was just built — the .ko files
    # would all still exist, just be the wrong (older) ones, with nothing here
    # to flag it.
    rm -rf "${BUILD_MODULES_DIR}"
    yellow "[*] Installing modules → ${BUILD_MODULES_DIR}..."
    mkdir -p "${BUILD_MODULES_DIR}"
    make "${MAKE_FLAGS[@]}" modules_install INSTALL_MOD_PATH="${BUILD_MODULES_DIR}"
    green "[✓] Modules installed → ${BUILD_MODULES_DIR}"

    # depmod stages everything under lib/modules/<kernelrelease>/ — locate it
    # via the kernelrelease this exact build just produced (rather than
    # guessing at a directory listing) so it can never point at a stale
    # kernelrelease even if one somehow still exists.
    KERNELRELEASE="$(cat "${KDIR}/out/include/config/kernel.release" 2>/dev/null)"
    if [ -z "${KERNELRELEASE}" ]; then
        red "[✗] Could not read kernelrelease from out/include/config/kernel.release"
        exit 1
    fi
    KMOD_SUBDIR="${BUILD_MODULES_DIR}/lib/modules/${KERNELRELEASE}"
    if [ ! -d "${KMOD_SUBDIR}" ]; then
        red "[✗] Expected module staging dir not found: ${KMOD_SUBDIR}"
        exit 1
    fi
    yellow "    Found module staging dir: ${KMOD_SUBDIR}"

    KERNEL_MOD_DIR="${KMOD_SUBDIR}/kernel"
    if [ ! -d "${KERNEL_MOD_DIR}" ]; then
        red "[✗] Expected 'kernel' subfolder not found: ${KERNEL_MOD_DIR}"
        exit 1
    fi

    MOD_KO_COUNT=$(find "${KERNEL_MOD_DIR}" -type f -name "*.ko" | wc -l)
    if [ "${MOD_KO_COUNT}" -eq 0 ]; then
        red "[✗] No .ko files found under ${KERNEL_MOD_DIR}"
        exit 1
    fi
    yellow "    Found ${MOD_KO_COUNT} built modules"

    # ── AnyKernel3 layout: modules/vendor/lib/modules/*.ko — flat, no kernelrelease dir ──
    AK3_MODULES_DIR="${AK3_DIR}/modules/vendor/lib/modules"
    rm -rf "${AK3_MODULES_DIR}"
    mkdir -p "${AK3_MODULES_DIR}"

    yellow "    Copying modules..."
    find "${KERNEL_MOD_DIR}" -type f -name "*.ko" -exec cp -p {} "${AK3_MODULES_DIR}/" \;

    # Strip debug symbols
    if command -v llvm-strip &>/dev/null; then
        yellow "    Stripping debug symbols..."
        for ko in "${AK3_MODULES_DIR}"/*.ko; do
            llvm-strip --strip-debug "${ko}"
        done
    fi

    # ── modules.alias / modules.dep / modules.softdep — copied straight from depmod output ──
    for f in modules.alias modules.dep modules.softdep; do
        if [ -f "${KMOD_SUBDIR}/${f}" ]; then
            cp -p "${KMOD_SUBDIR}/${f}" "${AK3_MODULES_DIR}/"
        else
            yellow "    [!] ${f} not found in staging, skipping"
        fi
    done

    # Fix paths in modules.dep → /vendor/lib/modules/<name>.ko
    # depmod here writes paths relative to the module root, e.g.
    # "kernel/drivers/net/wireless/foo.ko: kernel/drivers/misc/bar.ko" —
    # strip any directory prefix and rewrite each *.ko reference in one pass.
    if [ -f "${AK3_MODULES_DIR}/modules.dep" ]; then
        sed -E -i 's#[^ :]*/([A-Za-z0-9_.-]+\.ko)#/vendor/lib/modules/\1#g' "${AK3_MODULES_DIR}/modules.dep"
        green "    Fixed modules.dep paths → /vendor/lib/modules/"
    fi

    # ── modules.load — list of module filenames (with .ko), one per line ──
    : > "${AK3_MODULES_DIR}/modules.load"
    for ko in "${AK3_MODULES_DIR}"/*.ko; do
        basename "${ko}" >> "${AK3_MODULES_DIR}/modules.load"
    done
    green "    Generated modules.load (${MOD_KO_COUNT} entries)"

    green "[✓] Modules staged → ${AK3_MODULES_DIR}"
fi

# ══════════════════════════════════════════════════════════════
# PACKAGE  (skipped for --kernel-only; runs for the default full build and for --modules-only)
# ══════════════════════════════════════════════════════════════

if [[ "${MODE}" == "all" || "${MODE}" == "modules-only" ]]; then

    yellow "[*] Packaging AnyKernel3 zip..."

    if [ ! -d "${AK3_DIR}" ]; then
        red "[✗] AnyKernel3 directory not found: ${AK3_DIR}"
        exit 1
    fi

    cp -p "${BUILT_IMAGE}" "${AK3_DIR}/Image.gz"
    green "    Copied Image.gz → ${AK3_DIR}/Image.gz"

    # Remove any stale zip first — `zip -r` only ADDS/UPDATES entries into an
    # existing archive, it never drops files that were removed from AK3_DIR
    # (e.g. modules from a previous --modules run). Without this, a later
    # non-modules build would silently keep shipping last run's .ko files.
    rm -f "${OUT_ZIP}"

    cd "${AK3_DIR}"
    zip -r9 "${OUT_ZIP}" . -x ".git/*" ".git" ".github/*" ".github" "README.md"
    cd "${KDIR}"

    ZIP_SIZE=$(du -sh "${OUT_ZIP}" | cut -f1)
    green "[✓] Flashable zip → ${OUT_ZIP} (${ZIP_SIZE})"

fi

# ──────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────

echo ""
green "[✓] All done!"
echo "    Kernel Image.gz:  ${BUILT_IMAGE}"
[[ "${BUILD_MODULES}" -eq 1 ]] && echo "    Modules staged:    ${AK3_DIR}/modules/vendor/lib/modules"
[[ "${MODE}" == "all" ]]       && echo "    Flashable zip:     ${OUT_ZIP}"
[[ "${MODE}" == "kernel-only" ]] && echo "    (--kernel-only: no modules, no AnyKernel3, no zip)"