#!/bin/bash
# Runs inside CentOS 6. Builds the RPM, installs it, and checks R46 is trusted.
set -eu

cp /src/ansible/files/centos-6.repo /etc/yum.repos.d/centos-6.repo
mkdir -p /etc/yum.repos.d/disabled
for f in /etc/yum.repos.d/CentOS-*.repo; do
  [ -e "$f" ] || continue
  mv -f "$f" /etc/yum.repos.d/disabled/
done

yum install -y rpm-build openssl

topdir=/tmp/rpm
mkdir -p "$topdir"/{SPECS,SOURCES,BUILD,RPMS,SRPMS}
cp /src/packages/centos6/globalsign-root-r46.spec "$topdir/SPECS/"
cp /src/packages/centos6/sources/globalsign-root-r46.crt "$topdir/SOURCES/"

rpmbuild --define "_topdir $topdir" -bb "$topdir/SPECS/globalsign-root-r46.spec"
cp -a "$topdir"/RPMS/noarch/*.rpm /out/

rpm_file=$(echo /out/globalsign-root-r46-*.rpm)
echo "built $rpm_file"
before=$(grep -c "BEGIN CERTIFICATE" /etc/pki/tls/certs/ca-bundle.crt || true)
rpm -Uvh "$rpm_file"
after=$(grep -c "BEGIN CERTIFICATE" /etc/pki/tls/certs/ca-bundle.crt || true)
echo "certificates before=$before after=$after"
grep -F "GlobalSign Root R46" /etc/pki/tls/certs/ca-bundle.crt
test -L /etc/pki/tls/certs/ca-bundle.crt

rpm -e globalsign-root-r46
if grep -F "GlobalSign Root R46" /etc/pki/tls/certs/ca-bundle.crt; then
  echo "R46 still present after erase" >&2
  exit 1
fi
echo "erase removed GlobalSign Root R46"
