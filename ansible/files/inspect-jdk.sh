#!/bin/bash
# Report JDK 8 cacerts files and listening Java processes. Does not change the host.
set -eu

work=$(mktemp -d "${TMPDIR:-/tmp}/jdk-inspect.XXXXXX")
trap 'rm -rf "$work"' EXIT
candidates=$work/candidates.txt
seen=$work/seen.txt
: > "$candidates"
: > "$seen"

if [ -n "${JAVA_HOME:-}" ]; then
  printf '%s\n' "$JAVA_HOME" >> "$candidates"
fi

roots=""
for root in /usr/lib/jvm /usr/java /opt/java /usr/local/java; do
  [ -d "$root" ] || continue
  roots="$roots $root"
done
if [ -n "$roots" ]; then
  # shellcheck disable=SC2086
  find $roots \( -path '*/lib/security/cacerts' \) \( -type f -o -type l \) >> "$candidates" 2>/dev/null || true
fi

resolve_cacerts() {
  target=$1
  if [ -f "$target" ] || [ -L "$target" ]; then
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
  return 1
}

jdk_found=0
while IFS= read -r raw; do
  [ -n "$raw" ] || continue
  if ! ks=$(resolve_cacerts "$raw"); then
    continue
  fi
  if grep -Fxq "$ks" "$seen"; then
    continue
  fi
  printf '%s\n' "$ks" >> "$seen"
  if [ ! -e "$ks" ] && [ ! -L "$ks" ]; then
    continue
  fi

  if ! jre=$(cd "$(dirname "$ks")/../../.." && pwd); then
    continue
  fi
  java_bin=$jre/bin/java
  if [ ! -x "$java_bin" ]; then
    continue
  fi
  ver_out=$("$java_bin" -version 2>&1 || true)
  printf '%s\n' "$ver_out" | grep -q 'version "1\.8' || continue
  ver=$(printf '%s\n' "$ver_out" | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1)

  if [ -L "$ks" ]; then
    kind="symlink $(readlink "$ks")"
  else
    kind=file
  fi
  echo "jdk: $ks version ${ver:-unknown} $kind"
  jdk_found=1
done < "$candidates"

if [ "$jdk_found" -eq 0 ]; then
  echo "jdk: none"
fi

ps -eo pid=,user=,args= > "$work/ps.txt" 2>/dev/null || : > "$work/ps.txt"
if command -v ss >/dev/null 2>&1 && ss -lntp > "$work/listen.txt" 2>/dev/null; then
  :
elif command -v netstat >/dev/null 2>&1 && netstat -lntp > "$work/listen.txt" 2>/dev/null; then
  :
else
  : > "$work/listen.txt"
fi

awk -v listeners="$work/listen.txt" '
BEGIN {
  while ((getline line < listeners) > 0) {
    n = split(line, f, " ")
    if (n < 4) continue
    local = f[4]
    pid = ""
    if (match(line, /pid=[0-9]+/)) {
      pid = substr(line, RSTART + 4, RLENGTH - 4)
    } else if (match(f[n], /^[0-9]+\//)) {
      pid = substr(f[n], 1, RLENGTH - 1)
    }
    if (pid == "" || local == "" || index(local, ":") == 0) continue
    key = pid SUBSEP local
    if (key in seen_addr) continue
    seen_addr[key] = 1
    if (pid in addrs) addrs[pid] = addrs[pid] "\n" local
    else addrs[pid] = local
  }
  close(listeners)
  found = 0
}
NF < 3 { next }
{
  pid = $1
  user = $2
  args = $3
  for (i = 4; i <= NF; i++) args = args " " $i
  base = $3
  sub(/.*\//, "", base)
  if (base != "java") next
  found = 1
  if (pid in addrs) {
    n = split(addrs[pid], list, "\n")
    for (i = 1; i <= n; i++) print "proc: " pid " " user " " list[i] " " args
  } else {
    print "proc: " pid " " user " - " args
  }
}
END {
  if (!found) print "proc: none"
}
' "$work/ps.txt"
