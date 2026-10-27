#!/bin/bash
# Install the bundled el6-ca-trust-extras RPM. RPM_B64 is the package.
# The same NEVRA already installed is left in place. Anchors are checked either way.
set -eu

if [ -z "${RPM_B64:-}" ]; then
  echo "RPM_B64 is required" >&2
  exit 2
fi

rpmfile=$(mktemp /tmp/el6-ca-trust-extras.XXXXXX.rpm)
trap 'rm -f "$rpmfile"' EXIT
printf '%s' "$RPM_B64" | base64 -d > "$rpmfile"

nevra=$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$rpmfile")
name=$(rpm -qp --qf '%{NAME}\n' "$rpmfile")

if rpm -q "$nevra" >/dev/null 2>&1; then
  echo "Unchanged: $nevra"
else
  rpm -Uvh "$rpmfile"
  echo "Installed: $nevra"
fi

rpm -q "$name" >/dev/null

anchors=/etc/pki/ca-trust/source/anchors
for f in \
  globalsign-root-r46.crt \
  globalsign-root-e46.crt \
  digicert-tls-rsa4096-root-g5.crt \
  digicert-tls-ecc-p384-root-g5.crt \
  isrg-root-x2.crt \
  microsoft-rsa-root-certificate-authority-2017.crt \
  microsoft-ecc-root-certificate-authority-2017.crt
do
  if [ ! -f "$anchors/$f" ]; then
    echo "missing anchor $anchors/$f" >&2
    exit 1
  fi
done
echo "anchors: 7"
