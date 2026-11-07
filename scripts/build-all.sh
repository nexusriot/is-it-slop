#!/usr/bin/env bash
# Build archives (and optionally deb/rpm) for several targets.
#
#   scripts/build-all.sh [TARGET...]
#
# With no targets, builds the usual targets for this host OS: Linux x86_64/aarch64 on Linux,
# Apple Silicon/Intel on macOS, Windows x86_64/aarch64 on Windows. Cross-compiling Linux
# aarch64 from x86_64 needs BUILDER=cross or BUILDER=zigbuild.
#
# Env: PACKAGES="archive deb rpm" (default: archive; deb/rpm only apply to Linux targets)

source "$(dirname "${BASH_SOURCE[0]}")/packaging/common.sh"

SCRIPTS_DIR="${ROOT_DIR}/scripts"
PACKAGES="${PACKAGES:-archive}"

if [[ $# -gt 0 ]]; then
    TARGETS=("$@")
else
    case "$(uname -s)" in
        Linux) CANDIDATES=(x86_64-unknown-linux-gnu aarch64-unknown-linux-gnu) ;;
        Darwin) CANDIDATES=(aarch64-apple-darwin x86_64-apple-darwin) ;;
        MINGW* | MSYS* | CYGWIN*) CANDIDATES=(x86_64-pc-windows-msvc aarch64-pc-windows-msvc) ;;
        *) die "unsupported host $(uname -s); pass targets explicitly" ;;
    esac
    # Default list: skip cross targets this host has no toolchain for, rather than failing.
    TARGETS=()
    for target in "${CANDIDATES[@]}"; do
        if can_build_target "${target}"; then
            TARGETS+=("${target}")
        else
            log "Skipping ${target}: no cross toolchain (install gcc-$(cross_gcc_prefix "${target}"), or set BUILDER=zigbuild|cross)"
        fi
    done
fi

failed=()
for target in "${TARGETS[@]}"; do
    for kind in ${PACKAGES}; do
        if [[ "${kind}" != archive && "${target}" != *-linux-* ]]; then
            log "Skipping ${kind} for ${target} (Linux only)"
            continue
        fi
        if ! "${SCRIPTS_DIR}/build-${kind}.sh" "${target}"; then
            failed+=("${kind}:${target}")
        fi
    done
done

if [[ ${#failed[@]} -gt 0 ]]; then
    die "failed: ${failed[*]}"
fi
log "All builds finished; output in ${DIST_DIR}"
