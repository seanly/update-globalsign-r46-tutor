#!/bin/bash
# Capture leaf and intermediate certificates for trust-targets.txt.
# Runs inside the CentOS 6 container. OpenSSL 1.0.1e has no x509 -ext, so AIA
# URIs are read from openssl x509 -text.
set -eu

if [ "${1:-}" = "" ] || [ "${2:-}" != "" ]; then
  echo "usage: fetch-chains.sh DEST_DIR" >&2
  exit 2
fi

dest=$1
here=$(cd "$(dirname "$0")" && pwd)
targets=$here/trust-targets.txt
mkdir -p "$dest"

split_pems() {
  local src=$1
  local dir=$2
  rm -rf "$dir"
  mkdir -p "$dir"
  awk -v dir="$dir" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/%04d.pem", dir, n) }
    f != "" { print > f }
    /-----END CERTIFICATE-----/ { if (f != "") close(f); f = "" }
  ' "$src"
}

fp_of() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 \
    | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F'
}

to_pem() {
  local raw=$1
  local out=$2
  if openssl x509 -in "$raw" -noout -subject >/dev/null 2>&1; then
    openssl x509 -in "$raw" -out "$out"
    return 0
  fi
  if openssl x509 -inform DER -in "$raw" -out "$out" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

s_client_capture() {
  local host=$1
  local out=$2
  local err=$3
  local pid
  local i
  openssl s_client -connect "${host}:443" -servername "$host" -showcerts \
    </dev/null >"$out" 2>"$err" &
  pid=$!
  i=0
  while [ "$i" -lt 20 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" || true
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# Download AIA CA Issuers certificates into pool/. Already-seen fingerprints
# are skipped. The server chain often includes a cross-certificate; the AIA
# certificate is the one signed by the root named in trust-targets.txt.
add_aia() {
  local pool=$1
  local seen=$2
  local round=0
  local added snapshot pem uris uri raw pem_out fp n
  while [ "$round" -lt 3 ]; do
    round=$((round + 1))
    added=0
    snapshot=$(mktemp -d)
    cp -a "$pool"/. "$snapshot"/ 2>/dev/null || true
    for pem in "$snapshot"/*.pem; do
      [ -f "$pem" ] || continue
      uris=$(openssl x509 -in "$pem" -noout -text 2>/dev/null \
        | sed -n 's/^[[:space:]]*CA Issuers - URI://p' || true)
      for uri in $uris; do
        case "$uri" in
          http://*|https://*) ;;
          *) continue ;;
        esac
        raw=$(mktemp)
        if ! curl -fsSL --max-time 20 -o "$raw" "$uri"; then
          rm -f "$raw"
          continue
        fi
        pem_out=$(mktemp)
        if ! to_pem "$raw" "$pem_out"; then
          rm -f "$raw" "$pem_out"
          continue
        fi
        rm -f "$raw"
        fp=$(fp_of "$pem_out")
        if grep -qx "$fp" "$seen"; then
          rm -f "$pem_out"
          continue
        fi
        echo "$fp" >> "$seen"
        n=$(find "$pool" -name '*.pem' | wc -l | tr -d ' ')
        n=$((n + 1))
        mv "$pem_out" "$pool/$(printf '%04d' "$n").pem"
        added=1
      done
    done
    rm -rf "$snapshot"
    if [ "$added" -eq 0 ]; then
      break
    fi
  done
}

count=0
while read -r fp file host; do
  case "$fp" in
    ""|\#*) continue ;;
  esac
  count=$((count + 1))
  echo "fetch $host"
  out="$dest/$file"
  rm -rf "$out"
  mkdir -p "$out"
  raw=$(mktemp)
  err=$(mktemp)
  s_client_capture "$host" "$raw" "$err"
  work=$(mktemp -d)
  split_pems "$raw" "$work"
  if [ ! -s "$work/0001.pem" ]; then
    echo "no certificate from $host" >&2
    cat "$err" >&2
    exit 1
  fi
  openssl x509 -in "$work/0001.pem" -out "$out/leaf.pem"
  pool=$(mktemp -d)
  seen=$(mktemp)
  echo "$(fp_of "$out/leaf.pem")" > "$seen"
  n=0
  for pem in "$work"/*.pem; do
    [ -f "$pem" ] || continue
    [ "$pem" = "$work/0001.pem" ] && continue
    n=$((n + 1))
    openssl x509 -in "$pem" -out "$pool/$(printf '%04d' "$n").pem"
    fp_of "$pool/$(printf '%04d' "$n").pem" >> "$seen"
  done
  cp "$out/leaf.pem" "$pool/leaf.pem"
  add_aia "$pool" "$seen"
  rm -f "$pool/leaf.pem"
  : > "$out/untrusted.pem"
  for pem in "$pool"/*.pem; do
    [ -f "$pem" ] || continue
    cat "$pem" >> "$out/untrusted.pem"
  done
  rm -rf "$work" "$pool"
  rm -f "$raw" "$err" "$seen"
  echo "saved $file"
done < "$targets"

test "$count" -eq 7
echo "fetched 7 chains into $dest"
