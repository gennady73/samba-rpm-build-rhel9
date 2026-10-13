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
│   ├── samba.spec.in              # RPM spec template
│   └── ctdb.spec.in               # Unused upstream template (kept for reference)
├── scripts/
│   ├── build-samba-rpm.sh         # rpmbuild -ba: RPM + self-contained SRPM
│   ├── test-samba-rpm.sh          # Host-side runtime test harness (podman/docker)
│   └── runtime-gates.sh           # Gates executed inside the UBI 9 test container
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
git clone https://github.com/gennady73/samba-rpm-build-rhel9.git
cd samba-rpm-build-rhel9
```

### Step 2: Build the Compilation Container
On a **registered RHEL 9 host**, podman passes the host subscription into UBI builds automatically; no credentials are needed:

```bash
podman build -t samba-ad-builder -f Containerfile.samba-build .
```

On an unregistered host, put the credentials in a file that never enters the image and pass it as a build secret:

```bash
printf 'RH_USER=%s\nRH_PASS=%s\n' 'your_user' 'your_password' > ~/.rhsm.env && chmod 600 ~/.rhsm.env
podman build --secret id=rhsm,src=$HOME/.rhsm.env -t samba-ad-builder -f Containerfile.samba-build .
```

> **Never pass passwords with `--build-arg`.** Build arguments are recorded in the image history and can be read with `podman history --no-trunc`.

### Step 3: Build the RPM and SRPM
`SAMBA_TAG` is required and must be a release tag. The spec compiles from `Source0`, so the resulting SRPM rebuilds on its own with `rpmbuild --rebuild`.

```bash
podman run --rm \
  -e SAMBA_TAG="samba-4.24.7" \
  -v "$(pwd)/output":/build/output:z \
  -v "$(pwd)/spec":/build/spec:ro,z \
  -v "$(pwd)/scripts/build-samba-rpm.sh":/build/build-samba-rpm.sh:ro,z \
  samba-ad-builder bash /build/build-samba-rpm.sh
```

If `git.samba.org` is unreachable, add `-e SAMBA_GIT=https://github.com/samba-team/samba.git`, or mount a release tarball and set `-e SAMBA_TARBALL=/src/samba-4.24.7.tar.gz`.

Output: `output/samba-ad-dc-4.24.7-2.el9.x86_64.rpm` and `output/samba-ad-dc-4.24.7-2.el9.src.rpm`.

---

### Step 4: Runtime Test (`scripts/test-samba-rpm.sh`)

The harness starts a privileged UBI 9 container on its own network, installs the RPM and runs `scripts/runtime-gates.sh`. It proves the package works as a domain controller, not only that provisioning finishes.

```bash
./scripts/test-samba-rpm.sh --help
./scripts/test-samba-rpm.sh                                  # registered RHEL host, tests ./output
./scripts/test-samba-rpm.sh --rpm-dir=./rpm                  # test the committed pre-built RPM
./scripts/test-samba-rpm.sh --rhsm-secret=$HOME/.rhsm.env    # unregistered host
./scripts/test-samba-rpm.sh --no-build --offline             # reuse image, all repos disabled
```

Gates (exit code = number of failures):

| # | Gate |
| :--- | :--- |
| 1 | `dnf localinstall` resolves every dependency (`--offline`: from the image alone) |
| 2 | Packaging: `samba.service`, `pam_winbind.so` in `/usr/lib64/security`, no libraries under `/usr/lib`, every shared library resolves, `rpm -V` clean |
| 3 | `samba-tool domain provision` (SAMBA_INTERNAL DNS) |
| 4 | `samba` starts, spawns MIT `krb5kdc`; ports 53, 88, 389, 445, 636 accept TCP |
| 5 | `kinit`, LDAP read and write over GSSAPI, `kinit` as a new user, SMB `sysvol`/`netlogon`, DNS SRV records |
| 6 | GPO: `ntacl sysvolcheck`, `gpo create`/`setlink`/`backup`/`restore`, `dbcheck --cross-ncs` |
| 7 | BIND9 DLZ with the RHEL 9 BIND 9.16 (`dlz_bind9_16.so`) serves the AD SRV records |

Expected result: `SUCCESS: all runtime gates passed`.

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

### 5.2 Extended Attributes (`xattr`) in Containers
Provisioning writes NT ACLs to `security.NTACL` extended attributes on SysVol. Setting `security.*` attributes needs `CAP_SYS_ADMIN`, so the test container runs rootful and `--privileged`, with `--security-opt label=disable`. It also needs a network with a non-loopback IPv4 address: with `--network none` Samba binds only loopback and Kerberos, LDAP and SMB checks fail.

### 5.3 Known Limitations
* **MIT Kerberos AD DC is experimental upstream.** Samba does not issue security fixes for this mode; RODC and authentication audit logging are unsupported. Maintained Heimdal-based el9 packages exist and are the lower-risk choice for production.
* **One package, conflicting files.** `samba-ad-dc` contains the client libraries, tools and Python bindings that RHEL ships as `samba-client-libs`, `libwbclient`, `python3-samba` and others; the spec declares `Conflicts:` for them. A host cannot have both.
* **No `-devel` subpackage**: headers and pkgconfig files are dropped.

---

## 6. License

This repository is licensed under the **MIT License**. See [LICENSE](LICENSE) for full details.
