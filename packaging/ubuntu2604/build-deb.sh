#!/usr/bin/env bash
# 在 Ubuntu 26.04 amd64 容器里打包，并在干净容器里安装验证。
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${DIST_DIR:-${root}/dist}"
version="${DEB_VERSION:?}"
mkdir -p "${out}"
rm -f "${out}"/*.deb "${out}/NOTES.md"

docker run --rm --platform linux/amd64 \
  -e DEB_VERSION="${version}" \
  -e UPSTREAM_SHA="${UPSTREAM_SHA:?}" \
  -e RELEASE_TAG="${RELEASE_TAG:?}" \
  -v "${root}:/src:ro" \
  -v "${out}:/out" \
  ubuntu:26.04 \
  bash /src/packaging/ubuntu2604/inner-build.sh

deb="${out}/cosfs_${version}_amd64.deb"
test -f "${deb}"

docker run --rm --platform linux/amd64 \
  -v "${deb}:/tmp/cosfs.deb:ro" \
  ubuntu:26.04 \
  bash -lc 'set -eux
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y /tmp/cosfs.deb
    /usr/local/bin/cosfs --version
  '
echo "package ok ${deb}"
