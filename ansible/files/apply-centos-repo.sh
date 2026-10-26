#!/bin/bash
# Replace stock CentOS-*.repo with centos-<major>.repo and update ca-certificates.
# REPO_B64 is the base64 of the repo file. The first argument is 6 or 7.
set -eu

major="$1"
dest="/etc/yum.repos.d/centos-${major}.repo"

mkdir -p /etc/yum.repos.d/disabled
for f in /etc/yum.repos.d/CentOS-*.repo; do
  [ -e "$f" ] || continue
  mv -f "$f" /etc/yum.repos.d/disabled/
done

printf '%s' "$REPO_B64" | base64 -d > "$dest"
chmod 644 "$dest"

yum clean all
yum --disablerepo='*' --enablerepo=base --enablerepo=updates --enablerepo=extras update -y ca-certificates
rpm -q ca-certificates

if [ "$major" = "7" ]; then
  ver=$(rpm -q --qf '%{VERSION}\n' ca-certificates | head -n 1)
  printf '%s\n%s\n' '2021.2.48' "$ver" | sort -C -V
fi

if [ "$major" = "6" ]; then
  echo "NOTE: CentOS 6 vault ca-certificates does not include GlobalSign Root R46"
fi
