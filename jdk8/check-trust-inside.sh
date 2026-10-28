#!/bin/bash
# Prove the bundled JDK 8 roots are required and that JSSE uses them.
# Runs inside a JDK 8 image. The stock cacerts is copied; the image file is
# left unchanged. CHAIN_DIR holds leaf.pem and untrusted.pem from fetch-chains.sh.
# A live handshake is printed for the imported store and does not decide success.
set -eu
set -o pipefail

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
chains=""
pass="${CACERTS_PASS:-changeit}"

usage() {
  cat <<'EOF'
Usage: check-trust-inside.sh --chains DIR

Run inside a JDK 8 container. Copy its cacerts, import the bundled roots into
the copy, and PKIX-check the seven direct chains in DIR.

  --chains DIR    directory written by packages/centos6/fetch-chains.sh
  -h, --help      show this help

CACERTS_PASS overrides the keystore password. The default is changeit.

Examples:
  bash jdk8/check-trust-inside.sh --chains /chains
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --chains)
      shift
      if [ "$#" -eq 0 ] || [ -z "${1:-}" ]; then
        echo "error: --chains requires a directory" >&2
        echo "  bash jdk8/check-trust-inside.sh --chains /chains" >&2
        exit 2
      fi
      chains=$1
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      echo "  bash jdk8/check-trust-inside.sh --chains /chains" >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "$chains" ] || [ ! -d "$chains" ]; then
  echo "error: --chains must be an existing directory" >&2
  echo "  bash jdk8/check-trust-inside.sh --chains /chains" >&2
  exit 2
fi

resolve_java_home() {
  local bin
  if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
    printf '%s\n' "$JAVA_HOME"
    return 0
  fi
  if ! command -v java >/dev/null 2>&1; then
    echo "error: java not found" >&2
    return 1
  fi
  bin=$(command -v java)
  if readlink -f "$bin" >/dev/null 2>&1; then
    bin=$(readlink -f "$bin")
  fi
  cd "$(dirname "$bin")/.." && pwd
}

java_home=$(resolve_java_home)
java_bin=$java_home/bin/java
keytool_bin=$java_home/bin/keytool
javac_bin=$java_home/bin/javac
if [ ! -x "$java_bin" ] || [ ! -x "$keytool_bin" ] || [ ! -x "$javac_bin" ]; then
  echo "error: $java_home has no java, keytool, or javac" >&2
  exit 1
fi
if ! "$java_bin" -version 2>&1 | grep -q 'version "1\.8'; then
  echo "error: $java_bin is not JDK 8" >&2
  "$java_bin" -version >&2 || true
  exit 1
fi

if [ -f "$java_home/jre/lib/security/cacerts" ]; then
  origin=$java_home/jre/lib/security/cacerts
elif [ -f "$java_home/lib/security/cacerts" ]; then
  origin=$java_home/lib/security/cacerts
else
  echo "error: cacerts not found under $java_home" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/jdk8-trust.XXXXXX")
trap 'rm -rf "$work"' EXIT
stock_jdk=$work/jdk-stock
imported_jdk=$work/jdk-imported

stage_jdk() {
  local dest=$1
  rm -rf "$dest"
  mkdir -p "$dest/bin" "$dest/jre/lib/security"
  cp "$origin" "$dest/jre/lib/security/cacerts"
  chmod u+w "$dest/jre/lib/security/cacerts"
  ln -s "$java_bin" "$dest/bin/java"
  ln -s "$keytool_bin" "$dest/bin/keytool"
}

stage_jdk "$stock_jdk"
stage_jdk "$imported_jdk"

echo "java: $("$java_bin" -version 2>&1 | head -n 1)"
echo "cacerts: $origin"

echo "=== stock fingerprints ==="
set +e
bash "$here/import-roots.sh" --check --jdk-path "$stock_jdk"
stock_check=$?
set -e
if [ "$stock_check" -eq 0 ]; then
  echo "note: stock store already contains all 22 fingerprints"
fi

echo "=== import ==="
bash "$here/import-roots.sh" --jdk-path "$imported_jdk"

echo "=== imported fingerprints ==="
bash "$here/import-roots.sh" --check --jdk-path "$imported_jdk"

mkdir -p "$work/classes"
"$javac_bin" -d "$work/classes" "$here/PkixCheck.java"

targets=$here/../packages/centos6/trust-targets.txt
if [ ! -f "$targets" ]; then
  echo "error: missing $targets" >&2
  exit 1
fi

fail=0
count=0
while read -r fp file host; do
  case "$fp" in
    ""|\#*) continue ;;
  esac
  count=$((count + 1))
  leaf=$chains/$file/leaf.pem
  bag=$chains/$file/untrusted.pem
  root=$here/certs/$file
  if [ ! -s "$leaf" ] || [ ! -f "$bag" ] || [ ! -f "$root" ]; then
    echo "error: missing chain or root for $file" >&2
    exit 1
  fi
  one=$work/one.jks
  rm -f "$one"
  if ! "$keytool_bin" -importcert -noprompt -alias root \
    -file "$root" -keystore "$one" -storepass "$pass" -storetype JKS \
    >"$work/keytool.out" 2>&1; then
    echo "error: single-root keystore failed for $file" >&2
    cat "$work/keytool.out" >&2
    exit 1
  fi

  echo "=== $file ==="
  set +e
  "$java_bin" -cp "$work/classes" PkixCheck \
    "$stock_jdk/jre/lib/security/cacerts" "$pass" "$leaf" "$bag" "$root"
  stock_rc=$?
  echo "-- single root --"
  "$java_bin" -cp "$work/classes" PkixCheck \
    "$one" "$pass" "$leaf" "$bag" "$root"
  one_rc=$?
  echo "-- imported --"
  "$java_bin" -cp "$work/classes" PkixCheck \
    "$imported_jdk/jre/lib/security/cacerts" "$pass" "$leaf" "$bag" "$root" "$host"
  imp_rc=$?
  set -e

  echo "result $file stock=$stock_rc single=$one_rc imported=$imp_rc"
  case "$stock_rc" in
    0) echo "note: stock store already trusts $file" ;;
    1) ;;
    *)
      echo "error: stock PKIX could not check $file" >&2
      fail=1
      ;;
  esac
  if [ "$one_rc" -ne 0 ] || [ "$imp_rc" -ne 0 ]; then
    echo "error: PKIX failed for $file" >&2
    fail=1
  fi
done < "$targets"

if [ "$count" -ne 7 ]; then
  echo "error: expected 7 direct chains, found $count" >&2
  exit 1
fi
if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "jdk8 trust check passed"
