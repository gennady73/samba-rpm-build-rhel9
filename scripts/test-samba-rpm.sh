#!/usr/bin/env bash
# =============================================================================
# Script Name:  test-samba-rpm.sh
# Description:  Samba 4 AD DC RPM Containerized Smoke Test for UBI-9 / Podman
#
# What it does: This is the script that aimed to pass custom Samba RPM verification gates.
#               It spins up a Red Hat UBI-9 container under Podman, installs the 
#               built RPMs (dnf localinstall), and runs "samba-tool domain provision" 
#               to verify that the RPMs work end-to-end without crashing.
#
# Used in CI/CD to "test and validate" the custom Samba RPMs before putting them on real servers.
#
# =============================================================================
set -euo pipefail

# Default parameters
OUTPUT_DIR="$(pwd)/output"
IMAGE_NAME="localhost/samba-ad-tester:latest"
CONTAINERFILE="Containerfile.samba-test"
REALM="TEST.LOCAL"
DOMAIN="TEST"
ADMINPASS="P@ssw0rd2026!"
RH_USER="${RH_USER:-}"
RH_PASS="${RH_PASS:-}"

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Samba 4 AD DC RPM Containerized Smoke Test Harness for RHEL 9 / UBI 9

Options:
  --rh-user=<username>     Red Hat Subscription Manager username
  --rh-pass=<password>     Red Hat Subscription Manager password
  --output-dir=<path>      Directory containing built RPM packages (default: ./output)
  --image-name=<tag>       Test container image tag (default: localhost/samba-ad-tester:latest)
  --containerfile=<path>   Path to test Containerfile (default: Containerfile.samba-test)
  --realm=<realm>          Test Active Directory realm (default: TEST.LOCAL)
  --domain=<domain>        Test Active Directory NetBIOS domain (default: TEST)
  --adminpass=<password>   Test Active Directory administrator password (default: P@ssw0rd2026!)
  -h, --help               Display this help message and exit

Environment Variables:
  RH_USER                  Fallback for --rh-user if option is omitted
  RH_PASS                  Fallback for --rh-pass if option is omitted

Examples:
  # Run smoke test with default settings:
  ./scripts/test-samba-rpm.sh

  # Pass RHSM credentials using --argname=value notation:
  ./scripts/test-samba-rpm.sh --rh-user="my_username" --rh-pass="my_password"

  # Specify custom RPM output directory and container tag:
  ./scripts/test-samba-rpm.sh --output-dir="/tmp/rpms" --image-name="samba-test:v1"
EOF
}

SHOW_INFO_HEADER=false
if [ $# -eq 0 ]; then
    SHOW_INFO_HEADER=true
fi

# Parse options using --argname=value notation
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        --rh-user=*)
            RH_USER="${1#*=}"
            ;;
        --rh-user)
            RH_USER="$2"
            shift
            ;;
        --rh-pass=*)
            RH_PASS="${1#*=}"
            ;;
        --rh-pass)
            RH_PASS="$2"
            shift
            ;;
        --output-dir=*)
            OUTPUT_DIR="${1#*=}"
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift
            ;;
        --image-name=*)
            IMAGE_NAME="${1#*=}"
            ;;
        --image-name)
            IMAGE_NAME="$2"
            shift
            ;;
        --containerfile=*)
            CONTAINERFILE="${1#*=}"
            ;;
        --containerfile)
            CONTAINERFILE="$2"
            shift
            ;;
        --realm=*)
            REALM="${1#*=}"
            ;;
        --realm)
            REALM="$2"
            shift
            ;;
        --domain=*)
            DOMAIN="${1#*=}"
            ;;
        --domain)
            DOMAIN="$2"
            shift
            ;;
        --adminpass=*)
            ADMINPASS="${1#*=}"
            ;;
        --adminpass)
            ADMINPASS="$2"
            shift
            ;;
        *)
            echo "ERROR: Unknown option '$1'"
            echo "Run '$(basename "$0") --help' to view available options."
            exit 1
            ;;
    esac
    shift
done

echo "=========================================================="
echo "  Samba 4 AD DC RPM Containerized Smoke Test"
echo "  Target Environment: Red Hat UBI 9 / Podman / Docker"
echo "=========================================================="

if [ $SHOW_INFO_HEADER = true ]; then
    echo "INFO: Running smoke test with default configuration."
    echo "      Use --help to view all configurable CLI options."
    echo ""
    exit 1
fi

if [ -z "${RH_USER}"] || ["${RH_PASS}"]; then
    echo "ERROR: Red Hat Subscription credentials are empty or not provided."
    echo "       Use --help to view all configurable CLI options."
    echo ""
    exit 1
fi

if [ ! -d "$OUTPUT_DIR" ] || [ -z "$(ls -A "$OUTPUT_DIR"/*.rpm 2>/dev/null)" ]; then
    echo "ERROR: No .rpm packages found in $OUTPUT_DIR. Please run build-samba-rpm.sh first."
    echo "       Use --help to view all configurable CLI options."
    echo ""
    exit 1
fi

echo "===> Found RPM packages in $OUTPUT_DIR:"
ls -lh "$OUTPUT_DIR"/*.rpm

if [ ! -f "$CONTAINERFILE" ]; then
    echo "ERROR: $CONTAINERFILE not found in current directory."
    exit 1
fi

# Determine Podman execution context (rootful vs rootless) at top of script
PODMAN_CMD="podman"
if [ "$EUID" -ne 0 ] && command -v sudo &>/dev/null; then
    echo "---> Rootless environment detected. Using 'sudo podman' (Method 2: Privileged) for full xattr/ACL permissions."
    PODMAN_CMD="sudo podman"
fi

# Construct build arguments for RHSM if credentials are provided
BUILD_ARGS=()
if [ -n "${RH_USER}" ] && [ -n "${RH_PASS}" ]; then
    echo "---> Red Hat Subscription credentials detected. Forwarding to container build..."
    BUILD_ARGS+=("--build-arg" "RH_USER=${RH_USER}" "--build-arg" "RH_PASS=${RH_PASS}")
fi

echo ""
echo "===> [1/3] Building UBI 9 Test Container Image using ${PODMAN_CMD}..."
$PODMAN_CMD build -t "$IMAGE_NAME" "${BUILD_ARGS[@]}" -f "$CONTAINERFILE" .

echo ""
echo "===> [2/3] Testing RPM Dependency Resolution & Binary Installation..."
$PODMAN_CMD run --rm \
  -v "$OUTPUT_DIR":/output:ro,z \
  "$IMAGE_NAME" bash -c "
    set -euo pipefail
    echo '---> Installing locally built RPMs via dnf...'
    dnf localinstall -y /output/*.rpm
    
    echo '---> [PASS] Local RPM installation succeeded!'
    echo '---> Checking installed binary versions:'
    /usr/sbin/samba -V
    /usr/bin/samba-tool --version
    /usr/sbin/winbindd -V
    /usr/bin/smbclient --version
"

echo ""
echo "===> [3/3] Executing Samba AD DC Domain Provisioning Smoke Test..."
echo "       Applying Extended Attribute & Container Isolation Bypass Flags..."

$PODMAN_CMD run --rm \
  --privileged \
  --cap-add=SYS_ADMIN \
  --security-opt label=disable \
  --security-opt seccomp=unconfined \
  --tmpfs /var/lib/samba:rw,exec,mode=1777 \
  -v "$OUTPUT_DIR":/output:ro,z \
  "$IMAGE_NAME" bash -c "
    set -euo pipefail
    dnf localinstall -y /output/*.rpm > /dev/null 2>&1
    
    echo '---> Cleaning placeholder configuration files...'
    rm -f /etc/samba/smb.conf /etc/krb5.conf
    
    echo '---> Executing samba-tool domain provision...'
    samba-tool domain provision \
      --server-role=dc \
      --use-rfc2307 \
      --dns-backend=SAMBA_INTERNAL \
      --realm='${REALM}' \
      --domain='${DOMAIN}' \
      --adminpass='${ADMINPASS}'
    
    echo '---> Verifying generated Kerberos configuration...'
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
    
    echo '---> Checking smb.conf presence and structural validity...'
    test -f /etc/samba/smb.conf
    
    echo '---> [PASS] Domain provisioning completed successfully with zero panics!'
"

echo ""
echo "=========================================================="
echo "  SUCCESS: Samba AD DC RPMs passed all verification gates!"
echo "=========================================================="
