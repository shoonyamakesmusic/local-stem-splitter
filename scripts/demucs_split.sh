#!/usr/bin/env bash
# Split a reference track:
#   1. Demucs htdemucs_ft        -> stems/{drums,bass,vocals,other}.wav
#   2. LarsNet                   -> drums_split/{kick,snare,toms,hihat,cymbals}.wav
#   3. keyfinder-cli + aubio     -> analysis.txt (key, BPM)
#
# Usage:
#   ./demucs_split.sh <input.wav|.mp3|.flac|.m4a> [output_dir]

set -euo pipefail

VENV_BIN="$HOME/.venvs/demucs/bin"
DEMUCS="$VENV_BIN/demucs"
PYTHON="$VENV_BIN/python"
LARSNET_DIR="$HOME/.cache/larsnet"

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
echo "==> Splitting stems with Demucs (htdemucs_ft) on: $INPUT"
"$DEMUCS" -n htdemucs_ft -o "$STEMS_DIR/_raw" "$INPUT"

SRC="$STEMS_DIR/_raw/htdemucs_ft/$TRACK_NAME"
if [[ ! -d "$SRC" ]]; then
  echo "ERROR: expected demucs output at $SRC not found"
  exit 1
fi
mv "$SRC"/*.wav "$STEMS_DIR/"
rm -rf "$STEMS_DIR/_raw"
echo "    Stems: $STEMS_DIR/{drums,bass,vocals,other}.wav"

# 2. LarsNet ---------------------------------------------------
if [[ -f "$LARSNET_DIR/separate.py" && -f "$LARSNET_DIR/pretrained_larsnet_models/kick/pretrained_kick_unet.pth" ]]; then
  echo "==> Splitting drums with LarsNet..."
  # LarsNet rglobs a directory for .wav files — give it an isolated input dir.
  STAGING_IN="$DRUMS_DIR/_in"
  STAGING_OUT="$DRUMS_DIR/_raw"
  mkdir -p "$STAGING_IN"
  cp "$STEMS_DIR/drums.wav" "$STAGING_IN/drums.wav"
  (
    cd "$LARSNET_DIR"
    "$PYTHON" separate.py -i "$STAGING_IN" -o "$STAGING_OUT" -d cpu
  )
  # LarsNet writes <out>/<stem>/drums.wav — flatten to <drums_split>/<stem>.wav.
  for stem in kick snare toms hihat cymbals; do
    if [[ -f "$STAGING_OUT/$stem/drums.wav" ]]; then
      mv "$STAGING_OUT/$stem/drums.wav" "$DRUMS_DIR/$stem.wav"
    fi
  done
  rm -rf "$STAGING_IN" "$STAGING_OUT"
  echo "    Drum elements: $DRUMS_DIR/"
  ls "$DRUMS_DIR"/*.wav 2>/dev/null | sed 's/^/      /'
else
  echo "==> LarsNet not installed at $LARSNET_DIR — skipping drum-element split."
fi

# 3. Analysis --------------------------------------------------
if command -v keyfinder-cli >/dev/null 2>&1 && command -v aubio >/dev/null 2>&1; then
  echo "==> Analyzing key and BPM..."
  "$(dirname "$0")/analyze.sh" "$INPUT" | tee "$OUT_DIR/analysis.txt"
fi

echo "==> Done."
