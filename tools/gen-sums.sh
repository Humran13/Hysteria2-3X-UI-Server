#!/usr/bin/env bash
# Regenerate SHA256SUMS for the files the installer copies (bin/, lib/, VERSION). Run before every commit that changes them
# (CI verifies it is current). install.sh and the self-updater verify this manifest after download to catch corruption
# or a partial/mixed download.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
LC_ALL=C find bin lib -type f | LC_ALL=C sort | { cat; echo VERSION; } | xargs sha256sum >SHA256SUMS
echo "SHA256SUMS updated ($(wc -l <SHA256SUMS) files)"
