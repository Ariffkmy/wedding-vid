#!/usr/bin/env python3
"""Compile the Malay-wedding reference dataset into the bundled domain pack the app ships.

Reads AI-reference/references_malay_wedding.jsonl + taxonomy_malay_wedding.json and
derives, per moment type: importance, audio policy, preferred/avoid shot qualities, a
short classification cue, and per-ceremony ordered moment slots.

The output is HEURISTIC (the dataset has no explicit ordering or must-have judgment) and
is meant to be reviewed/edited by hand afterwards. Re-runnable and deterministic.

    python scripts/build_domain_pack.py
"""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC_DIR = ROOT / "AI-reference"
OUT = ROOT / "Sources/PalmierPro/Resources/DomainPacks/malay_wedding.json"

# Editorial arc order. Earlier categories are cut earlier in a wedding film.
CATEGORY_ORDER = ["scene", "preparation", "ceremony", "family", "celebration"]

# Audio policy default per category. feature-original = the clip's own audio is the
# point (vows, speech, greetings); music-bed-ok = safe to lay music over; ambient =
# light room tone, neither featured nor important.
CATEGORY_AUDIO = {
    "ceremony": "feature-original",
    "family": "feature-original",
    "preparation": "ambient",
    "celebration": "music-bed-ok",
    "scene": "music-bed-ok",
}
# Per-moment overrides where the category default is wrong.
MOMENT_AUDIO = {
    "family_portrait": "ambient",   # posed photo, no crucial speech
    "guest_reaction": "ambient",
    "couple_portrait": "music-bed-ok",
    "decor_detail": "music-bed-ok",
    "venue_establishing": "music-bed-ok",
}
# Keywords in culturalNotes that force feature-original (speech/audio is crucial).
AUDIO_KEYWORDS = ("vow", "speech", "interview", "silent", "reverent", "doa", "audio", "recit")

# Frequency thresholds -> importance.
CORE_MIN = 40
OPTIONAL_MIN = 10

# Per-ceremony category whitelist (which moments belong to each ceremony's arc).
CEREMONY_CATEGORIES = {
    "nikah": ["scene", "preparation", "ceremony", "family"],
    "tunang": ["scene", "preparation", "ceremony", "family"],
    "reception": ["scene", "celebration", "family"],
}
# Tunang (engagement) excludes the solemnization itself.
TUNANG_EXCLUDE = {"akad_nikah"}


def load_records() -> list[dict]:
    path = SRC_DIR / "references_malay_wedding.jsonl"
    records = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line:
            records.append(json.loads(line))
    return records


def category_of(moment: str, categories: dict[str, list[str]]) -> str:
    for cat, moments in categories.items():
        if moment in moments:
            return cat
    return "scene"


def importance_of(count: int) -> str:
    if count >= CORE_MIN:
        return "core"
    if count >= OPTIONAL_MIN:
        return "optional"
    return "filler"


def audio_policy_of(moment: str, category: str, notes: str) -> str:
    if any(k in notes.lower() for k in AUDIO_KEYWORDS):
        return "feature-original"
    if moment in MOMENT_AUDIO:
        return MOMENT_AUDIO[moment]
    return CATEGORY_AUDIO.get(category, "music-bed-ok")


def humanize(moment: str) -> str:
    return moment.replace("_", " ")


def top_values(counter: Counter, n: int) -> list[str]:
    return [v for v, _ in counter.most_common(n)]


def build() -> dict:
    taxonomy = json.loads((SRC_DIR / "taxonomy_malay_wedding.json").read_text(encoding="utf-8"))
    records = load_records()

    moment_counts: Counter = Counter(taxonomy.get("momentTypes", {}))
    categories: dict[str, list[str]] = taxonomy.get("momentCategories", {})
    preferred_composition = taxonomy.get("preferredComposition", "")

    # Aggregate shot qualities + a representative cultural note per moment from the records.
    preferred: dict[str, Counter] = {}
    avoid: dict[str, Counter] = {}
    notes: dict[str, Counter] = {}
    for rec in records:
        note = (rec.get("culturalNotes") or "").strip()
        for moment in rec.get("momentTypes", []):
            preferred.setdefault(moment, Counter()).update(rec.get("preferredShotQualities", []))
            avoid.setdefault(moment, Counter()).update(rec.get("avoidQualities", []))
            if note:
                notes.setdefault(moment, Counter()).update([note])

    moments: dict[str, dict] = {}
    for moment, count in moment_counts.items():
        category = category_of(moment, categories)
        note_counter = notes.get(moment, Counter())
        rep_note = note_counter.most_common(1)[0][0] if note_counter else ""
        cue_bits = [humanize(moment)]
        if preferred_composition:
            cue_bits.append(preferred_composition)
        if rep_note:
            cue_bits.append(rep_note)
        moments[moment] = {
            "category": category,
            "importance": importance_of(count),
            "audioPolicy": audio_policy_of(moment, category, rep_note),
            "preferredShots": top_values(preferred.get(moment, Counter()), 3),
            "avoidQualities": top_values(avoid.get(moment, Counter()), 3) or ["blurry", "shaky"],
            "classificationCues": " — ".join(cue_bits),
            "referenceCount": count,
        }

    def ordered_for(allowed_cats: list[str], exclude: set[str]) -> list[str]:
        slots = [m for m in moments if moments[m]["category"] in allowed_cats and m not in exclude]
        # Category arc order, then by frequency (most common first) within a category.
        slots.sort(key=lambda m: (CATEGORY_ORDER.index(moments[m]["category"]), -moment_counts[m]))
        return slots

    ceremonies = {
        "nikah": ordered_for(CEREMONY_CATEGORIES["nikah"], set()),
        "tunang": ordered_for(CEREMONY_CATEGORIES["tunang"], TUNANG_EXCLUDE),
        "reception": ordered_for(CEREMONY_CATEGORIES["reception"], set()),
    }

    return {
        "_note": "Derived from AI-reference by scripts/build_domain_pack.py. Heuristic ordering/importance — review and edit by hand.",
        "domain": taxonomy.get("domain", "malay_wedding"),
        "culture": taxonomy.get("culture", ""),
        "audioPatterns": taxonomy.get("audioPatterns", ""),
        "typicalPacing": taxonomy.get("typicalPacing", ""),
        "moments": moments,
        "ceremonies": ceremonies,
    }


def main() -> None:
    pack = build()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(pack, indent=2, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {OUT.relative_to(ROOT)} — {len(pack['moments'])} moments, "
          f"{len(pack['ceremonies'])} ceremonies.")


if __name__ == "__main__":
    main()
