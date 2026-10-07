#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
base="${1:-ubuntu:24.04}"
tag="${base//[:\/]/-}"
image="hy2-systemd-$tag"
name="hy2-it-$tag-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker build --build-arg "BASE=$base" -t "$image" -f tests/docker/Dockerfile.systemd tests/docker
docker run -d --name "$name" --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw -v "$(pwd):/src:ro" "$image" >/dev/null
docker exec "$name" bash -lc 'systemctl is-system-running --wait || true'
docker exec "$name" bash /src/tests/integration/lifecycle.sh /src
