#!/usr/bin/env python3
"""
Generate an Ableton Live .als project from a stems folder, using a user-provided
.als that already contains ONE imported audio track as the template.

The template track is cloned per stem, with internal Ids remapped and file paths
/ names rewritten. Output is a gzipped .als in Live 12.x format.

Usage:
    build_als.py <template.als> <stems_dir> <output.als> [--tempo N]

Expects stems_dir to contain some subset of:
    stems/{drums,bass,vocals,other}.wav
    drums_split/{kick,snare,toms,cymbals}.wav
"""
from __future__ import annotations
import argparse
import copy
import gzip
import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Order matters: determines track order in Live left-to-right.
# Note name -> Live's Root integer (chromatic, C=0).
NOTE_TO_ROOT = {
    "C": 0, "C#": 1, "DB": 1, "D": 2, "D#": 3, "EB": 3,
    "E": 4, "F": 5, "F#": 6, "GB": 6, "G": 7, "G#": 8, "AB": 8,
    "A": 9, "A#": 10, "BB": 10, "B": 11,
}
# Live 12 scale mode -> Name integer.
SCALE_TO_NAME = {
    "MAJOR": 0, "MAJ": 0,
    "MINOR": 1, "MIN": 1, "M": 1,
    "DORIAN": 2, "MIXOLYDIAN": 3, "LYDIAN": 4,
    "PHRYGIAN": 5, "LOCRIAN": 6,
}


def parse_key(key_str: str) -> tuple[int, int] | None:
    """
    Parse a key string like 'Abm', 'C#maj', 'F minor', 'Gb' -> (root, scale_name).
    Returns None if unparseable.
    """
    if not key_str:
        return None
    s = key_str.strip().upper().replace(" ", "")
    # Extract root (1-2 chars)
    m = re.match(r"^([A-G][B#]?)(.*)$", s)
    if not m:
        return None
    note, suffix = m.group(1), m.group(2)
    if note not in NOTE_TO_ROOT:
        return None
    root = NOTE_TO_ROOT[note]
    # Suffix: default major; 'M' or 'MIN'/'MINOR' = minor, 'MAJ' = major
    if suffix == "" or suffix == "MAJ" or suffix == "MAJOR":
        scale = SCALE_TO_NAME["MAJOR"]
    elif suffix == "M" or suffix == "MIN" or suffix == "MINOR":
        scale = SCALE_TO_NAME["MINOR"]
    elif suffix in SCALE_TO_NAME:
        scale = SCALE_TO_NAME[suffix]
    else:
        return None
    return root, scale


STEM_ORDER = [
    ("drums",   "stems/drums.wav"),
    ("bass",    "stems/bass.wav"),
    ("vocals",  "stems/vocals.wav"),
    ("other",   "stems/other.wav"),
    ("kick",    "drums_split/kick.wav"),
    ("snare",   "drums_split/snare.wav"),
    ("toms",    "drums_split/toms.wav"),
    ("hihat",   "drums_split/hihat.wav"),
    ("ride",    "drums_split/ride.wav"),
    ("crash",   "drums_split/crash.wav"),
]

# Attributes that contain ID references we may need to remap.
ID_REF_ATTRS = {"Id", "PointeeId", "TargetId", "ReceiverId", "LomId", "SenderId"}


def collect_ids(elem: ET.Element) -> set[int]:
    """Collect every `Id="N"` value defined inside elem (the Id that names a node)."""
    ids: set[int] = set()
    for e in elem.iter():
        v = e.get("Id")
        if v is not None and v.isdigit():
            ids.add(int(v))
    return ids


def collect_all_ids(elem: ET.Element) -> set[int]:
    """Collect integer values of any ID-like attribute anywhere under elem."""
    ids: set[int] = set()
    for e in elem.iter():
        for attr in ID_REF_ATTRS:
            v = e.get(attr)
            if v is not None and v.isdigit():
                ids.add(int(v))
    return ids


def remap_ids(elem: ET.Element, mapping: dict[int, int]) -> None:
    """Rewrite any ID_REF_ATTRS whose int value is a key in mapping."""
    for e in elem.iter():
        for attr in ID_REF_ATTRS:
            v = e.get(attr)
            if v is not None and v.isdigit():
                iv = int(v)
                if iv in mapping:
                    e.set(attr, str(mapping[iv]))


def set_value(elem: ET.Element, tag: str, value: str) -> int:
    """Set `Value` attribute on all matching <tag Value="..."/> descendants. Returns count."""
    count = 0
    for e in elem.iter(tag):
        if "Value" in e.attrib:
            e.set("Value", value)
            count += 1
    return count


def update_track(track: ET.Element, name: str, abs_path: Path, rel_path: str) -> None:
    """Set track name, clip name, and sample file paths in a cloned AudioTrack."""
    # Track-level name: <Name><EffectiveName/><UserName/><MemorizedFirstClipName/></Name>
    # Only the first <Name> child of the track is the track name holder.
    name_elem = track.find("Name")
    if name_elem is not None:
        for child_tag, val in [
            ("EffectiveName", name),
            ("UserName", name),
            ("MemorizedFirstClipName", name),
        ]:
            child = name_elem.find(child_tag)
            if child is not None and "Value" in child.attrib:
                child.set("Value", val)

    # Clip name: <AudioClip><Name Value="..."/> — update all AudioClip names.
    for clip in track.iter("AudioClip"):
        cn = clip.find("Name")
        if cn is not None and "Value" in cn.attrib:
            cn.set("Value", name)

    # Sample paths: <FileRef><RelativePath/><Path/></FileRef>
    for file_ref in track.iter("FileRef"):
        rp = file_ref.find("RelativePath")
        if rp is not None and "Value" in rp.attrib:
            rp.set("Value", rel_path)
        p = file_ref.find("Path")
        if p is not None and "Value" in p.attrib:
            p.set("Value", str(abs_path))


def relpath_from_project(stem_abs: Path, project_dir: Path) -> str:
    return os.path.relpath(stem_abs, project_dir)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("template", help="Template .als with ONE audio track already imported")
    ap.add_argument("stems_dir", help="Directory containing stems/ and drums_split/ subfolders")
    ap.add_argument("output", help="Output .als path (will be created in its project folder)")
    ap.add_argument("--tempo", type=float, default=None, help="Set master tempo")
    ap.add_argument("--key", type=str, default=None,
                    help="Key, e.g. 'Abm', 'C#maj', 'F minor', 'G dorian'")
    args = ap.parse_args()

    template_path = Path(args.template).resolve()
    stems_root = Path(args.stems_dir).resolve()
    output_path = Path(args.output).resolve()
    project_dir = output_path.parent

    # 1. Read and decompress the template.
    with gzip.open(template_path, "rb") as f:
        xml_bytes = f.read()
    # Preserve XML declaration header exactly.
    tree = ET.ElementTree(ET.fromstring(xml_bytes))
    root = tree.getroot()

    live_set = root.find("LiveSet")
    tracks = live_set.find("Tracks") if live_set is not None else None
    if tracks is None:
        sys.exit("ERROR: <Tracks> not found in template")

    template_track = tracks.find("AudioTrack")
    if template_track is None:
        sys.exit("ERROR: no <AudioTrack> in template — import one audio file before exporting")

    # 2. Figure out max ID in the whole document (to allocate from).
    max_global_id = max(collect_all_ids(root), default=0)

    # 3. Determine which stems exist on disk.
    available = []
    for name, rel in STEM_ORDER:
        p = stems_root / rel
        if p.exists():
            available.append((name, p))
        else:
            print(f"  (skip: {rel} not found)")
    if not available:
        sys.exit("ERROR: no stem files found under " + str(stems_root))

    # 4. Update the existing template track to be the first stem.
    first_name, first_path = available[0]
    update_track(template_track,
                 first_name,
                 first_path,
                 relpath_from_project(first_path, project_dir))
    print(f"  [0] reused template track -> {first_name}")

    # 5. For each remaining stem, clone + remap IDs + update.
    template_ids = collect_ids(template_track)  # Ids defined inside the template
    next_id = max_global_id + 1
    for idx, (name, path) in enumerate(available[1:], start=1):
        clone = copy.deepcopy(template_track)
        # Build mapping: every Id defined inside template_track -> new unique Id.
        mapping = {old: next_id + i for i, old in enumerate(sorted(template_ids))}
        next_id += len(template_ids)
        remap_ids(clone, mapping)
        update_track(clone,
                     name,
                     path,
                     relpath_from_project(path, project_dir))
        tracks.append(clone)
        print(f"  [{idx}] appended track -> {name}")

    # 6. Update NextPointeeId to be safely above everything.
    npi = live_set.find("NextPointeeId")
    if npi is not None:
        npi.set("Value", str(next_id + 1000))

    # 7. Optionally set tempo.
    # Live 12 uses <MainTrack>; older versions used <MasterTrack>.
    main_track = live_set.find("MainTrack") or live_set.find("MasterTrack")
    if args.tempo is not None and main_track is not None:
        tempo_set = False
        tempo_auto_target_id = None
        for tempo in main_track.iter("Tempo"):
            manual = tempo.find("Manual")
            if manual is not None and "Value" in manual.attrib:
                manual.set("Value", f"{args.tempo:.6f}")
                auto_target = tempo.find("AutomationTarget")
                if auto_target is not None:
                    tempo_auto_target_id = auto_target.get("Id")
                tempo_set = True
                break
        # Live drives playing tempo from the AutomationEnvelope's FloatEvent,
        # keyed by PointeeId == the Tempo's AutomationTarget Id.
        if tempo_auto_target_id is not None:
            for env in main_track.iter("AutomationEnvelope"):
                target = env.find("EnvelopeTarget")
                if target is None:
                    continue
                pointee = target.find("PointeeId")
                if pointee is None or pointee.get("Value") != tempo_auto_target_id:
                    continue
                for float_ev in env.iter("FloatEvent"):
                    float_ev.set("Value", f"{args.tempo:.6f}")
                break
        print(f"  tempo set -> {args.tempo}" if tempo_set else "  WARN: tempo node not found")

    # 8. Optionally set project key (Live 12's ScaleInformation, direct child of LiveSet).
    if args.key is not None:
        parsed = parse_key(args.key)
        if parsed is None:
            print(f"  WARN: could not parse key '{args.key}' — skipping")
        else:
            root_val, scale_val = parsed
            scale_info = live_set.find("ScaleInformation")
            if scale_info is not None:
                r = scale_info.find("Root")
                n = scale_info.find("Name")
                if r is not None: r.set("Value", str(root_val))
                if n is not None: n.set("Value", str(scale_val))
                in_key = live_set.find("InKey")
                if in_key is not None:
                    in_key.set("Value", "true")
            # Also set every AudioClip's per-clip ScaleInformation so clips
            # match the global key (Live syncs these when "In Key" is on).
            clip_updates = 0
            for clip in root.iter("AudioClip"):
                clip_scale = clip.find("ScaleInformation")
                if clip_scale is not None:
                    cr = clip_scale.find("Root")
                    cn = clip_scale.find("Name")
                    if cr is not None: cr.set("Value", str(root_val))
                    if cn is not None: cn.set("Value", str(scale_val))
                    clip_updates += 1
                ck = clip.find("IsInKey")
                if ck is not None and "Value" in ck.attrib:
                    ck.set("Value", "true")
            print(f"  key set -> {args.key} (Root={root_val}, Scale={scale_val}; {clip_updates} clips)")

    # 9. Serialize and gzip-write.
    project_dir.mkdir(parents=True, exist_ok=True)
    xml_out = ET.tostring(root, encoding="utf-8")
    # Restore XML declaration that ET.tostring omits by default on write.
    if not xml_out.startswith(b"<?xml"):
        xml_out = b'<?xml version="1.0" encoding="UTF-8"?>\n' + xml_out
    with gzip.open(output_path, "wb") as f:
        f.write(xml_out)

    print(f"\n==> Wrote {output_path}")
    print(f"    Open in Live 12 and verify tracks/paths.")


if __name__ == "__main__":
    main()
