#!/usr/bin/env bash
# =============================================================================
# Script Name:  build-samba-rpm.sh
# Description:  Build the samba-ad-dc RPM (and SRPM) for RHEL 9 / UBI 9.
#
# Runs inside the samba-ad-builder container:
#   1. Gets the Samba source for SAMBA_TAG (a mounted tarball, or git clone).
#   2. Fills spec/samba.spec.in with the version and tarball name.
#   3. Runs rpmbuild -ba: the spec compiles from Source0 itself, so the
#      resulting SRPM can be rebuilt anywhere with `rpmbuild --rebuild`.
#   4. Copies RPM + SRPM to /build/output.
#
# Environment:
#   SAMBA_TAG     release tag, e.g. samba-4.24.7 (required; "master" is not
#                 accepted because it is not a reproducible build)
#   SAMBA_GIT     git URL (default: https://git.samba.org/samba.git;
#                 mirror: https://github.com/samba-team/samba.git)
#   SAMBA_TARBALL optional path to an existing samba-X.Y.Z.tar.gz
# =============================================================================
set -euo pipefail

SAMBA_TAG="${1:-${SAMBA_TAG:-}}"
SAMBA_GIT="${SAMBA_GIT:-https://git.samba.org/samba.git}"
SPEC_TEMPLATE="${SPEC_TEMPLATE:-/build/spec/samba.spec.in}"
OUTPUT_DIR="${OUTPUT_DIR:-/build/output}"
TOP="${HOME}/rpmbuild"

if [[ ! "${SAMBA_TAG}" =~ ^samba-[0-9]+\.[0-9]+\.[0-9]+([a-z0-9.]*)?$ ]]; then
    echo "ERROR: set SAMBA_TAG to a release tag such as samba-4.24.7" >&2
    exit 1
fi
RAW_VER="${SAMBA_TAG#samba-}"
RPM_VER="${RAW_VER//-/_}"
TAR_NAME="samba-${RAW_VER}.tar.gz"

mkdir -p "${TOP}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS} "${OUTPUT_DIR}"

echo "===> [1/4] Obtaining Samba source ${SAMBA_TAG}"
if [ -n "${SAMBA_TARBALL:-}" ]; then
    cp "${SAMBA_TARBALL}" "${TOP}/SOURCES/${TAR_NAME}"
else
    rm -rf /tmp/samba-src
    git clone --depth 1 --branch "${SAMBA_TAG}" "${SAMBA_GIT}" /tmp/samba-src
    git -C /tmp/samba-src archive --format=tar.gz \
        --prefix="samba-${RAW_VER}/" -o "${TOP}/SOURCES/${TAR_NAME}" HEAD
fi

echo "===> [2/4] Generating spec from ${SPEC_TEMPLATE}"
[ -f "${SPEC_TEMPLATE}" ] || { echo "ERROR: ${SPEC_TEMPLATE} not found" >&2; exit 1; }
sed -e "s/@VERSION@/${RPM_VER}/g" \
    -e "s/@RAW_VER@/${RAW_VER}/g" \
    -e "s/@TAR_NAME@/${TAR_NAME}/g" \
    "${SPEC_TEMPLATE}" > "${TOP}/SPECS/samba.spec"

echo "===> [3/4] rpmbuild -ba (compiles Samba; takes a while)"
rpmbuild -ba "${TOP}/SPECS/samba.spec"

echo "===> [4/4] Exporting packages to ${OUTPUT_DIR}"
cp -v "${TOP}"/RPMS/*/samba-ad-dc-*.rpm "${TOP}"/SRPMS/samba-ad-dc-*.src.rpm "${OUTPUT_DIR}/"
echo "===> Build completed successfully"
