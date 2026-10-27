#!/bin/bash
# Build el6-ca-trust-extras for CentOS 6 and install it in a throwaway container.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
image="${CENTOS6_IMAGE:-docker.syscube.dev/centos:6}"
platform="${DOCKER_PLATFORM:-linux/amd64}"

mkdir -p "$here/RPMS"
rm -f "$here/RPMS/"*.rpm

docker run --rm --platform "$platform" \
  -v "$root:/src:ro" \
  -v "$here/RPMS:/out" \
  "$image" \
  bash /src/packages/centos6/build-inside.sh
