# Custom Samba 4 AD DC RPM Builder for RHEL 9 (`samba-rpm-build-rhel9`)

**Version:** 1.0.0  
**Target OS:** Red Hat Enterprise Linux 9 / Rocky Linux 9 / AlmaLinux 9 / UBI 9  
**Package:** `samba-ad-dc` (Samba 4.24+)  
**License:** MIT  

---

### **⚠️ CRITICAL DISCLAIMER**

> This guide is an **experimental** proof of concept and is intended for educational and technology evaluation purposes.
> 
> * **No Official Support:** This is NOT an officially supported Red Hat product, reference architecture, or consulting delivery standard.
> * **Inherent Risks:** An experimental approach tests new ideas without a long track record. It involves unknown risks, fast learning loops, and uncertain results.
> * **Liability:** All materials, templates, and automation playbooks are provided "as-is" for demonstration only.

---

## 1. Executive Summary & RHEL 9 Context

Deploying Samba as an Active Directory Domain Controller (AD DC) on **Red Hat Enterprise Linux 9 (RHEL 9)** presents unique architectural constraints compared to other Linux distributions (such as Debian, Ubuntu, or Alpine):

* **Absence of Native RHEL 9 `samba-dc` RPMs**: Red Hat deliberately omits Active Directory Domain Controller packages (`samba-dc`) from official RHEL 9 AppStream repositories, positioning **Red Hat Identity Management (IdM / FreeIPA)** as the primary Linux identity solution.
* **Mandatory MIT Kerberos Binding**: While standard Samba AD DC builds historically relied on an embedded Heimdal Kerberos implementation, RHEL 9 standardizes strictly on **system MIT Kerberos** (`krb5-libs`). Samba must be compiled explicitly against MIT Kerberos headers using `./configure --with-system-mitkrb5 --with-experimental-mit-ad-dc`.
* **Repository & Dependency Access**: Building on RHEL 9 requires enabling the **CodeReady Linux Builder (CRB)** repository to access mandatory build headers (`krb5-devel`, `libarchive-devel`, `jansson-devel`, `bind-devel`, `popt-devel`).
* **Container Isolation & Extended Attributes**: Testing Samba AD DC provisioning inside Red Hat Universal Base Image 9 (UBI 9) containers introduces host kernel user namespace isolation challenges regarding extended file attributes (`security.NTACL` / POSIX ACLs).

* **UBI 9 and RHEL Version Alignment**: At the time of this build, the containerized toolchain pulls the official Red Hat Universal Base Image 9 (`registry.access.redhat.com/ubi9/ubi:latest`), which corresponds to the **Red Hat Enterprise Linux 9.7** userland baseline. All compiled binaries, system MIT Kerberos headers (`krb5-devel`), and runtime Python modules (`python3-markdown`, `python3-cryptography`, `python3-dns`) have been fully tested and validated against this RHEL 9.7 release environment.



### TLDR 
> - This repository provides an automated, modular, containerized toolchain to build, package, and verify custom Samba 4 AD DC RPMs specifically tailored for RHEL 9 environments.
> - Pre-Built RPM Packages
For convenience, quick evaluation, or to bypass the containerized compilation process, a pre-compiled `samba-ad-dc` RPM package is included directly in the `/rpm` directory at the root of this repository (`rpm/samba-ad-dc-4.24.7-1.el9.x86_64.rpm`). You can use this pre-built binary directly with `scripts/test-samba-rpm.sh` for instant container smoke testing or copy it to target hosts for deployment via `dnf localinstall`.




---

## 2. Repository Structure

```text
samba-rpm-build-rhel9/
├── LICENSE                        # MIT License
├── README.md                      # Primary Documentation & Operations Runbook
├── Containerfile.samba-build      # UBI 9 Build container definition with RHSM support
├── Containerfile.samba-test       # UBI 9 Test container definition for package verification
├── rpm/                           # Pre-Built RPM Packages
├── spec/
│   └── samba.spec.in              # Externalized RPM spec template with Python 3 dependencies
├── scripts/
│   ├── build-samba-rpm.sh         # Production compilation & RPM packaging script
│   └── test-samba-rpm.sh          # Containerized smoke test harness
└── output/
    └── .gitkeep                   # Target directory for generated .rpm packages
```

---

## 3. Quick Start & Prerequisites

### 3.1 Host System Requirements
* Red Hat Enterprise Linux 9, Rocky Linux 9, or Fedora build workstation
* Podman or Docker installed (`sudo dnf install -y podman`)
* Internet access to clone `https://git.samba.org/samba.git` and pull UBI 9 base images

---

## 4. Step-by-Step Usage Guide

### Step 1: Clone Repository
```bash
git clone https://github.com/your-org/samba-rpm-build-rhel9.git
cd samba-rpm-build-rhel9
```

### Step 2: Build the Compilation Container
If building on an unsubscribed host or requiring Red Hat Subscription Manager (RHSM) repositories for CRB access, pass `RH_USER` and `RH_PASS` as build arguments:

```bash
# Option A: Standard Build (UBI 9 Default Repositories)
podman build -t samba-ad-builder -f Containerfile.samba-build .

# Option B: With Red Hat Subscription Manager Credentials
podman build -t samba-ad-builder   --build-arg RH_USER="your_rhsm_username"   --build-arg RH_PASS="your_rhsm_password"   -f Containerfile.samba-build .
```

### Step 3: Execute RPM Compilation
Run the build container, mounting the `output/` directory, `spec/` folder, and compilation script.

> **Note on Version Selection:** Pass `-e SAMBA_TAG="samba-4.24.7"` to lock compilation to a specific stable release tag. If `-e SAMBA_TAG` is omitted, the build script defaults to cloning and building the latest Samba `master` development branch.

```bash
chmod +x scripts/build-samba-rpm.sh

# Build a specific Samba release tag (Recommended):
podman run --rm   -e SAMBA_TAG="samba-4.24.7"   -v $(pwd)/output:/build/output:z   -v $(pwd)/spec:/build/spec:ro,z   -v $(pwd)/scripts/build-samba-rpm.sh:/build/build-samba-rpm.sh:ro,z   samba-ad-builder /build/build-samba-rpm.sh
```

Upon completion, compiled packages (`samba-ad-dc-4.24.7-1.el9.x86_64.rpm`) will be exported to `./output/`.

---

### Step 4: Containerized Smoke Test & Verification

The automated smoke test harness (`scripts/test-samba-rpm.sh`) verifies that newly built RPM packages resolve dependencies and provision Active Directory correctly without panicking. It supports GNU-style `--argname=value` CLI options and built-in help (`--help`).

#### 1. Display Usage & Options (`--help`)
Run the test script with `-h` or `--help` to view all available options, parameters, and environment variable fallbacks:

```bash
chmod +x scripts/test-samba-rpm.sh
./scripts/test-samba-rpm.sh --help
```

#### 2. Execute the Test Harness

You can pass options using standard `--argname=value` syntax or set environment variables:

```bash
# Option A: Standard Execution (Runs with default configuration)
./scripts/test-samba-rpm.sh

# Option B: Explicit CLI Arguments (--argname=value notation)
./scripts/test-samba-rpm.sh   --rh-user="your_rhsm_username"   --rh-pass="your_rhsm_password"   --output-dir="$(pwd)/output"

# Option C: Environment Variable Fallback
export RH_USER="your_rhsm_username"
export RH_PASS="your_rhsm_password"
./scripts/test-samba-rpm.sh
```

> **Note on Execution Context**: `scripts/test-samba-rpm.sh` automatically detects rootless vs. rootful execution environments. In a rootless shell, it automatically invokes `sudo podman` to ensure proper user namespace and POSIX extended attribute (`xattr`) allocation during domain provisioning.

#### 3. Verification Gates Executed by `scripts/test-samba-rpm.sh` 

The harness script executes three sequential verification gates:

1. **Automated Image Build**: Builds `localhost/samba-ad-tester:latest` using `Containerfile.samba-test`, forwarding `RH_USER`/`RH_PASS` build arguments if specified.
2. **RPM Dependency Resolution & Installation Gate**: Mounts `./output/` read-only into the test container, installs packages via `dnf localinstall -y /output/*.rpm`, and validates binary installation and version responses (`samba -V`, `samba-tool --version`, `winbindd -V`, `smbclient --version`).
3. **Domain Provisioning Gate**: Runs `samba-tool domain provision` under elevated container capabilities (`--privileged`, `--cap-add=SYS_ADMIN`, `--security-opt label=disable`, `--tmpfs /var/lib/samba:rw,exec,mode=1777`), verifying LDB datastore creation (`sam.ldb`), forest update execution, Kerberos configuration (`krb5.conf`), and structural `smb.conf` validity.

#### 4. Expected Output
Upon successful verification across all three gates, the test harness exits with code `0` and outputs:

```text
==========================================================
  SUCCESS: Samba AD DC RPMs passed all verification gates!
==========================================================
```

---

## 5. Technical Deep Dive

### 5.1 System MIT Kerberos Build Configuration
Samba 4 AD DC is configured with system MIT Kerberos integration to ensure native library compatibility across RHEL 9 nodes:

```bash
./configure --prefix=/usr \
            --sysconfdir=/etc \
            --localstatedir=/var \
            --with-system-mitkrb5 \
            --with-experimental-mit-ad-dc \
            --enable-fhs \
            --disable-iprint
```

### 5.2 Extended Attribute (`xattr`) & Container Isolation Override
During `samba-tool domain provision`, Samba writes NT ACLs (`security.NTACL`) to `/var/lib/samba/sysvol/` via `vfs_acl_xattr.so`. In rootless Podman containers, host user namespace restrictions block `fsetxattr` calls, triggering a **Security context active token stack underflow panic**.

The verification script (`scripts/test-samba-rpm.sh`) resolves this by supplying container isolation bypass flags:

```bash
podman run --rm   -v "$(pwd)/output":/output:ro,z   --privileged   --cap-add=SYS_ADMIN   --security-opt label=disable   --security-opt seccomp=unconfined   --tmpfs /var/lib/samba:rw,exec,mode=1777   localhost/samba-ad-tester:latest bash -c "..."
```

* **`--cap-add=SYS_ADMIN` & `--privileged`**: Grants POSIX extended attribute privileges inside UBI 9.
* **`--security-opt label=disable`**: Disables host SELinux container process labeling.
* **`--tmpfs /var/lib/samba:rw,exec,mode=1777`**: Mounts an in-memory POSIX filesystem with full xattr support.

---

## 6. License

This repository is licensed under the **MIT License**. See [LICENSE](LICENSE) for full details.
