#!/usr/bin/env bash
# Build a .deb for one Linux target using dpkg-deb (no cargo-deb needed).
#
#   scripts/build-deb.sh [TARGET]
#
# Env: PROFILE (default release), BUILDER (cargo|cross|zigbuild), DIST_DIR (default ./dist),
#      DEB_REVISION (default 1), MAINTAINER (default: original author, Samuel Åkesson),
#      HOMEPAGE (default: origin remote), STATIC=1 (fully static musl binary, no Depends)

source "$(dirname "${BASH_SOURCE[0]}")/packaging/common.sh"

TARGET="${1:-$(host_target)}"
[[ "${TARGET}" == *-linux-* ]] || die "deb packages need a Linux target, got ${TARGET}"
command -v dpkg-deb >/dev/null || die "dpkg-deb not found (apt install dpkg)"

VERSION="$(package_version)"
REVISION="${DEB_REVISION:-1}"
ARCH="$(deb_arch "${TARGET}")"
LICENSE_ID="$(workspace_license)"

BIN_PATH="$(build_binary "${TARGET}")"
mkdir -p "${DIST_DIR}"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
PKG_ROOT="${STAGE}/${PKG_NAME}"

install -Dm755 "${BIN_PATH}" "${PKG_ROOT}/usr/bin/${BIN_NAME}"
install -Dm644 "${ROOT_DIR}/README.md" "${PKG_ROOT}/usr/share/doc/${PKG_NAME}/README.md"
{
    echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
    echo "Upstream-Name: ${PKG_NAME}"
    echo "Source: $(repo_homepage)"
    echo
    echo "Files: *"
    echo "License: ${LICENSE_ID}"
    sed 's/^[[:space:]]*$/./; s/^/ /' "${ROOT_DIR}/LICENSE"
} >"${STAGE}/copyright"
install -Dm644 "${STAGE}/copyright" "${PKG_ROOT}/usr/share/doc/${PKG_NAME}/copyright"

if [[ "${STATIC}" == 1 ]]; then
    # Fully static binary: no library dependencies (CA certificates are still recommended below).
    DEPENDS_LINE=""
    DEB_SUFFIX="_static"
elif [[ "${ARCH}" != "$(dpkg --print-architecture 2>/dev/null)" ]]; then
    # dpkg-shlibdeps only knows the host architecture's libraries; read the ELF directly instead.
    DEPENDS_LINE="Depends: $(elf_deb_depends "${BIN_PATH}")"
    DEB_SUFFIX=""
else
    # Derive Depends (libc6 version floor, libgcc-s1, ...) from the binary's shared-library needs.
    command -v dpkg-shlibdeps >/dev/null || die "dpkg-shlibdeps not found (apt install dpkg-dev)"
    mkdir -p "${STAGE}/debian"
    printf 'Source: %s\n\nPackage: %s\nArchitecture: any\n' "${PKG_NAME}" "${PKG_NAME}" >"${STAGE}/debian/control"
    SHLIBDEPS="$(cd "${STAGE}" && dpkg-shlibdeps -O "${PKG_ROOT}/usr/bin/${BIN_NAME}" 2>"${STAGE}/shlibdeps.err")" \
        || { cat "${STAGE}/shlibdeps.err" >&2; die "dpkg-shlibdeps failed for ${BIN_PATH}"; }
    DEPENDS="$(sed -n 's/^shlibs:Depends=//p' <<<"${SHLIBDEPS}")"
    [[ -n "${DEPENDS}" ]] || die "dpkg-shlibdeps reported no dependencies for ${BIN_PATH}"
    DEPENDS_LINE="Depends: ${DEPENDS}"
    DEB_SUFFIX=""
fi

INSTALLED_SIZE="$(du -sk "${PKG_ROOT}" | cut -f1)"
mkdir -p "${PKG_ROOT}/DEBIAN"
cat >"${PKG_ROOT}/DEBIAN/control" <<EOF
Package: ${PKG_NAME}
Version: ${VERSION}-${REVISION}
Architecture: ${ARCH}
Maintainer: $(maintainer)
Installed-Size: ${INSTALLED_SIZE}
${DEPENDS_LINE}
Recommends: ca-certificates
Section: devel
Priority: optional
Homepage: $(repo_homepage)
Description: $(package_field description)
 Checks a GitHub-hosted Rust project for common hallmarks of low-effort
 LLM-generated code, such as an old Rust edition, workspace resolver 2 and
 outdated dependencies.
EOF
# Drop the empty Depends line for static builds; dpkg rejects blank lines.
sed -i '/^$/d' "${PKG_ROOT}/DEBIAN/control"

DEB="${DIST_DIR}/${PKG_NAME}_${VERSION}-${REVISION}${DEB_SUFFIX}_${ARCH}.deb"
# xz rather than dpkg's newer zstd default, so older dpkg (Debian <= 11, Ubuntu <= 21.04) can install it.
dpkg-deb -Zxz --root-owner-group --build "${PKG_ROOT}" "${DEB}" >&2
log "Created ${DEB} ($(du -h "${DEB}" | cut -f1))"
