#!/bin/bash
# Import a short list of Temurin 8u504 public trust roots into a JDK 8 cacerts file.
# The bundle is the public roots in 8u504 that 8u202 lacks and that servers often
# present without a cross-certificate to an older root. Regional roots, the four
# emSign roots, and the re-signed GlobalSign ECC Root CA - R4 certificate are omitted.
# Existing entries are kept. A certificate already in the store, under any
# alias, is skipped by SHA-256 fingerprint.
set -eu

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cert_dir=$here/certs
manifest=$here/fingerprints.txt
pass="${CACERTS_PASS:-changeit}"
expected_count=22

check_only=0
jdk_paths=""

usage() {
  cat <<'EOF'
Usage: import-roots.sh [--check] [--jdk-path PATH]

Add the bundled JDK 8 trust roots to a JDK 8 cacerts file.
Certificates already present are skipped. Existing roots are not removed.

  --check            report what is missing and do not change the keystore
  --jdk-path PATH    JDK 8 home or a cacerts file; may be repeated
  -h, --help         show this help

CACERTS_PASS overrides the keystore password. The default is changeit.
A symlink is skipped, including one that points at /etc/pki/java/cacerts.
Without --jdk-path, JDK 8 installs are discovered under /usr/lib/jvm,
/usr/java, /opt/java, /usr/local/java, and JAVA_HOME.
Restart Java processes after a keystore change.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check_only=1 ;;
    --jdk-path)
      shift
      if [ "$#" -eq 0 ] || [ -z "${1:-}" ]; then
        echo "--jdk-path requires a path" >&2
        exit 2
      fi
      jdk_paths="${jdk_paths}
$1"
      ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -f "$manifest" ] || [ ! -d "$cert_dir" ]; then
  echo "certificate bundle is incomplete beside $here" >&2
  exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/jdk8-import.XXXXXX")
trap 'rm -rf "$work"' EXIT
bundle_list=$work/bundle.txt
ks_list=$work/keystores.txt
: > "$ks_list"

# keytool labels move between locales. Fingerprints are the 32-byte
# colon-separated values; serial numbers are not printed that way.
extract_sha256() {
  awk '
  {
    s = $0
    gsub(/[^0-9A-Fa-f:]/, " ", s)
    n = split(s, f, " ")
    for (i = 1; i <= n; i++) {
      if (length(f[i]) != 95) continue
      hex = f[i]
      gsub(/:/, "", hex)
      if (length(hex) == 64) print toupper(hex)
    }
  }
  '
}

grep -E '^[0-9A-F]{64}  [^ ]+$' "$manifest" > "$bundle_list"
count=$(wc -l < "$bundle_list" | tr -d ' ')
if [ "$count" -ne "$expected_count" ]; then
  echo "expected $expected_count certificates in $manifest, found $count" >&2
  exit 1
fi

while IFS= read -r row; do
  name=${row#*  }
  if [ ! -f "$cert_dir/$name" ]; then
    echo "missing bundled certificate $name" >&2
    exit 1
  fi
done < "$bundle_list"

resolve_cacerts() {
  target=$1
  if [ -f "$target" ]; then
    printf '%s\n' "$target"
    return 0
  fi
  if [ -d "$target" ]; then
    if [ -e "$target/jre/lib/security/cacerts" ]; then
      printf '%s\n' "$target/jre/lib/security/cacerts"
      return 0
    fi
    if [ -e "$target/lib/security/cacerts" ]; then
      printf '%s\n' "$target/lib/security/cacerts"
      return 0
    fi
  fi
  echo "jdk: path not found $target" >&2
  return 1
}

list_cacerts() {
  if [ -n "$jdk_paths" ]; then
    printf '%s\n' "$jdk_paths"
    return
  fi
  if [ -n "${JAVA_HOME:-}" ]; then
    printf '%s\n' "$JAVA_HOME"
  fi
  roots=""
  for root in /usr/lib/jvm /usr/java /opt/java /usr/local/java; do
    [ -d "$root" ] || continue
    roots="$roots $root"
  done
  if [ -n "$roots" ]; then
    # shellcheck disable=SC2086
    find $roots \( -path '*/lib/security/cacerts' \) \( -type f -o -type l \) 2>/dev/null || true
  fi
}

inode_of() {
  if stat -c '%d:%i' "$1" >/dev/null 2>&1; then
    stat -c '%d:%i' "$1"
  else
    stat -f '%d:%i' "$1"
  fi
}

cert_sha256() {
  keytool_bin=$1
  file=$2
  "$keytool_bin" -printcert -file "$file" | extract_sha256 | awk 'NR == 1 { print; exit }'
}

verify_bundle() {
  keytool_bin=$1
  while IFS= read -r row; do
    fp=${row%%  *}
    name=${row#*  }
    got=$(cert_sha256 "$keytool_bin" "$cert_dir/$name")
    if [ "$got" != "$fp" ]; then
      echo "bundle fingerprint mismatch for $name" >&2
      echo "expected $fp" >&2
      echo "got      ${got:-<none>}" >&2
      exit 1
    fi
  done < "$bundle_list"
}

pick_alias() {
  keytool_bin=$1
  ks=$2
  base=$3
  candidate=$base
  n=2
  while "$keytool_bin" -list -alias "$candidate" -keystore "$ks" -storepass "$pass" >/dev/null 2>&1; do
    candidate="${base}-${n}"
    n=$((n + 1))
    if [ "$n" -gt 20 ]; then
      echo "no free alias for $base in $ks" >&2
      exit 1
    fi
  done
  printf '%s\n' "$candidate"
}

store_sha256() {
  keytool_bin=$1
  ks=$2
  out=$3
  if ! "$keytool_bin" -list -v -keystore "$ks" -storepass "$pass" >"$work/keytool.out" 2>"$work/keytool.err"; then
    echo "jdk: cannot read $ks" >&2
    cat "$work/keytool.err" >&2
    exit 1
  fi
  extract_sha256 < "$work/keytool.out" > "$out"
  if [ ! -s "$out" ]; then
    echo "jdk: no SHA-256 fingerprints from keytool for $ks" >&2
    exit 1
  fi
}

missing=0
path_error=0
seen=" "
found=0
verified=0
imported_any=0

while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  if [ -d "$raw" ] || [ ! -e "$raw" ]; then
    if ! ks=$(resolve_cacerts "$raw"); then
      path_error=1
      continue
    fi
  else
    ks=$raw
  fi

  if [ ! -e "$ks" ]; then
    echo "jdk: missing $ks"
    path_error=1
    continue
  fi
  if [ -L "$ks" ]; then
    echo "jdk: skip symlink $ks -> $(readlink "$ks")"
    continue
  fi

  id=$(inode_of "$ks")
  case "$seen" in
    *" $id "*) continue ;;
  esac
  seen="$seen$id "

  jre=$(cd "$(dirname "$ks")/../../.." && pwd)
  java_bin=$jre/bin/java
  keytool_bin=$jre/bin/keytool
  if [ ! -x "$java_bin" ] || [ ! -x "$keytool_bin" ]; then
    echo "jdk: skip $ks (no java or keytool)"
    continue
  fi
  if ! "$java_bin" -version 2>&1 | grep -q 'version "1\.8'; then
    echo "jdk: skip $ks (not JDK 8)"
    continue
  fi

  printf '%s\t%s\n' "$ks" "$keytool_bin" >> "$ks_list"
  found=1
done <<EOF
$(list_cacerts)
EOF

if [ "$found" -eq 0 ]; then
  echo "jdk: no JDK 8 cacerts found"
  exit 1
fi

while IFS= read -r line; do
  ks=${line%%$'\t'*}
  keytool_bin=${line#*$'\t'}
  if [ "$verified" -eq 0 ]; then
    verify_bundle "$keytool_bin"
    verified=1
  fi

  store_fp=$work/store.fp
  store_sha256 "$keytool_bin" "$ks" "$store_fp"

  present_n=0
  missing_n=0
  imported_n=0
  while IFS= read -r row; do
    fp=${row%%  *}
    name=${row#*  }
    if grep -qx "$fp" "$store_fp"; then
      present_n=$((present_n + 1))
      continue
    fi
    missing_n=$((missing_n + 1))
    missing=1
    if [ "$check_only" -eq 1 ]; then
      echo "jdk: missing $ks $name"
      continue
    fi
    alias_name=$(pick_alias "$keytool_bin" "$ks" "${name%.crt}")
    if ! "$keytool_bin" -importcert -noprompt -trustcacerts \
      -alias "$alias_name" \
      -file "$cert_dir/$name" \
      -keystore "$ks" \
      -storepass "$pass" >"$work/import.out" 2>"$work/import.err"; then
      echo "jdk: import failed $ks $name" >&2
      cat "$work/import.out" "$work/import.err" >&2
      exit 1
    fi
    echo "jdk: imported $ks $name"
    imported_n=$((imported_n + 1))
    imported_any=1
  done < "$bundle_list"

  if [ "$check_only" -eq 1 ]; then
    echo "jdk: $ks present $present_n missing $missing_n"
  else
    echo "jdk: $ks imported $imported_n, already present $present_n"
  fi
done < "$ks_list"

if [ "$check_only" -eq 1 ] && [ "$missing" -ne 0 ]; then
  exit 1
fi

if [ "$path_error" -ne 0 ]; then
  exit 1
fi

if [ "$imported_any" -eq 1 ]; then
  echo "restart Java 8 processes before they trust the new certificates"
fi
