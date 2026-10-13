#!/usr/bin/env bash
# =============================================================================
# Script Name:  test-samba-rpm.sh
# Description:  Containerized runtime test for the samba-ad-dc RPM on UBI 9.
#
# Builds (or reuses) the test image, starts a privileged UBI 9 container on
# its own network, installs the RPM and runs scripts/runtime-gates.sh:
# provisioning, the MIT KDC, Kerberos, LDAP, SMB, DNS, GPO handling and
# BIND9 DLZ. Exit code = number of failed gates.
#
# Red Hat credentials are NOT needed when the host is a registered RHEL
# system: podman shares the host subscription with UBI builds. Otherwise pass
# --rhsm-secret=<file> (a file containing RH_USER=... and RH_PASS=...), which
# is mounted with `podman build --secret` and never stored in the image.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
RPM_DIR="${REPO_DIR}/output"
IMAGE_NAME="localhost/samba-ad-tester:latest"
CONTAINERFILE="${REPO_DIR}/Containerfile.samba-test"
RHSM_SECRET=""
BUILD_IMAGE=1
OFFLINE=0
ENGINE="${CONTAINER_ENGINE:-}"
NETWORK="samba-ad-test"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --rpm-dir=<path>        Directory with samba-ad-dc-*.x86_64.rpm
                          (default: ./output, falls back to ./rpm)
  --image-name=<tag>      Test image tag (default: ${IMAGE_NAME})
  --containerfile=<path>  Test Containerfile (default: Containerfile.samba-test)
  --rhsm-secret=<file>    File with RH_USER=/RH_PASS= for unregistered hosts
  --no-build              Reuse an existing test image
  --offline               Install the RPM with all repositories disabled
                          (proves the image already holds every dependency)
  --engine=<podman|docker>
  -h, --help              Show this help

Examples:
  $(basename "$0")                               # registered RHEL host
  $(basename "$0") --rpm-dir=./rpm --no-build    # test the committed RPM
  $(basename "$0") --rhsm-secret=\$HOME/.rhsm.env  # unregistered host
EOF
}

for arg in "$@"; do
    case "${arg}" in
        -h|--help)          show_help; exit 0 ;;
        --rpm-dir=*)        RPM_DIR="${arg#*=}" ;;
        --output-dir=*)     RPM_DIR="${arg#*=}" ;;   # backward compatible
        --image-name=*)     IMAGE_NAME="${arg#*=}" ;;
        --containerfile=*)  CONTAINERFILE="${arg#*=}" ;;
        --rhsm-secret=*)    RHSM_SECRET="${arg#*=}" ;;
        --no-build)         BUILD_IMAGE=0 ;;
        --offline)          OFFLINE=1 ;;
        --engine=*)         ENGINE="${arg#*=}" ;;
        *) echo "ERROR: unknown option '${arg}' (see --help)" >&2; exit 2 ;;
    esac
done

if [ -z "${ENGINE}" ]; then
    if command -v podman >/dev/null; then ENGINE=podman
    elif command -v docker >/dev/null; then ENGINE=docker
    else echo "ERROR: neither podman nor docker found" >&2; exit 2; fi
fi
SUDO=""
if [ "${EUID}" -ne 0 ] && [ "${ENGINE}" = podman ]; then
    # Privileged containers need rootful podman for security.* xattrs.
    SUDO="sudo"
fi
RUN="${SUDO} ${ENGINE}"

if ! ls "${RPM_DIR}"/samba-ad-dc-*.x86_64.rpm >/dev/null 2>&1; then
    if ls "${REPO_DIR}"/rpm/samba-ad-dc-*.x86_64.rpm >/dev/null 2>&1; then
        RPM_DIR="${REPO_DIR}/rpm"
    else
        echo "ERROR: no samba-ad-dc-*.x86_64.rpm in ${RPM_DIR}; run build-samba-rpm.sh first" >&2
        exit 2
    fi
fi
echo "===> Testing: $(ls "${RPM_DIR}"/samba-ad-dc-*.x86_64.rpm)"

if [ "${BUILD_IMAGE}" = 1 ]; then
    echo "===> [1/3] Building test image ${IMAGE_NAME}"
    SECRET_ARGS=()
    if [ -n "${RHSM_SECRET}" ]; then
        [ -r "${RHSM_SECRET}" ] || { echo "ERROR: cannot read ${RHSM_SECRET}" >&2; exit 2; }
        SECRET_ARGS=(--secret "id=rhsm,src=${RHSM_SECRET}")
    fi
    ${RUN} build "${SECRET_ARGS[@]}" -t "${IMAGE_NAME}" -f "${CONTAINERFILE}" "${REPO_DIR}"
else
    echo "===> [1/3] Reusing image ${IMAGE_NAME}"
fi

echo "===> [2/3] Preparing network ${NETWORK}"
${RUN} network exists "${NETWORK}" 2>/dev/null \
    || ${RUN} network inspect "${NETWORK}" >/dev/null 2>&1 \
    || ${RUN} network create "${NETWORK}" >/dev/null

echo "===> [3/3] Running runtime gates"
set +e
${RUN} run --rm \
    --privileged \
    --security-opt label=disable \
    --network "${NETWORK}" \
    --hostname dc1 \
    -e OFFLINE="${OFFLINE}" \
    -v "${RPM_DIR}":/output:ro,z \
    -v "${SCRIPT_DIR}/runtime-gates.sh":/runtime-gates.sh:ro,z \
    "${IMAGE_NAME}" bash /runtime-gates.sh
RC=$?
set -e
exit "${RC}"
