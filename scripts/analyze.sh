#!/usr/bin/env bash
# Analyze a track for key and BPM using keyfinder-cli and aubio.
#
# Usage:
#   ./analyze.sh <audio_file>
#
# Output: a JSON-like block with key (standard + camelot) and BPM.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <audio_file>"
  exit 1
fi

INPUT="$1"

if [[ ! -f "$INPUT" ]]; then
  echo "ERROR: file not found: $INPUT"
  exit 1
fi

KEY_STD="$(keyfinder-cli "$INPUT" 2>/dev/null || echo 'n/a')"
KEY_CAM="$(keyfinder-cli -n camelot "$INPUT" 2>/dev/null || echo 'n/a')"
BPM_RAW="$(aubio tempo "$INPUT" 2>/dev/null | head -1 | awk '{print $1}')"
BPM="${BPM_RAW:-n/a}"
BPM_HALF=""
BPM_DOUBLE=""
if [[ "$BPM" != "n/a" ]]; then
  BPM_HALF="$(awk "BEGIN {printf \"%.2f\", $BPM / 2}")"
  BPM_DOUBLE="$(awk "BEGIN {printf \"%.2f\", $BPM * 2}")"
fi

cat <<EOF
---
file:     $INPUT
key:      $KEY_STD
camelot:  $KEY_CAM
bpm:      $BPM   (half: $BPM_HALF  |  double: $BPM_DOUBLE)
---
EOF
