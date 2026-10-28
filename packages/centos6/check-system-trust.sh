#!/bin/bash
# Prove each injected root is required and that the system bundle uses it.
#   check-system-trust.sh installed STOCK_BUNDLE CHAIN_DIR ROOT_DIR TARGETS
#   check-system-trust.sh erased   STOCK_BUNDLE CHAIN_DIR ROOT_DIR TARGETS
# STOCK_BUNDLE is the ca-certificates bundle from before the extras package.
# CHAIN_DIR holds leaf.pem and untrusted.pem written by fetch-chains.sh.
# installed: stock bundle must reject the direct path, the single root file
# must accept it, and /etc/pki/tls/certs/ca-bundle.crt must accept it.
# erased: the system bundle must reject the same path.
# A live handshake is printed for installed mode and does not decide success.
set -eu
set -o pipefail

mode=${1:-}
stock=${2:-}
chains=${3:-}
roots=${4:-}
targets=${5:-}
system=${6:-/etc/pki/tls/certs/ca-bundle.crt}

if [ "$mode" != "installed" ] && [ "$mode" != "erased" ]; then
  echo "usage: check-system-trust.sh installed|erased STOCK_BUNDLE CHAIN_DIR ROOT_DIR TARGETS" >&2
  exit 2
fi
for need in "$stock" "$chains" "$roots" "$targets"; do
  if [ ! -e "$need" ]; then
    echo "missing $need" >&2
    exit 2
  fi
done

name_field() {
  openssl x509 -in "$1" -noout -"$2" | sed 's/^[^=]*=[[:space:]]*//'
}

fp_of() {
  openssl x509 -in "$1" -noout -fingerprint -sha256 \
    | sed 's/.*=//; s/://g' | tr 'a-f' 'A-F'
}

split_pems() {
  local src=$1
  local dir=$2
  rm -rf "$dir"
  mkdir -p "$dir"
  if [ ! -s "$src" ]; then
    return 0
  fi
  awk -v dir="$dir" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = sprintf("%s/%04d.pem", dir, n) }
    f != "" { print > f }
    /-----END CERTIFICATE-----/ { if (f != "") close(f); f = "" }
  ' "$src"
}

# Walk issuer links from the leaf to ROOT_SUBJECT. Self-signed certificates
# are skipped so a cross-certificate and its old root cannot loop. The chosen
# intermediates are appended to OUT; the root itself stays in -CAfile.
pick_path() {
  local want=$1
  local depth=$2
  local root_subject=$3
  local cand_dir=$4
  local out=$5
  local pem sub iss next
  if [ "$want" = "$root_subject" ]; then
    : > "$out"
    return 0
  fi
  if [ "$depth" -gt 6 ]; then
    return 1
  fi
  pem=
  sub=
  iss=
  next=
  for pem in "$cand_dir"/*.pem; do
    [ -f "$pem" ] || continue
    sub=$(name_field "$pem" subject)
    iss=$(name_field "$pem" issuer)
    if [ "$sub" = "$iss" ]; then
      continue
    fi
    if [ "$sub" != "$want" ]; then
      continue
    fi
    next=$(mktemp)
    if pick_path "$iss" $((depth + 1)) "$root_subject" "$cand_dir" "$next"; then
      cp "$next" "$out"
      echo "$pem" >> "$out"
      rm -f "$next"
      return 0
    fi
    rm -f "$next"
  done
  return 1
}

verify_with() {
  local cafile=$1
  local leaf=$2
  local untrusted=$3
  if [ -s "$untrusted" ]; then
    openssl verify -purpose sslserver -CAfile "$cafile" -untrusted "$untrusted" "$leaf"
  else
    openssl verify -purpose sslserver -CAfile "$cafile" "$leaf"
  fi
}

if [ "$mode" = "installed" ]; then
  if [ ! -L "$system" ]; then
    echo "system bundle is not a symlink: $system" >&2
    exit 1
  fi
fi

count=0
while read -r fp file host; do
  case "$fp" in
    ""|\#*) continue ;;
  esac
  count=$((count + 1))
  rootfile=$roots/$file
  leaf=$chains/$file/leaf.pem
  bag=$chains/$file/untrusted.pem
  if [ ! -s "$leaf" ] || [ ! -f "$rootfile" ]; then
    echo "missing chain or root for $file" >&2
    exit 1
  fi
  got=$(fp_of "$rootfile")
  if [ "$got" != "$fp" ]; then
    echo "fingerprint mismatch for $file: $got" >&2
    exit 1
  fi

  root_subject=$(name_field "$rootfile" subject)
  leaf_issuer=$(name_field "$leaf" issuer)
  cand=$(mktemp -d)
  split_pems "$bag" "$cand"
  chosen=$(mktemp)
  if ! pick_path "$leaf_issuer" 0 "$root_subject" "$cand" "$chosen"; then
    echo "no direct path from $host to $file" >&2
    echo "leaf issuer: $leaf_issuer" >&2
    echo "root subject: $root_subject" >&2
    exit 1
  fi
  untrusted=$(mktemp)
  : > "$untrusted"
  if [ -s "$chosen" ]; then
    while read -r pem; do
      [ -n "$pem" ] || continue
      cat "$pem" >> "$untrusted"
    done < "$chosen"
  fi
  echo "path $host -> $file"
  if [ -s "$chosen" ]; then
    while read -r pem; do
      [ -n "$pem" ] || continue
      name_field "$pem" subject | sed 's/^/  /'
    done < "$chosen"
  fi

  verify_out=$(mktemp)
  if verify_with "$stock" "$leaf" "$untrusted" >"$verify_out" 2>&1; then
    echo "stock bundle accepted $host; chain still has another trusted path and does not prove $file is required" >&2
    cat "$verify_out" >&2
    exit 1
  fi

  if [ "$mode" = "installed" ]; then
    if ! verify_with "$rootfile" "$leaf" "$untrusted" >"$verify_out" 2>&1; then
      echo "root file $file rejected $host" >&2
      cat "$verify_out" >&2
      exit 1
    fi
    if ! verify_with "$system" "$leaf" "$untrusted" >"$verify_out" 2>&1; then
      echo "system bundle rejected $host" >&2
      cat "$verify_out" >&2
      exit 1
    fi
    echo "system bundle trusts $host via $file"
  else
    if verify_with "$system" "$leaf" "$untrusted" >"$verify_out" 2>&1; then
      echo "system bundle still trusts $host after erase" >&2
      cat "$verify_out" >&2
      exit 1
    fi
    echo "system bundle rejects $host after erase"
  fi
  rm -rf "$cand"
  rm -f "$chosen" "$untrusted" "$verify_out"
done < "$targets"

test "$count" -eq 7

if [ "$mode" != "installed" ]; then
  exit 0
fi

echo "NSS module links:"
ls -l /etc/alternatives/libnssckbi.so* 2>/dev/null || echo "no libnssckbi alternative"
if ! command -v curl >/dev/null 2>&1; then
  echo "curl absent; NSS handshake not probed"
fi

while read -r fp file host; do
  case "$fp" in
    ""|\#*) continue ;;
  esac
  live=$(mktemp)
  if command -v timeout >/dev/null 2>&1; then
    timeout 20 openssl s_client -CAfile "$system" -connect "${host}:443" -servername "$host" \
      </dev/null >"$live" 2>&1 || true
  else
    openssl s_client -CAfile "$system" -connect "${host}:443" -servername "$host" \
      </dev/null >"$live" 2>&1 || true
  fi
  if grep -q "Verify return code: 0 " "$live"; then
    echo "live handshake trusted: $host"
  else
    echo "信任已通过，实时握手未完成: $host"
    grep -E "Verify return code:|error:|errno=|alert" "$live" | head -n 4 || true
  fi
  rm -f "$live"
  if command -v curl >/dev/null 2>&1; then
    curl_rc=0
    if command -v timeout >/dev/null 2>&1; then
      timeout 20 curl -fsS -o /dev/null --max-time 15 "https://${host}/" >/dev/null 2>&1 || curl_rc=$?
    else
      curl -fsS -o /dev/null --max-time 15 "https://${host}/" >/dev/null 2>&1 || curl_rc=$?
    fi
    if [ "$curl_rc" -eq 0 ]; then
      echo "curl trusted: $host"
    else
      echo "curl did not complete: $host"
    fi
  fi
done < "$targets"
