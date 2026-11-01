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
    [[ "${target%%-*}" == "$(uname -m)" ]] \
        || die "container static builds only support the host arch ($(uname -m)); use BUILDER=cross for ${target}"

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
