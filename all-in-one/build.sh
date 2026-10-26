#!/bin/bash
# Build a CentOS 6 x86_64 ELF. The shell installer and certificate are gzipped inside it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cert="$root/packages/centos6/sources/globalsign-root-r46.crt"
image="${CENTOS6_IMAGE:-docker.syscube.dev/centos:6}"
platform="${DOCKER_PLATFORM:-linux/amd64}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

fp=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g')
test "$fp" = "4FA3126D8D3A11D1C4855A4F807CBAD6CF919D3A5A88B03BEA2C6372D93C40C9"

if base64 --help 2>&1 | grep -q -- '-w'; then
  b64=$(base64 -w 0 "$cert")
else
  b64=$(base64 < "$cert" | tr -d '\n')
fi

awk -v b64="$b64" '{gsub("__CERT_B64__", b64); print}' "$here/cacert-update.sh.in" > "$stage/cacert-update.sh"
if grep -F '__CERT_B64__' "$stage/cacert-update.sh" >/dev/null; then
  echo "certificate placeholder was not replaced" >&2
  exit 1
fi
gzip -c "$stage/cacert-update.sh" > "$stage/payload.gz"

python3 - "$stage/payload.gz" "$stage/payload.c" <<'PY'
import pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
out = pathlib.Path(sys.argv[2])
lines = ["const unsigned char payload[] = {"]
for i in range(0, len(data), 16):
    chunk = data[i:i + 16]
    lines.append("  " + ", ".join("%d" % b for b in chunk) + ",")
lines.append("};")
lines.append("const unsigned int payload_len = %d;" % len(data))
out.write_text("\n".join(lines) + "\n")
PY

cp "$here/launcher.c" "$stage/launcher.c"

docker run --rm -i --platform "$platform" \
  -v "$root:/src:ro" \
  -v "$stage:/work:ro" \
  -v "$here:/out" \
  "$image" \
  bash -s <<'EOF'
set -eu
cp /src/ansible/files/centos-6.repo /etc/yum.repos.d/centos-6.repo
mkdir -p /etc/yum.repos.d/disabled
for f in /etc/yum.repos.d/CentOS-*.repo; do
  [ -e "$f" ] || continue
  mv -f "$f" /etc/yum.repos.d/disabled/
done
yum install -y gcc glibc-devel
gcc -O2 -o /tmp/cacert-update.bin /work/launcher.c /work/payload.c
cp /tmp/cacert-update.bin /out/cacert-update.bin
chmod 755 /out/cacert-update.bin
EOF

file "$here/cacert-update.bin"
echo "wrote $here/cacert-update.bin"
