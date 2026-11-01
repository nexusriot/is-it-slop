#!/usr/bin/env bash
# Build the CLI for one target and pack it as is-it-slop-<version>-<target>.tar.gz
# (.zip on Windows) together with README.md and LICENSE.
#
#   scripts/build-archive.sh [TARGET]
#
# Env: PROFILE (default release), BUILDER (cargo|cross|zigbuild), DIST_DIR (default ./dist),
#      STATIC=1 (fully static musl binary)

source "$(dirname "${BASH_SOURCE[0]}")/packaging/common.sh"

TARGET="${1:-$(host_target)}"
[[ "${STATIC}" == 1 ]] && TARGET="$(musl_target "${TARGET}")"
VERSION="$(package_version)"

BIN_PATH="$(build_binary "${TARGET}")"
mkdir -p "${DIST_DIR}"

STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
cp "${BIN_PATH}" "${ROOT_DIR}/README.md" "${ROOT_DIR}/LICENSE" "${STAGE}/"

NAME="${BIN_NAME}-${VERSION}-${TARGET}"
if [[ "${TARGET}" == *windows* ]]; then
    ARCHIVE="${DIST_DIR}/${NAME}.zip"
    rm -f "${ARCHIVE}"
    if command -v zip >/dev/null; then
        (cd "${STAGE}" && zip -q "${ARCHIVE}" ./*)
    elif command -v 7z >/dev/null; then
        (cd "${STAGE}" && 7z a -tzip "${ARCHIVE}" ./* >/dev/null)
    else
        die "need zip or 7z to create ${ARCHIVE}"
    fi
else
    ARCHIVE="${DIST_DIR}/${NAME}.tar.gz"
    tar -czf "${ARCHIVE}" -C "${STAGE}" .
fi

log "Created ${ARCHIVE} ($(du -h "${ARCHIVE}" | cut -f1))"
