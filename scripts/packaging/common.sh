# shellcheck shell=bash
# Shared helpers for the build/packaging scripts. Source, don't execute.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CRATE_DIR="${ROOT_DIR}/is-it-slop"
DIST_DIR="${DIST_DIR:-${ROOT_DIR}/dist}"
BIN_NAME="is-it-slop"
PKG_NAME="is-it-slop"
PROFILE="${PROFILE:-release}"
FEATURES="${FEATURES:-}"

# Builder used to compile: cargo (native), cross, or zigbuild (cargo-zigbuild).
BUILDER="${BUILDER:-cargo}"

# STATIC=1 builds a fully static binary for the *-linux-musl variant of the target
# (TLS is rustls, so there's no OpenSSL to link). Without a host musl toolchain this runs
# in a rust:alpine container (docker or podman), whose native target is musl.
STATIC="${STATIC:-0}"
STATIC_IMAGE="${STATIC_IMAGE:-rust:alpine}"

log() { printf '==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# [package] field from the crate's Cargo.toml (version, description, ...).
package_field() {
    awk -v key="$1" '
        /^\[package\]/ { in_pkg = 1; next }
        /^\[/ { in_pkg = 0 }
        in_pkg && $1 == key { sub(/^[^=]*=[[:space:]]*"/, ""); sub(/"[[:space:]]*$/, ""); print; exit }
    ' "${CRATE_DIR}/Cargo.toml"
}

workspace_license() {
    awk '
        /^\[workspace\.package\]/ { in_pkg = 1; next }
        /^\[/ { in_pkg = 0 }
        in_pkg && $1 == "license" { sub(/^[^=]*=[[:space:]]*"/, ""); sub(/"[[:space:]]*$/, ""); print; exit }
    ' "${ROOT_DIR}/Cargo.toml"
}

package_version() { package_field version; }

# https URL of the origin remote, used as the package homepage unless HOMEPAGE is set.
repo_homepage() {
    local url
    url="$(git -C "${ROOT_DIR}" remote get-url origin 2>/dev/null || true)"
    url="${url%.git}"
    url="${url/#git@github.com:/https://github.com/}"
    printf '%s\n' "${HOMEPAGE:-${url}}"
}

# Packager identity: the original author unless MAINTAINER overrides it.
maintainer() {
    printf '%s\n' "${MAINTAINER:-Samuel Åkesson <sermuns@lysator.liu.se>}"
}

host_target() {
    rustc -vV | sed -n 's/^host: //p'
}

# x86_64-unknown-linux-gnu -> x86_64-unknown-linux-musl (no-op for musl targets).
musl_target() {
    case "$1" in
        *-linux-musl*) printf '%s\n' "$1" ;;
        *-linux-gnu*) printf '%s\n' "${1/-linux-gnu/-linux-musl}" ;;
        *) die "static builds need a Linux target, got $1" ;;
    esac
}

host_arch() {
    local arch
    arch="$(uname -m)"
    [[ "${arch}" == arm64 ]] && arch=aarch64
    printf '%s\n' "${arch}"
}

# GNU cross toolchain prefix for a *-linux-gnu target (e.g. aarch64-linux-gnu).
cross_gcc_prefix() {
    case "$1" in
        armv7-*-gnueabihf) echo arm-linux-gnueabihf ;;
        *-linux-gnu*) echo "${1%%-*}-linux-gnu" ;;
        *) return 1 ;;
    esac
}

is_foreign_linux_gnu() {
    [[ "$1" == *-linux-gnu* && "${1%%-*}" != "$(host_arch)" ]]
}

# Whether this host can build the target with the current BUILDER/STATIC settings.
can_build_target() {
    local target="$1"
    [[ "${BUILDER}" != cargo ]] && return 0
    if [[ "${STATIC}" == 1 ]]; then
        [[ "${target%%-*}" == "$(host_arch)" ]]
        return
    fi
    is_foreign_linux_gnu "${target}" || return 0
    command -v "$(cross_gcc_prefix "${target}")-gcc" >/dev/null
}

# Plain-cargo cross build of a *-linux-gnu target: aws-lc-sys compiles C and the final link needs
# the matching GNU toolchain (Debian/Ubuntu: gcc-aarch64-linux-gnu; Fedora: gcc-aarch64-linux-gnu).
setup_cross_gnu() {
    local target="$1"
    is_foreign_linux_gnu "${target}" || return 0
    local prefix
    prefix="$(cross_gcc_prefix "${target}")"
    command -v "${prefix}-gcc" >/dev/null \
        || die "cross compiler ${prefix}-gcc not found for ${target}; install gcc-${prefix} (apt/dnf), or use BUILDER=zigbuild or BUILDER=cross"
    local env_target="${target//-/_}"
    export "CC_${env_target}=${prefix}-gcc" "CXX_${env_target}=${prefix}-g++" "AR_${env_target}=${prefix}-ar"
    export "CARGO_TARGET_${env_target^^}_LINKER=${prefix}-gcc"
}

container_engine() {
    local e
    for e in podman docker; do
        command -v "${e}" >/dev/null && { printf '%s\n' "${e}"; return; }
    done
}

# Compile the CLI for a target and print the path to the resulting binary.
#   build_binary <target>
build_binary() {
    local target="$1"
    [[ "${STATIC}" == 1 ]] && target="$(musl_target "${target}")"

    local target_dir="${CARGO_TARGET_DIR:-${ROOT_DIR}/target}"
    local exe="${BIN_NAME}"
    [[ "${target}" == *windows* ]] && exe="${BIN_NAME}.exe"
    local path="${target_dir}/${target}/${PROFILE}/${exe}"

    local -a args=(--locked -p "${PKG_NAME}" --bin "${BIN_NAME}" --profile "${PROFILE}" --target "${target}")
    [[ -n "${FEATURES}" ]] && args+=(--features "${FEATURES}")

    if [[ "${STATIC}" == 1 && "${BUILDER}" == cargo ]] && ! command -v musl-gcc >/dev/null; then
        build_static_in_container "${target}" "${args[@]}"
        path="${ROOT_DIR}/target/${target}/${PROFILE}/${exe}"
    else
        local -a cmd
        case "${BUILDER}" in
            cargo) cmd=(cargo build) ;;
            cross) cmd=(cross build) ;;
            zigbuild) cmd=(cargo zigbuild) ;;
            *) die "unknown BUILDER '${BUILDER}' (expected cargo, cross or zigbuild)" ;;
        esac

        if [[ "${BUILDER}" == cargo ]]; then
            setup_cross_gnu "${target}"
            if command -v rustup >/dev/null && ! rustup target list --installed | grep -qx "${target}"; then
                log "Adding rust target ${target}"
                rustup target add "${target}" >&2
            fi
        fi

        log "Building ${BIN_NAME} for ${target} (profile=${PROFILE}, builder=${BUILDER})"
        # Called inside $(...), where errexit isn't inherited, so fail explicitly.
        (cd "${ROOT_DIR}" && "${cmd[@]}" "${args[@]}" >&2) || die "cargo build failed for ${target}"
    fi

    [[ -f "${path}" ]] || die "expected binary not found at ${path}"
    printf '%s\n' "${path}"
}

# Build inside rust:alpine, whose native target is musl. Only same-arch targets are supported.
build_static_in_container() {
    local target="$1"
    shift
    local engine
    engine="$(container_engine)"
    [[ -n "${engine}" ]] || die "static build needs musl-gcc on the host, or docker/podman to build in ${STATIC_IMAGE}"
    [[ "${target%%-*}" == "$(host_arch)" ]] \
        || die "container static builds only support the host arch ($(host_arch)); use BUILDER=cross for ${target}"

    log "Building ${BIN_NAME} for ${target} in ${STATIC_IMAGE} via ${engine} (profile=${PROFILE})"
    # Cargo's registry lives in a named volume so repeat builds don't re-download crates.
    "${engine}" run --rm \
        -v "${ROOT_DIR}:/src:Z" -w /src \
        -v is-it-slop-cargo-registry:/usr/local/cargo/registry \
        -e CARGO_TARGET_DIR=/src/target \
        "${STATIC_IMAGE}" \
        sh -c "apk add -q --no-cache musl-dev \
            && rustup target add ${target} >/dev/null 2>&1; \
            cargo build $* && chown -R $(id -u):$(id -g) /src/target" >&2 \
        || die "container build failed for ${target}"
}

# Debian Depends read straight from the ELF, for binaries dpkg-shlibdeps can't resolve
# (another architecture than the host's dpkg).
elf_deb_depends() {
    local bin="$1" glibc lib deps
    glibc="$(readelf -W --version-info "${bin}" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -uV | tail -1)"
    [[ -n "${glibc}" ]] || die "could not read the glibc version requirement of ${bin}"
    deps="libc6 (>= ${glibc})"
    while read -r lib; do
        case "${lib}" in
            libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|ld-linux*) ;;
            libgcc_s.so.1) deps+=", libgcc-s1" ;;
            *) die "no Debian package mapping for ${lib} needed by ${bin}" ;;
        esac
    done < <(readelf -d "${bin}" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    printf '%s\n' "${deps}"
}

deb_arch() {
    case "$1" in
        x86_64-*) echo amd64 ;;
        aarch64-*) echo arm64 ;;
        armv7-*|arm-*hf) echo armhf ;;
        i686-*|i586-*) echo i386 ;;
        riscv64gc-*) echo riscv64 ;;
        *) die "no Debian architecture mapping for target $1" ;;
    esac
}

rpm_arch() {
    case "$1" in
        x86_64-*) echo x86_64 ;;
        aarch64-*) echo aarch64 ;;
        armv7-*) echo armv7hl ;;
        i686-*) echo i686 ;;
        riscv64gc-*) echo riscv64 ;;
        *) die "no RPM architecture mapping for target $1" ;;
    esac
}
