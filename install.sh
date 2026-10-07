#!/usr/bin/env bash
# Hysteria2 + 3X-UI Server bootstrap.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/Humran13/Hysteria2-3X-UI-Server/main/install.sh)
#
# This script only fetches the project tree (verified against its SHA256SUMS), installs it to
# /opt/hysteria2-3x-ui-server and hands over to `hysteria2 install`, which does the real work.
# Everything after `install.sh` is passed through unchanged (except --ref REF, consumed here).
set -Eeuo pipefail

REPO="Humran13/Hysteria2-3X-UI-Server"
REF="${HY2_REF:-main}"
HOME_DIR="${HY2_HOME:-/opt/hysteria2-3x-ui-server}"
BIN_LINK="${HY2_BIN_LINK:-/usr/local/bin/hysteria2}"

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then R=$'\033[0;31m' G=$'\033[0;32m' B=$'\033[0;34m' Z=$'\033[0m'; else R="" G="" B="" Z=""; fi
info() { printf '%s\n' "${B}[*]${Z} $*" >&2; }
ok() { printf '%s\n' "${G}[+]${Z} $*" >&2; }
fail() {
    printf '%s\n' "${R}[x]${Z} $*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
BlueSoftKeys Hysteria2 + 3X-UI Server

  bash <(curl -fsSL https://raw.githubusercontent.com/Humran13/Hysteria2-3X-UI-Server/main/install.sh)
  bash <(curl -fsSL https://raw.githubusercontent.com/Humran13/Hysteria2-3X-UI-Server/main/install.sh) -- [options]

Options (passed to `hysteria2 install`):
  --port PORT   --server-address ADDR   --sni HOST   --client-name NAME
  --tls-cert FILE   --tls-key FILE   --panel-version vX.Y.Z   --allow-unsupported-os
  --non-interactive   --verbose   --help   --version
Bootstrap-only: --ref REF (install a specific git tag/branch of this project; default: main)
Full documentation: https://github.com/Humran13/Hysteria2-3X-UI-Server
EOF
}

# ---- argument scan: handle --help / --version / --ref locally, pass the rest through ----
args=()
while (($#)); do
    case "$1" in
        --ref)
            [[ -n "${2:-}" ]] || fail "--ref needs a value"
            REF="$2"
            shift 2
            ;;
        --ref=*)
            REF="${1#--ref=}"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            args+=("$1")
            shift
            ;;
    esac
done
[[ "$REF" =~ ^[A-Za-z0-9._/-]{1,100}$ ]] || fail "invalid --ref"

# ---- run from a local checkout when possible ----
script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [[ -n "$script_dir" && -f "$script_dir/lib/common.sh" && -x "$script_dir/bin/hysteria2" ]]; then
    info "Using the local checkout at $script_dir"
    exec "$script_dir/bin/hysteria2" install ${args[@]+"${args[@]}"}
fi

((EUID == 0)) || fail "please run as root:  curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sudo bash"
[[ "$(uname -s)" == "Linux" ]] || fail "Linux only"

need_pkgs=()
command -v curl >/dev/null 2>&1 || need_pkgs+=(curl)
command -v tar >/dev/null 2>&1 || need_pkgs+=(tar)
command -v sha256sum >/dev/null 2>&1 || need_pkgs+=(coreutils)
[[ -d /etc/ssl/certs ]] || need_pkgs+=(ca-certificates)
if ((${#need_pkgs[@]})); then
    command -v apt-get >/dev/null 2>&1 || fail "missing tools (${need_pkgs[*]}) and apt-get is unavailable"
    info "Installing prerequisites: ${need_pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q >/dev/null 2>&1 || true
    apt-get install -y -q --no-install-recommends "${need_pkgs[@]}" >/dev/null 2>&1 || fail "could not install ${need_pkgs[*]}"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/hy2-bootstrap.XXXXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT

# ---- download ----
info "Downloading $REPO@$REF ..."
url="https://codeload.github.com/$REPO/tar.gz/$REF"
if [[ "${HY2_TEST_MODE:-0}" == "1" && -n "${HY2_SELF_TARBALL_URL:-}" ]]; then
    url="$HY2_SELF_TARBALL_URL" # test-suite only
fi
curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 180 "$url" -o "$tmp/src.tgz" ||
    fail "download failed ($url). Check the ref '$REF' and your network."
mkdir "$tmp/src"
tar -xzf "$tmp/src.tgz" -C "$tmp/src" --strip-components=1 --no-same-owner || fail "downloaded archive is corrupt"

# ---- verify ----
[[ -f "$tmp/src/VERSION" && -x "$tmp/src/bin/hysteria2" && -d "$tmp/src/lib" ]] || fail "downloaded archive is not a complete project tree"
[[ -f "$tmp/src/SHA256SUMS" ]] || fail "SHA256SUMS missing in the downloaded tree"
(cd "$tmp/src" && sha256sum -c --quiet SHA256SUMS >/dev/null 2>&1) || fail "checksum verification failed; refusing to install"
for f in "$tmp/src/bin/hysteria2" "$tmp/src"/lib/*.sh; do
    bash -n "$f" || fail "syntax check failed: $f"
done
ver="$(tr -d '[:space:]' <"$tmp/src/VERSION")"
ok "Downloaded and verified wrapper $ver"

# ---- install atomically ----
stage="$HOME_DIR.new.$$"
old="$HOME_DIR.old.$$"
mkdir -p "$(dirname "$HOME_DIR")"
rm -rf "$stage"
mkdir -p "$stage"
cp -a "$tmp/src/bin" "$tmp/src/lib" "$tmp/src/VERSION" "$tmp/src/SHA256SUMS" "$stage/"
for extra in LICENSE NOTICE.md README.md; do
    [[ -f "$tmp/src/$extra" ]] && cp -a "$tmp/src/$extra" "$stage/"
done
chmod -R go-w "$stage"
if [[ -e "$HOME_DIR" ]]; then mv "$HOME_DIR" "$old"; fi
if ! mv "$stage" "$HOME_DIR"; then
    [[ -e "$old" ]] && mv "$old" "$HOME_DIR"
    fail "could not install into $HOME_DIR"
fi
rm -rf "$old"
ln -sfn "$HOME_DIR/bin/hysteria2" "$BIN_LINK"

# ---- hand over (stdin: keep a real terminal; under `curl | bash` reattach /dev/tty when possible) ----
info "Starting the installer..."
if [[ -t 0 ]]; then
    exec "$HOME_DIR/bin/hysteria2" install ${args[@]+"${args[@]}"}
elif [[ -c /dev/tty && ( -t 1 || -t 2 ) ]]; then
    exec "$HOME_DIR/bin/hysteria2" install ${args[@]+"${args[@]}"} </dev/tty
else
    exec "$HOME_DIR/bin/hysteria2" install ${args[@]+"${args[@]}"} </dev/null
fi
