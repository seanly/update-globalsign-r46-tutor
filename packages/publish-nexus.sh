#!/bin/bash
# Upload RPM files to a Nexus 3 yum hosted repository.
# Do not point this at a proxy or group repository.
set -eu

repository="${NEXUS_REPOSITORY:-yum-el6}"

if [ -z "${NEXUS_URL:-}" ] || [ -z "${NEXUS_USER:-}" ] || [ -z "${NEXUS_PASSWORD:-}" ] || [ "$#" -lt 1 ]; then
  echo "usage: NEXUS_URL=https://nexus.example.com NEXUS_USER=... NEXUS_PASSWORD=... [NEXUS_REPOSITORY=yum-el6] $0 rpm [rpm...]" >&2
  exit 2
fi

base="${NEXUS_URL%/}"

for rpm in "$@"; do
  if [ ! -f "$rpm" ]; then
    echo "not a file: $rpm" >&2
    exit 1
  fi
  case "$rpm" in
    *.rpm) ;;
    *)
      echo "not an rpm: $rpm" >&2
      exit 1
      ;;
  esac
  echo "upload $(basename "$rpm") to ${base} repository ${repository}"
  curl -fsS --user "${NEXUS_USER}:${NEXUS_PASSWORD}" \
    -X POST \
    "${base}/service/rest/v1/components?repository=${repository}" \
    -F "yum.asset=@${rpm};filename=$(basename "$rpm")"
  echo
done
