#!/usr/bin/env bash
# Full pipeline: audio file -> stems + drum-element splits + key/BPM analysis
# + Ableton Live project with all stems imported, tempo + key set.
#
# Usage:
#   ./split.sh [--high-quality] <audio_file> [output_folder]
#
# Output (default): the input file's parent directory (so stems land alongside
# the source). Pass a second arg to override.
#
# Flags:
#   --high-quality   Use Demucs htdemucs_ft (bag-of-4, ~4x slower, ~0.6 dB better
#                    drums SDR). Default is htdemucs (single model).
#
# Environment variables:
#   TEMPLATE_ALS     override path to Ableton template (default: ./template/Empty.als)
#   DEMUCS_MODEL     override Demucs model (default: htdemucs)
#   DEMUCS_DEVICE    override compute device ("mps" on Apple Silicon, else "cpu")

set -euo pipefail

note()  { printf "    \033[2m%s\033[0m\n" "$*"; }
step()  { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
warn()  { printf "    \033[33m!\033[0m %s\n" "$*"; }

# Parse flags
HIGH_QUALITY=0
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --high-quality|-H) HIGH_QUALITY=1; shift ;;
    -h|--help) POSITIONAL=(); break ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL[@]}"

if [[ $# -lt 1 ]]; then
  cat <<EOF
Usage: $0 [--high-quality] <audio_file> [output_folder]

Output goes into the input file's parent directory by default
(pass an explicit output folder to override):
  stems/{drums,bass,vocals,other}.wav                (Demucs)
  drums_split/{kick,snare,toms,hihat,ride,crash}.wav (MDX23C)
  analysis.txt                                        (key + BPM)
  Ableton Project/<name>.als                          (Live 12, tempo + key set)

Flags:
  --high-quality  Use Demucs htdemucs_ft bag-of-4 model (~4x slower,
                  marginally better drum SDR). Default is htdemucs single model
                  with MPS acceleration on Apple Silicon.

Env vars:
  TEMPLATE_ALS   path to Ableton template .als (default: ./template/Empty.als)
  DEMUCS_MODEL   override Demucs model (default: htdemucs)
  DEMUCS_DEVICE  override compute device (auto: mps on Apple Silicon, else cpu)
EOF
  exit 1
fi

INPUT="$1"
if [[ ! -f "$INPUT" ]]; then
  echo "ERROR: file not found: $INPUT" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS_DIR="$REPO_DIR/scripts"

BASE_NAME="$(basename "${INPUT%.*}")"
INPUT_ABS="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
OUT_DIR="${2:-$(dirname "$INPUT_ABS")}"

TEMPLATE_ALS="${TEMPLATE_ALS:-$REPO_DIR/template/Empty.als}"
if [[ ! -f "$TEMPLATE_ALS" ]]; then
  cat <<EOF >&2
ERROR: Ableton template not found at:
  $TEMPLATE_ALS

Create one (see README):
  1. Open Ableton Live, new empty set.
  2. Drag one audio file in.
  3. Save As -> $TEMPLATE_ALS

Or set TEMPLATE_ALS=/path/to/your.als to point elsewhere.
EOF
  exit 1
fi

if [[ "$HIGH_QUALITY" == "1" ]]; then
  export DEMUCS_MODEL="htdemucs_ft"
fi

step "Target output: $OUT_DIR"
mkdir -p "$OUT_DIR"

# 1. Stems + drum elements + analysis
"$SCRIPTS_DIR/demucs_split.sh" "$INPUT" "$OUT_DIR"

# 2. Read analysis
ANALYSIS_FILE="$OUT_DIR/analysis.txt"
KEY=""
BPM=""
if [[ -f "$ANALYSIS_FILE" ]]; then
  KEY="$(grep -E '^key:' "$ANALYSIS_FILE" | awk '{print $2}' || true)"
  BPM="$(grep -E '^bpm:' "$ANALYSIS_FILE" | awk '{print $2}' || true)"
fi

# 3. Build .als
step "Building Ableton project"
ALS_DIR="$OUT_DIR/Ableton Project"
mkdir -p "$ALS_DIR"
ALS_PATH="$ALS_DIR/${BASE_NAME}.als"

BUILD_ARGS=()
[[ -n "$BPM" && "$BPM" != "n/a" ]] && BUILD_ARGS+=(--tempo "$BPM")
[[ -n "$KEY" && "$KEY" != "n/a" ]] && BUILD_ARGS+=(--key "$KEY")

"$HOME/.venvs/demucs/bin/python" "$SCRIPTS_DIR/build_als.py" \
  "$TEMPLATE_ALS" \
  "$OUT_DIR" \
  "$ALS_PATH" \
  "${BUILD_ARGS[@]}"

# 4. Summary
step "Done."
cat <<EOF
    Stems:       $OUT_DIR/stems/
    Drum splits: $OUT_DIR/drums_split/
    Analysis:    $ANALYSIS_FILE
    Ableton:     $ALS_PATH

EOF

if [[ -n "$BPM" && "$BPM" != "n/a" ]]; then
  warn "BPM $BPM was auto-detected. aubio sometimes reports 2x the real tempo;"
  warn "if it feels wrong, halve/double it in Live after opening."
fi
