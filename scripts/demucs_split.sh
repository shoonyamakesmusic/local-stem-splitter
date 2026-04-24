#!/usr/bin/env bash
# Split a reference track into stems using Demucs (htdemucs_ft) and the drums
# stem into kick/snare/hihat/toms/cymbals using Drumsep.
#
# Usage:
#   ./demucs_split.sh <input.wav|.mp3|.flac|.m4a> [output_dir]
#
# Default output_dir: <input_dir>/  (writes ./stems and ./drums_split next to input)
#
# Examples:
#   ./demucs_split.sh "Songs/track.wav"
#   ./demucs_split.sh "Songs/track.wav" "_GENRE_TEMPLATE/01_References/Track_01"

set -euo pipefail

VENV_BIN="$HOME/.venvs/demucs/bin"
DEMUCS="$VENV_BIN/demucs"
DRUMSEP_MODEL_DIR="$HOME/.cache/drumsep/model"
DRUMSEP_SIG="49469ca8"

if [[ ! -x "$DEMUCS" ]]; then
  echo "ERROR: demucs not found at $DEMUCS"
  echo "Install with: python3.11 -m venv ~/.venvs/demucs && ~/.venvs/demucs/bin/pip install demucs"
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

if [[ -f "$DRUMSEP_MODEL_DIR/$DRUMSEP_SIG.th" ]]; then
  echo "==> Splitting drum stem with DrumSep (inagoy/drumsep model)..."
  "$DEMUCS" --repo "$DRUMSEP_MODEL_DIR" -n "$DRUMSEP_SIG" -o "$DRUMS_DIR/_raw" "$STEMS_DIR/drums.wav"
  DRUMSEP_SRC="$DRUMS_DIR/_raw/$DRUMSEP_SIG/drums"
  if [[ -d "$DRUMSEP_SRC" ]]; then
    mv "$DRUMSEP_SRC"/*.wav "$DRUMS_DIR/"
    rm -rf "$DRUMS_DIR/_raw"
    # Rename Spanish -> English (bombo=kick, redoblante=snare, platillos=cymbals)
    [[ -f "$DRUMS_DIR/bombo.wav" ]] && mv "$DRUMS_DIR/bombo.wav" "$DRUMS_DIR/kick.wav"
    [[ -f "$DRUMS_DIR/redoblante.wav" ]] && mv "$DRUMS_DIR/redoblante.wav" "$DRUMS_DIR/snare.wav"
    [[ -f "$DRUMS_DIR/platillos.wav" ]] && mv "$DRUMS_DIR/platillos.wav" "$DRUMS_DIR/cymbals.wav"
    echo "    Drum elements: $DRUMS_DIR/"
    ls "$DRUMS_DIR"/*.wav 2>/dev/null | sed 's/^/      /'
  else
    echo "    WARN: expected drumsep output at $DRUMSEP_SRC not found"
  fi
else
  echo "==> DrumSep model not found at $DRUMSEP_MODEL_DIR/$DRUMSEP_SIG.th — skipping drum-element split."
fi

if command -v keyfinder-cli >/dev/null 2>&1 && command -v aubio >/dev/null 2>&1; then
  echo "==> Analyzing key and BPM..."
  "$(dirname "$0")/analyze.sh" "$INPUT" | tee "$OUT_DIR/analysis.txt"
fi

echo "==> Done."
