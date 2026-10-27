#!/bin/bash
# Runs inside CentOS 6. Builds the RPM, installs it, and checks the anchors.
set -eu
set -o pipefail

cp /src/ansible/files/centos-6.repo /etc/yum.repos.d/centos-6.repo
mkdir -p /etc/yum.repos.d/disabled
for f in /etc/yum.repos.d/CentOS-*.repo; do
  [ -e "$f" ] || continue
  mv -f "$f" /etc/yum.repos.d/disabled/
done

yum install -y rpm-build openssl
yum --disablerepo='*' --enablerepo=base --enablerepo=updates --enablerepo=extras update -y ca-certificates
ver=$(rpm -q --qf '%{VERSION}\n' ca-certificates | head -n 1)
test "$ver" = "2020.2.41"

src=/src/packages/centos6
bundle=/etc/pki/tls/certs/ca-bundle.crt
old_gts=2A575471E31340BC21581CBD2CF13E158463203ECE94BCF9D3CC196BF09A5472

list_bundle_fps() {
  dest=$1
  tmp=$(mktemp -d)
  awk -v dir="$tmp" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/%04d.pem", dir, n) }
    f != "" { print > f }
    /-----END CERTIFICATE-----/ { if (f != "") close(f); f = "" }
  ' "$bundle"
  : > "$dest"
  for pem in "$tmp"/*.pem; do
    [ -f "$pem" ] || continue
    openssl x509 -in "$pem" -noout -fingerprint -sha256 \
      | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F' >> "$dest"
  done
  rm -rf "$tmp"
}

manifest_fps() {
  sed -n 's/^\([0-9A-F][0-9A-F]*\)  .*/\1/p' "$src/sources/fingerprints.txt" | tr 'a-f' 'A-F'
}

require_present() {
  have=$1
  label=$2
  missing=$(mktemp)
  manifest_fps | while read -r fp; do
    grep -qx "$fp" "$have" || echo "$fp"
  done > "$missing"
  if [ -s "$missing" ]; then
    echo "$label" >&2
    cat "$missing" >&2
    exit 1
  fi
  rm -f "$missing"
}

require_absent() {
  have=$1
  label=$2
  still=$(mktemp)
  manifest_fps | while read -r fp; do
    grep -qx "$fp" "$have" && echo "$fp" || true
  done > "$still"
  if [ -s "$still" ]; then
    echo "$label" >&2
    cat "$still" >&2
    exit 1
  fi
  rm -f "$still"
}

topdir=/tmp/rpm
rm -rf "$topdir"
mkdir -p "$topdir"/{SPECS,SOURCES,BUILD,RPMS,SRPMS}
cp "$src/el6-ca-trust-extras.spec" "$topdir/SPECS/"
cp "$src/sources/fingerprints.txt" "$topdir/SOURCES/"
tar -C "$src/sources" -czf "$topdir/SOURCES/el6-ca-trust-extras-certs.tar.gz" --exclude fingerprints.txt .

rpmbuild --define "_topdir $topdir" -bb "$topdir/SPECS/el6-ca-trust-extras.spec"
cp -a "$topdir"/RPMS/noarch/*.rpm /out/
rpm_file=$(echo /out/el6-ca-trust-extras-*.rpm)
echo "built $rpm_file"

payload=$(mktemp -d)
(
  cd "$payload"
  rpm2cpio "$rpm_file" | cpio -id
)
pkg_fps=$(mktemp)
find "$payload" -type f -name '*.crt' -print | while read -r pem; do
  openssl x509 -in "$pem" -noout -fingerprint -sha256 \
    | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F'
done | sort > "$pkg_fps"
manifest_fps | sort > /tmp/manifest.fps
test "$(wc -l < "$pkg_fps")" -eq 7
cmp /tmp/manifest.fps "$pkg_fps"
for blocked in \
  873F4685FA7F563625252E6D36BCD7F16FC24951F264E47E1B954F4908CDCA13 \
  EF66B0B10A3CDB9F2E3648C76BD2AF18EAD2BFE6F117655E28C4060DA1A3F4C2 \
  9A296A5182D1D451A2E37F439B74DAAFA267523329F90F9A0D2007C334E23C9A \
  24A55C2AB051442D0617766541239A4AD032D7C55175AA34FFDE2FBC4F5C5294 \
  97552015F5DDFC3C8788C006944555408894450084F100867086BC1A2BB58DC8 \
  945BBC825EA554F489D1FD51A73DDF2EA624AC7019A05205225C22A78CCFA8B4 \
  55903859C8C0C3EBB8759ECE4E2557225FF5758BBD38EBD48276601E1BD58097
do
  if grep -qx "$blocked" "$pkg_fps"; then
    echo "excluded fingerprint packaged: $blocked" >&2
    exit 1
  fi
done
rm -rf "$payload"

before=$(mktemp)
list_bundle_fps "$before"
grep -qx "$old_gts" "$before"

rpm -Uvh "$rpm_file"
test -L "$bundle"
after=$(mktemp)
list_bundle_fps "$after"
require_present "$after" "missing from bundle after install"
grep -qx "$old_gts" "$after"

rpm -e el6-ca-trust-extras
erased=$(mktemp)
list_bundle_fps "$erased"
require_absent "$erased" "still present after erase"
grep -qx "$old_gts" "$erased"
echo "erase removed the added roots and kept the previous GTS Root R1"
