#!/bin/bash
# Build a CentOS 6 x86_64 ELF beside this directory. The importer and certificates are gzipped inside it.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
image="${CENTOS6_IMAGE:-docker.syscube.dev/centos:6}"
platform="${DOCKER_PLATFORM:-linux/amd64}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

manifest="$here/fingerprints.txt"
count=0
while read -r fp name; do
  case "$fp" in
    ""|\#*) continue ;;
  esac
  test -f "$here/certs/$name"
  got=$(openssl x509 -in "$here/certs/$name" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F')
  if [ "$got" != "$fp" ]; then
    echo "fingerprint mismatch for $name" >&2
    exit 1
  fi
  count=$((count + 1))
done < "$manifest"
test "$count" -eq 22

bundle=$stage/jdk8
mkdir -p "$bundle/certs"
cp "$here/import-roots.sh" "$here/fingerprints.txt" "$bundle/"
# Ship LF PEM files. A CRLF working tree still verifies, and the payload stays stable.
python3 - "$here/certs" "$bundle/certs" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
n = 0
for path in sorted(src.glob("*.crt")):
    text = path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n")
    if not text.endswith(b"\n"):
        text += b"\n"
    (dst / path.name).write_bytes(text)
    n += 1
if n != 22:
    raise SystemExit("expected 22 certificates, found %d" % n)
PY
chmod 755 "$bundle/import-roots.sh"
tar -C "$bundle" -cf "$stage/bundle.tar" import-roots.sh fingerprints.txt certs

python3 - "$stage/bundle.tar" "$stage/cacert-update.sh" <<'PY'
import base64, pathlib, sys
tar = pathlib.Path(sys.argv[1]).read_bytes()
b64 = base64.b64encode(tar).decode("ascii")
wrapped = "\n".join(b64[i:i + 76] for i in range(0, len(b64), 76))
script = """#!/bin/bash
# Unpack the embedded JDK 8 trust roots and run the importer.
set -eu
set -o pipefail
root=$(mktemp -d "${TMPDIR:-/tmp}/jdk8-aio.XXXXXX")
trap 'rm -rf "$root"' EXIT
base64 -d <<'END_JDK8_BUNDLE' | tar -C "$root" -xf -
%s
END_JDK8_BUNDLE
bash "$root/import-roots.sh" "$@"
""" % wrapped
pathlib.Path(sys.argv[2]).write_bytes(script.encode("ascii"))
PY

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
