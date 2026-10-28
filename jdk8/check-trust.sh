#!/bin/bash
# Fetch the seven direct chains, then verify them with a JDK 8 image.
# This is not part of build.sh. build.sh only packs cacert-update.bin.
set -eu
set -o pipefail

here=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
repo=$(CDPATH= cd -- "$here/.." && pwd)
image="${JDK8_IMAGE:-tcr.chinawayltd.com/g7-base/java:jaeger-8u201-v0.8}"
fetch_image="${CENTOS6_IMAGE:-centos:6}"
platform="${DOCKER_PLATFORM:-linux/amd64}"

usage() {
  cat <<EOF
Usage: check-trust.sh

Copy a JDK 8 cacerts, import the bundled roots, and PKIX-check the seven
direct chains. The other 15 roots are checked by fingerprint only.

  -h, --help    show this help

Environment:
  JDK8_IMAGE       JDK 8 image (default: $image)
  CENTOS6_IMAGE    CentOS 6 image used to fetch chains (default: $fetch_image)
  DOCKER_PLATFORM  docker platform (default: $platform)
  CACERTS_PASS     cacerts password (default: changeit)

Examples:
  bash jdk8/check-trust.sh
  JDK8_IMAGE=tcr.chinawayltd.com/g7-base/java:jaeger-8u201-v0.8 bash jdk8/check-trust.sh
  CENTOS6_IMAGE=docker.syscube.dev/centos:6 bash jdk8/check-trust.sh
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      echo "  bash jdk8/check-trust.sh" >&2
      exit 2
      ;;
  esac
  shift
done

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found" >&2
  echo "  bash jdk8/check-trust.sh" >&2
  exit 1
fi

chains=$(mktemp -d "${TMPDIR:-/tmp}/jdk8-chains.XXXXXX")
trap 'rm -rf "$chains"' EXIT

docker run --rm --platform "$platform" \
  -v "$repo/packages/centos6:/src:ro" \
  -v "$chains:/out" \
  "$fetch_image" \
  bash /src/fetch-chains.sh /out

docker run --rm --platform "$platform" --entrypoint bash \
  -v "$repo:/src:ro" \
  -v "$chains:/chains:ro" \
  -e CACERTS_PASS \
  "$image" \
  /src/jdk8/check-trust-inside.sh --chains /chains
