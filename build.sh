#!/bin/bash
# Build the gopeed-dl native binary from Ruby source with Spinel.
# One build per host OS/arch — run this on each target (or in CI per runner):
#   macOS (Intel or Apple Silicon), Linux x86_64/arm64: native
#   Windows: run under WSL (dependable) or MinGW-w64 (best effort), see spinel/docs/windows.md
set -euo pipefail
cd "$(dirname "$0")"

SPINEL="${SPINEL:-}"
if [ -z "$SPINEL" ]; then
  if [ -x "$HOME/Documents/KIMI_NIM/bin/spinel" ]; then
    SPINEL="$HOME/Documents/KIMI_NIM/bin/spinel"
  elif command -v spinel >/dev/null 2>&1; then
    SPINEL="$(command -v spinel)"
  else
    echo "spinel not found: build https://github.com/matz/spinel (make deps && make)" >&2
    echo "and pass SPINEL=/path/to/spinel" >&2
    exit 1
  fi
fi

os="$(uname -s)"
case "$os" in
  MINGW*|MSYS*|CYGWIN*) os="windows" ;;         # native Windows toolchain (MinGW/MSYS2)
  *) os="$(printf '%s' "$os" | tr '[:upper:]' '[:lower:]')" ;;  # darwin | linux
esac
arch="$(uname -m)"                              # x86_64 | arm64 | aarch64
case "$arch" in
  aarch64) arch="arm64" ;;                      # Linux reports aarch64; normalize to arm64
esac
mkdir -p bin
out="bin/gopeed-dl-${os}-${arch}"
"$SPINEL" src/gopeed_dl.rb -o "$out"
ln -sf "gopeed-dl-${os}-${arch}" bin/gopeed-dl
echo "built $out (bin/gopeed-dl -> $out)"
