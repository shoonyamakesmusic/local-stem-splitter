#!/usr/bin/env bash
# Split a reference track:
#   1. Demucs htdemucs_ft        -> stems/{drums,bass,vocals,other}.wav
#   2. MDX23C (audio-separator)  -> drums_split/{kick,snare,toms,hihat,ride,crash}.wav
#   3. keyfinder-cli + aubio     -> analysis.txt (key, BPM)
#
# Usage:
#   ./demucs_split.sh <input.wav|.mp3|.flac|.m4a> [output_dir]

set -euo pipefail

VENV_BIN="$HOME/.venvs/demucs/bin"
DEMUCS="$VENV_BIN/demucs"
PYTHON="$VENV_BIN/python"
MDX23C_MODEL="MDX23C-DrumSep-aufr33-jarredou.ckpt"

# Demucs model + device (env-overridable).
#   DEMUCS_MODEL: "htdemucs" (default, fast, single model) or
#                 "htdemucs_ft" (bag-of-4, ~4x slower, ~0.6 dB better SDR).
#   DEMUCS_DEVICE: "mps" on Apple Silicon, "cpu" elsewhere (auto-detected).
DEMUCS_MODEL="${DEMUCS_MODEL:-htdemucs}"
if [[ -z "${DEMUCS_DEVICE:-}" ]]; then
  if [[ "$(uname -s)" == "Darwin" && "$(uname -m)" == "arm64" ]]; then
    DEMUCS_DEVICE="mps"
  else
    DEMUCS_DEVICE="cpu"
  fi
fi
# Allow MPS fallback for any op PyTorch hasn't implemented yet on Metal.
export PYTORCH_ENABLE_MPS_FALLBACK=1

if [[ ! -x "$DEMUCS" ]]; then
  echo "ERROR: demucs not found at $DEMUCS — run install.sh first."
  exit 1
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <input_audio_file> [output_dir]"
  exit 1
fi

INPUT="$1"
OUT_DIR="${2:-$(dirname "$INPUT")}"
STEMS_DIR="$OUT_DIR/stems"
DRUMS_DIR="$OUT_DIR/drums_split"
TRACK_NAME="$(basename "${INPUT%.*}")"

mkdir -p "$STEMS_DIR" "$DRUMS_DIR"

# 1. Demucs ----------------------------------------------------
echo "==> Splitting stems with Demucs ($DEMUCS_MODEL, device=$DEMUCS_DEVICE) on: $INPUT"
"$DEMUCS" -n "$DEMUCS_MODEL" -d "$DEMUCS_DEVICE" -o "$STEMS_DIR/_raw" "$INPUT"

SRC="$STEMS_DIR/_raw/$DEMUCS_MODEL/$TRACK_NAME"
if [[ ! -d "$SRC" ]]; then
  echo "ERROR: expected demucs output at $SRC not found"
  exit 1
fi
mv "$SRC"/*.wav "$STEMS_DIR/"
rm -rf "$STEMS_DIR/_raw"
echo "    Stems: $STEMS_DIR/{drums,bass,vocals,other}.wav"

# 2. MDX23C via audio-separator -------------------------------
echo "==> Splitting drums with MDX23C (audio-separator)..."
STAGING="$DRUMS_DIR/_raw"
mkdir -p "$STAGING"
"$PYTHON" - "$STEMS_DIR/drums.wav" "$STAGING" "$MDX23C_MODEL" <<'PY'
import sys
from audio_separator.separator import Separator
drums_wav, out_dir, model = sys.argv[1], sys.argv[2], sys.argv[3]
sep = Separator(output_dir=out_dir, output_format="WAV", log_level=30)
sep.load_model(model_filename=model)
sep.separate(drums_wav)
PY

# Flatten audio-separator's output naming:
#   drums_(kick)_MDX23C-...wav -> kick.wav, etc.
#   `hh` is renamed to `hihat` for clarity.
for raw in "$STAGING"/drums_\(*\)_*.wav; do
  [[ -e "$raw" ]] || continue
  stem="$(basename "$raw" | sed -E 's/^drums_\(([^)]+)\)_.*/\1/')"
  case "$stem" in
    hh) stem="hihat" ;;
  esac
  mv "$raw" "$DRUMS_DIR/$stem.wav"
done
rm -rf "$STAGING"
echo "    Drum elements: $DRUMS_DIR/"
ls "$DRUMS_DIR"/*.wav 2>/dev/null | sed 's/^/      /'

# 3. Analysis --------------------------------------------------
if command -v keyfinder-cli >/dev/null 2>&1 && command -v aubio >/dev/null 2>&1; then
  echo "==> Analyzing key and BPM..."
  "$(dirname "$0")/analyze.sh" "$INPUT" | tee "$OUT_DIR/analysis.txt"
fi

echo "==> Done."
