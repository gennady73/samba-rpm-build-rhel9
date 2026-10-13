#!/usr/bin/env bash
# =============================================================================
# Script Name:  runtime-gates.sh
# Description:  Runs INSIDE the samba-ad-tester container (as root, privileged,
#               on a network with a non-loopback IP). Installs the RPM from
#               /output and checks that it works as an AD DC, not only that
#               provisioning finishes.
#
# Exit code: number of failed gates (0 = all passed).
# =============================================================================
set -u

REALM="${REALM:-TEST.LAB}"
DOMAIN="${DOMAIN:-TEST}"
ADMINPASS="${ADMINPASS:-P@ssw0rd2026!}"
OFFLINE="${OFFLINE:-0}"          # 1 = install with all repos disabled
DNSDOM="$(echo "${REALM}" | tr '[:upper:]' '[:lower:]')"
BASEDN="DC=${DNSDOM//./,DC=}"
HOST_SHORT="dc1"
FQDN="${HOST_SHORT}.${DNSDOM}"
IP="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | head -1)"
FAILED=0
LDAP="-H ldap://${FQDN} --use-kerberos=required"

gate() { echo; echo "==== $*"; }
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; FAILED=$((FAILED + 1)); }
check() { local d="$1"; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

stop_samba() {
    pkill -x samba 2>/dev/null || true
    pkill -f '^/usr/libexec/samba/' 2>/dev/null || true
    pkill -x named 2>/dev/null || true
    sleep 2
}

[ -n "${IP}" ] || { echo "ERROR: no non-loopback IPv4 address; do not use --network none"; exit 99; }

gate "1. Install RPM"
DNF_OPTS="-y"; [ "${OFFLINE}" = "1" ] && DNF_OPTS="-y --disablerepo=*"
check "dnf localinstall resolves every dependency" \
    dnf ${DNF_OPTS} localinstall /output/samba-ad-dc-*.x86_64.rpm
rpm -q samba-ad-dc >/dev/null 2>&1 || { echo "Cannot continue without the package."; exit 99; }

gate "2. Packaging"
check "samba.service installed" test -f /usr/lib/systemd/system/samba.service
check "pam_winbind.so in /usr/lib64/security" test -f /usr/lib64/security/pam_winbind.so
check "libraries under /usr/lib64 (none under /usr/lib/samba)" test ! -d /usr/lib/samba
# Private libraries are always loaded by Samba binaries whose RPATH points at
# the private directory, so resolve them with that directory on the path.
NOTFOUND="$(rpm -ql samba-ad-dc | grep -v '/\.build-id/' | while read -r f; do
    [ -f "$f" ] && head -c4 "$f" 2>/dev/null | grep -q ELF \
        && LD_LIBRARY_PATH=/usr/lib64/samba:/usr/lib/samba ldd "$f" 2>/dev/null | grep 'not found' | sed "s|^|$f: |"
done | sort -u)"
[ -z "${NOTFOUND}" ] || echo "${NOTFOUND}" | head -5
check "every shared library resolves" test -z "${NOTFOUND}"
check "rpm -V clean" rpm -V samba-ad-dc

gate "3. Provision (SAMBA_INTERNAL DNS)"
echo "${IP} ${FQDN} ${HOST_SHORT}" >> /etc/hosts
rm -f /etc/samba/smb.conf
check "samba-tool domain provision" samba-tool domain provision \
    --server-role=dc --use-rfc2307 --dns-backend=SAMBA_INTERNAL \
    --realm="${REALM}" --domain="${DOMAIN}" --adminpass="${ADMINPASS}" \
    --host-ip="${IP}" --option="interfaces = lo ${IP}" --option="bind interfaces only = yes"
cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
printf 'search %s\nnameserver %s\n' "${DNSDOM}" "${IP}" > /etc/resolv.conf

gate "4. Start the AD DC"
/usr/sbin/samba -D
for _ in $(seq 1 30); do
    (exec 3<>/dev/tcp/"${IP}"/389) 2>/dev/null && break
    sleep 2
done
check "samba spawned MIT krb5kdc" pgrep -x krb5kdc
for p in 53 88 389 445 636; do
    check "port ${p} accepts TCP" bash -c "exec 3<>/dev/tcp/${IP}/${p}"
done

gate "5. Kerberos, LDAP, SMB, DNS"
check "kinit administrator" bash -c "echo '${ADMINPASS}' | kinit administrator@${REALM} >/dev/null"
check "LDAP over GSSAPI: user list" bash -c "samba-tool user list ${LDAP} | grep -qx Administrator"
check "LDAP write: create user" samba-tool user create gate-user 'Us3r!Passw0rd' ${LDAP}
check "kinit as the new user" bash -c "echo 'Us3r!Passw0rd' | kinit gate-user@${REALM} >/dev/null"
echo "${ADMINPASS}" | kinit "administrator@${REALM}" >/dev/null
check "SMB: sysvol and netlogon shares" bash -c \
    "smbclient -L ${FQDN} --use-kerberos=required 2>/dev/null | grep -q sysvol"
check "DNS: _ldap._tcp.dc._msdcs SRV record" python3 -c "
import dns.resolver as r
x = r.Resolver(configure=False); x.nameservers = ['${IP}']
assert x.resolve('_ldap._tcp.dc._msdcs.${DNSDOM}', 'SRV')"

gate "6. Group Policy handling"
check "ntacl sysvolcheck" samba-tool ntacl sysvolcheck
GUID="$(samba-tool gpo create 'Gate GPO' ${LDAP} 2>/dev/null | grep -o '{[0-9A-F-]*}')"
check "gpo create" test -n "${GUID}"
check "gpo setlink" samba-tool gpo setlink "${BASEDN}" "${GUID}" ${LDAP}
mkdir -p /tmp/gpo-backup /tmp/gpo-tmp
check "gpo backup" samba-tool gpo backup "${GUID}" ${LDAP} --tmpdir=/tmp/gpo-backup
check "gpo restore" samba-tool gpo restore 'Gate GPO restored' \
    "/tmp/gpo-backup/policy/${GUID}" ${LDAP} --tmpdir=/tmp/gpo-tmp
check "dbcheck --cross-ncs" samba-tool dbcheck --cross-ncs

gate "7. BIND9_DLZ with the RHEL 9 BIND"
stop_samba
if command -v named >/dev/null; then
    samba_upgradedns --dns-backend=BIND9_DLZ >/dev/null 2>&1
    sed -i 's|^\(\s*\)# \(database "dlopen .*dlz_bind9_16.so";\)|\1\2|' /var/lib/samba/bind-dns/named.conf
    cat > /etc/named.conf <<EOF
options {
    directory "/var/named";
    listen-on port 53 { ${IP}; };
    recursion no;
    tkey-gssapi-keytab "/var/lib/samba/bind-dns/dns.keytab";
    minimal-responses yes;
};
include "/var/lib/samba/bind-dns/named.conf";
EOF
    sed -i 's/^\(\s*server role = .*\)$/\1\n\tserver services = -dns/' /etc/samba/smb.conf
    chgrp -R named /var/lib/samba/bind-dns && chmod -R g+rX /var/lib/samba/bind-dns
    check "named-checkconf" named-checkconf /etc/named.conf
    named -u named -c /etc/named.conf
    /usr/sbin/samba -D
    sleep 8
    check "BIND DLZ serves _kerberos._tcp SRV" python3 -c "
import dns.resolver as r
x = r.Resolver(configure=False); x.nameservers = ['${IP}']
assert x.resolve('_kerberos._tcp.${DNSDOM}', 'SRV')"
else
    echo "named not installed; skipped"
fi
stop_samba

echo
if [ "${FAILED}" -eq 0 ]; then
    echo "SUCCESS: all runtime gates passed"
else
    echo "FAILED GATES: ${FAILED}"
fi
exit "${FAILED}"
