#!/usr/bin/env bash
# Run the unit + static suite in the disposable dev image (Docker). On CI/Linux you can run `bats tests/unit` directly.
set -Eeuo pipefail
export MSYS_NO_PATHCONV=1
cd "$(dirname "$0")/.."
docker image inspect bsk-dev >/dev/null 2>&1 || docker build -q -t bsk-dev -f tests/docker/Dockerfile.dev tests/docker >/dev/null
bash tools/gen-sums.sh >/dev/null
root="$(pwd -W 2>/dev/null || pwd)"
docker run --rm -v "$root:/repo" -w /repo bsk-dev bash -c 'cp -r /repo /tmp/work && cd /tmp/work && chmod +x install.sh bin/hysteria2 tools/*.sh && bats "$@"' _ "${@:-tests/unit}"
