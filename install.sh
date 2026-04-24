#!/usr/bin/env bash
# One-time setup for local-stem-splitter.
# Idempotent — safe to re-run anytime.
#
# Usage: ./install.sh

set -euo pipefail

VENV="$HOME/.venvs/demucs"
VENV_BIN="$VENV/bin"
LARSNET_DIR="$HOME/.cache/larsnet"
LARSNET_GDRIVE_ID="1U8-5924B1ii1cjv9p0MTPzayb00P4qoL"
KEYFINDER_CLI_REPO="https://github.com/EvanPurkhiser/keyfinder-cli.git"

note()  { printf "    \033[2m%s\033[0m\n" "$*"; }
step()  { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
ok()    { printf "    \033[32m✓\033[0m %s\n" "$*"; }
warn()  { printf "    \033[33m!\033[0m %s\n" "$*"; }

if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "This script is designed for macOS. Linux support is untested — proceed at your own risk."
fi

# 1. Homebrew
step "Homebrew"
if ! command -v brew >/dev/null 2>&1; then
  echo "Installing Homebrew (may prompt for password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
  ok "Homebrew present"
fi

# 2. Homebrew packages
step "Homebrew packages"
BREW_PKGS=(python@3.11 ffmpeg aubio libkeyfinder pkg-config cmake)
for pkg in "${BREW_PKGS[@]}"; do
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    note "[already] $pkg"
  else
    echo "  installing $pkg ..."
    brew install "$pkg"
  fi
done
ok "brew packages ready"

# 3. Python venv
step "Python venv (demucs, torchcodec, soundfile, gdown)"
if [[ ! -x "$VENV_BIN/demucs" ]]; then
  python3.11 -m venv "$VENV"
  "$VENV_BIN/pip" install --upgrade pip >/dev/null
  "$VENV_BIN/pip" install demucs torchcodec soundfile gdown
  ok "venv created at $VENV"
else
  note "[already] $VENV"
  "$VENV_BIN/python" -c "import torchcodec" 2>/dev/null || "$VENV_BIN/pip" install torchcodec
  "$VENV_BIN/python" -c "import soundfile" 2>/dev/null || "$VENV_BIN/pip" install soundfile
  "$VENV_BIN/python" -c "import gdown"      2>/dev/null || "$VENV_BIN/pip" install gdown
  ok "venv OK"
fi

# 4. LarsNet (repo + 540 MB pretrained weights)
step "LarsNet (drum-element separation)"
if [[ -f "$LARSNET_DIR/pretrained_larsnet_models/kick/pretrained_kick_unet.pth" ]]; then
  note "[already] $LARSNET_DIR"
else
  rm -rf "$LARSNET_DIR"
  git clone --depth 1 https://github.com/polimi-ispl/larsnet.git "$LARSNET_DIR" >/dev/null 2>&1
  (
    cd "$LARSNET_DIR"
    "$VENV_BIN/gdown" "$LARSNET_GDRIVE_ID" -O weights.zip
    unzip -q weights.zip
    rm weights.zip
  )
  ok "LarsNet installed at $LARSNET_DIR"
fi

# 5. keyfinder-cli from source (not available as a brew formula)
step "keyfinder-cli (build from source)"
if command -v keyfinder-cli >/dev/null 2>&1; then
  note "[already] $(command -v keyfinder-cli)"
else
  BUILD_DIR="$(mktemp -d)"
  trap 'rm -rf "$BUILD_DIR"' EXIT
  git clone --depth 1 "$KEYFINDER_CLI_REPO" "$BUILD_DIR" >/dev/null 2>&1
  (
    cd "$BUILD_DIR"
    mkdir -p build && cd build
    cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/homebrew .. >/dev/null
    make -j4 >/dev/null
  )
  cp "$BUILD_DIR/build/keyfinder-cli" /opt/homebrew/bin/keyfinder-cli
  trap - EXIT
  rm -rf "$BUILD_DIR"
  ok "built and installed"
fi

# 6. Smoke tests
step "Smoke tests"
"$VENV_BIN/demucs" --help >/dev/null 2>&1 && ok "demucs"          || warn "demucs broken"
[[ -f "$LARSNET_DIR/separate.py" ]]        && ok "larsnet"         || warn "larsnet missing"
command -v aubio         >/dev/null        && ok "aubio"           || warn "aubio missing"
command -v keyfinder-cli >/dev/null        && ok "keyfinder-cli"   || warn "keyfinder-cli missing"
command -v ffmpeg        >/dev/null        && ok "ffmpeg"          || warn "ffmpeg missing"

echo ""
step "Install complete."
cat <<'EOF'

One-time manual step — create the Ableton template:

  1. Open Ableton Live, new empty set.
  2. Drag one audio file into the set (any short wav works).
  3. Save As -> template/Empty.als  (relative to this repo)

Then to process a song:
  ./split.sh path/to/yourtrack.m4a

See README.md for details.
EOF
