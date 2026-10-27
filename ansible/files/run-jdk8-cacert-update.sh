#!/bin/bash
# Write the embedded cacert-update.bin and run it.
# BIN_B64 is the executable. CHECK_ONLY=1 adds --check.
# Remaining arguments are JDK homes or cacerts paths.
set -eu

if [ -z "${BIN_B64:-}" ]; then
  echo "BIN_B64 is required" >&2
  exit 2
fi

pass="${CACERTS_PASS:-changeit}"
check="${CHECK_ONLY:-0}"
bin=$(mktemp /tmp/cacert-update.XXXXXX.bin)
trap 'rm -f "$bin"' EXIT
printf '%s' "$BIN_B64" | base64 -d > "$bin"
chmod 755 "$bin"

paths=("$@")
cmd=("$bin")
if [ "$check" = "1" ]; then
  cmd+=("--check")
fi
for p in "${paths[@]}"; do
  [ -n "$p" ] || continue
  cmd+=("--jdk-path" "$p")
done

CACERTS_PASS="$pass" "${cmd[@]}"
