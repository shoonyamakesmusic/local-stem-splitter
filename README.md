# local-stem-splitter

Drop in an audio file, get back:

- 4 stems (drums, bass, vocals, other) via Demucs
- 5 drum elements (kick, snare, toms, hihat, cymbals) via LarsNet
- Key and BPM analysis
- An Ableton Live 12 project with all 9 tracks imported, named, aligned, tempo and key set — ready to open

All runs locally on your Mac. No uploads, no subscriptions.

## Intended use

For producers who want to study reference tracks quickly — reverse-engineer arrangements, isolate drum character, source sample ideas. **Not** for redistributing stems or commercial use of separated content. Use responsibly.

## Requirements

- macOS (Apple Silicon or Intel)
- ~2 GB free disk space for Python env + models
- Ableton Live 12 (tested on 12.3.7) to open the generated project
- A Google Drive–accessible internet connection on first install (for the DrumSep model)

Linux is untested; the `install.sh` uses `brew` and macOS-specific `sed` flags. PRs welcome.

## Install

```bash
git clone https://github.com/shoonyamakesmusic/local-stem-splitter.git
cd local-stem-splitter
./install.sh
```

Cold install runs in roughly 5–10 minutes (Homebrew + PyTorch + model download). Re-running `install.sh` later is safe — it skips anything already in place.

### One-time manual step — the Ableton template

The `.als` generator needs a seed template so it can clone its track structure. Ableton's project XML varies across versions, so the cleanest approach is to have you create one from your own Live install:

1. Open Ableton Live → **File → New Live Set**.
2. Drag any audio file into the set (any short wav is fine — it won't be used, just needed for structure).
3. **File → Save As** → save to `template/Empty.als` inside this repo.

That's it. You only do this once. The tool overwrites the template's tempo, key, and track contents when generating each new project.

## Usage

```bash
./split.sh path/to/yoursong.m4a
```

Supported inputs: `.wav`, `.mp3`, `.m4a`, `.flac`.

Output (by default, in your current directory):

```
<songname>_Splits/
├── stems/
│   ├── drums.wav
│   ├── bass.wav
│   ├── vocals.wav
│   └── other.wav
├── drums_split/
│   ├── kick.wav
│   ├── snare.wav
│   ├── toms.wav
│   ├── hihat.wav
│   └── cymbals.wav
├── analysis.txt
└── Ableton Project/
    └── <songname>.als
```

Open the `.als` in Ableton Live 12 — you'll see 9 audio tracks named after the stems, aligned at bar 1, with tempo and key set from the analysis.

### Custom output folder

```bash
./split.sh path/to/song.m4a /path/to/output_folder
```

### Custom Ableton template

```bash
TEMPLATE_ALS=/path/to/custom.als ./split.sh path/to/song.m4a
```

## What each step does, roughly

| Step | Tool | Time (M-series) |
|---|---|---|
| Stem split | Demucs `htdemucs_ft` (bag-of-4) | ~3–5 min for a 3 min song |
| Drum split | LarsNet (5-stem U-Net) | ~10–20 s for the drum stem |
| Key detection | keyfinder-cli | ~2 s |
| BPM detection | aubio | ~2 s |
| Ableton project | Python XML generator | <1 s |

## Caveats

- **BPM accuracy.** aubio sometimes reports 2x or 0.5x the true tempo on breakbeat/halftime material. The tool surfaces a warning after every run. Ear-check and correct in Live if needed.
- **Key accuracy.** keyfinder-cli is ~85% accurate and can confuse relative major/minor pairs (same notes, different tonal center). Verify by ear for tracks you seriously work with.
- **Drum split grouping.** LarsNet splits into 5 buses: `kick / snare / toms / hihat / cymbals`. Hihat is its own bus; crashes and rides live together in `cymbals`.
- **Ableton version.** Generator targets Live 12 schema. Live 11 projects may open but mis-display metadata. Live 13+ is untested.
- **Gatekeeper prompt.** `keyfinder-cli` is built from source and not notarized; macOS may warn on first run. One-time "Allow" in **System Settings → Privacy & Security**.

## Credits

Built on the work of:

- [Demucs](https://github.com/facebookresearch/demucs) — Meta Research
- [LarsNet](https://github.com/polimi-ispl/larsnet) — Polimi ISPL (drum-element separation)
- [keyfinder-cli](https://github.com/EvanPurkhiser/keyfinder-cli) — Evan Purkhiser
- [aubio](https://aubio.org) — Paul Brossier et al.

This repo is a thin wrapper that glues them into a single-command pipeline and generates the Ableton project file.

## License

MIT — see [LICENSE](LICENSE).
