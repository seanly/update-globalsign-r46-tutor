#!/bin/bash
# Import GlobalSign Root R46 into JDK 8 cacerts files that are not the system store.
# CERT_B64 is the PEM certificate. CACERTS_PASS defaults to changeit.
# Extra arguments are explicit cacerts paths; otherwise JDK 8 installs are discovered.
set -eu

pass="${CACERTS_PASS:-changeit}"
expected=4FA3126D8D3A11D1C4855A4F807CBAD6CF919D3A5A88B03BEA2C6372D93C40C9
alias_name=globalsign-root-r46

if [ -z "${CERT_B64:-}" ]; then
  echo "CERT_B64 is required" >&2
  exit 2
fi

cert=$(mktemp /tmp/globalsign-root-r46.XXXXXX.crt)
trap 'rm -f "$cert"' EXIT
printf '%s' "$CERT_B64" | base64 -d > "$cert"

fp=$(openssl x509 -in "$cert" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g')
if [ "$fp" != "$expected" ]; then
  echo "refusing certificate fingerprint $fp" >&2
  exit 1
fi

collect() {
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@"
    return
  fi
  if [ -n "${JAVA_HOME:-}" ]; then
    printf '%s\n' "$JAVA_HOME/jre/lib/security/cacerts"
  fi
  find /usr/lib/jvm /usr/java /opt/java /usr/local/java \
    -path '*/lib/security/cacerts' -type f -o -path '*/lib/security/cacerts' -type l \
    2>/dev/null || true
}

seen=" "
found=0
imported=0

while IFS= read -r ks; do
  [ -n "$ks" ] && [ -e "$ks" ] || continue
  if [ -L "$ks" ]; then
    echo "skip symlink $ks -> $(readlink "$ks")"
    continue
  fi
  id=$(stat -c '%d:%i' "$ks")
  case "$seen" in
    *" $id "*) continue ;;
  esac
  seen="$seen$id "

  jre=$(cd "$(dirname "$ks")/../../.." && pwd)
  java_bin="$jre/bin/java"
  keytool_bin="$jre/bin/keytool"
  if [ ! -x "$java_bin" ] || [ ! -x "$keytool_bin" ]; then
    continue
  fi
  if ! "$java_bin" -version 2>&1 | grep -q 'version "1\.8'; then
    continue
  fi

  found=1
  if "$keytool_bin" -list -alias "$alias_name" -keystore "$ks" -storepass "$pass" >/dev/null 2>&1; then
    echo "already present $ks"
    continue
  fi

  "$keytool_bin" -importcert -noprompt -trustcacerts \
    -alias "$alias_name" \
    -file "$cert" \
    -keystore "$ks" \
    -storepass "$pass"
  echo "imported $ks"
  imported=1
done <<EOF
$(collect "$@")
EOF

if [ "$found" -eq 0 ]; then
  echo "no JDK 8 cacerts found"
fi

if [ "$imported" -eq 1 ]; then
  echo "restart Java 8 processes before they trust the new certificate"
fi
