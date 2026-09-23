#!/usr/bin/env bash
# =============================================================================
# Script Name:  build-samba-rpm.sh
# Description:  Containerized build script for Samba 4 AD DC RPM on RHEL-9/UBI-9.
#
# This script that actually compiles Samba from source code, and pack it as RPM
# in following stages:
# 1. Clones the Samba source repository from git.
# 2. Runs "./configure --with-system-mitkrb5 --with-experimental-mit-ad-dc".
# 3. Compiles the binaries with "make".
# 4. Generates the RPM ".spec" file.
# 5. Packages everything into "samba-ad-dc-4.24.7-1.el9.x86_64.rpm" inside your "./output/" folder.
#
# Used whenever you need to build or update the custom RPM packages from scratch.
# =============================================================================
set -euo pipefail

# Define target release tag (defaults to "latest" / master).
SAMBA_TAG="${1:-${SAMBA_TAG:-latest}}"

if [ "${SAMBA_TAG}" = "master" ] || [ "${SAMBA_TAG}" = "latest" ] || [ -z "${SAMBA_TAG}" ]; then
    echo "===> [1/6] Cloning latest Samba master/trunk repository..."
    git clone --depth 1 https://git.samba.org/samba.git /build/samba
else
    echo "===> [1/6] Cloning Samba release tag: ${SAMBA_TAG}..."
    git clone --depth 1 --branch "${SAMBA_TAG}" https://git.samba.org/samba.git /build/samba
fi
cd /build/samba

echo "===> [2/6] Configuring build against system MIT Kerberos..."
./configure --prefix=/usr \
            --sysconfdir=/etc \
            --localstatedir=/var \
            --with-system-mitkrb5 \
            --with-experimental-mit-ad-dc \
            --enable-fhs \
            --disable-iprint

echo "===> [3/6] Compiling Samba AD DC binaries..."
PYTHONHASHSEED=1 make -j$(nproc)

echo "===> [4/6] Creating release tarball and man pages..."
PYTHONHASHSEED=1 ./buildtools/bin/waf dist

echo "===> [5/6] Setting up RPM build tree..."
mkdir -p /root/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

TAR_PATH=$(ls samba-*.tar.gz | head -n 1)
TAR_NAME=$(basename "$TAR_PATH")

cp "$TAR_NAME" /root/rpmbuild/SOURCES/

RAW_VER=$(echo "$TAR_NAME" | sed -E 's/samba-(.*)\.tar\.gz/\1/')
RPM_VER=$(echo "$RAW_VER" | tr '-' '_')

echo "Found Tarball: $TAR_NAME"
echo "Extracted Raw Version: $RAW_VER"
echo "RPM-Compliant Version: $RPM_VER"

SPEC_FILE="/root/rpmbuild/SPECS/samba.spec"

# Locate external spec template: check mounted spec/samba.spec.in first, then packaging/RHEL
SPEC_TEMPLATE=""
if [ -f /build/spec/samba.spec.in ]; then
    SPEC_TEMPLATE="/build/spec/samba.spec.in"
elif [ -f spec/samba.spec.in ]; then
    SPEC_TEMPLATE="spec/samba.spec.in"
elif [ -f packaging/RHEL/samba.spec.in ]; then
    SPEC_TEMPLATE="packaging/RHEL/samba.spec.in"
fi

if [ -n "$SPEC_TEMPLATE" ]; then
    echo "Processing external RPM spec template: $SPEC_TEMPLATE ..."
    sed -e "s/@VERSION@/${RPM_VER}/g" \
        -e "s/@RAW_VER@/${RAW_VER}/g" \
        -e "s/@TAR_NAME@/${TAR_NAME}/g" \
        "$SPEC_TEMPLATE" > "$SPEC_FILE"
else
    echo "ERROR: No external spec file found at /build/spec/samba.spec.in or packaging/RHEL/samba.spec.in!"
    exit 1
fi

cp "$SPEC_FILE" /build/output/debug_processed.spec

echo "===> [6/6] Packaging binaries into RPMs..."
rpmbuild -bb "$SPEC_FILE"

echo "===> Exporting RPMs to host output directory..."
cp /root/rpmbuild/RPMS/x86_64/*.rpm /build/output/ 2>/dev/null || cp /root/rpmbuild/RPMS/*/*.rpm /build/output/
echo "===> Build completed successfully!"
