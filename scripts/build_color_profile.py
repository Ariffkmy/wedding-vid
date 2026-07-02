#!/usr/bin/env python3
"""Learn the color-grading profile of the Malay-wedding reference dataset.

Reads the frames cached by build_moment_prototypes.py, computes per-frame color
statistics matching the app's ColorSignature (Scopes) fields, averages per video,
k-means the videos into characteristic looks, and emits:

    Sources/PalmierPro/Resources/DomainPacks/malay_wedding_colors.json
    Sources/PalmierPro/Resources/DomainPacks/LUTs/malay_wedding_lut<k>.cube

Each look is baked into a real .cube 3D LUT (LUT1, LUT2, ...) the app can apply
directly via apply_color. The parametric bake maps tone (black/white points +
mid gamma), per-zone color tints (lift/gamma/gain style), and saturation from
the look's signature; the dataset-wide mean is the neutral baseline.

The app uses `overall` as the bundled color fallback when the user has no style
references; `looks` (with their LUTs) are selectable grading presets.

    python scripts/build_color_profile.py
"""
from __future__ import annotations

import colorsys
import json
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
FRAMES_DIR = ROOT / "References" / "MalayWedding" / "frames_prototypes"
PACKS_DIR = ROOT / "Sources" / "PalmierPro" / "Resources" / "DomainPacks"
OUT = PACKS_DIR / "malay_wedding_colors.json"
LUT_DIR = PACKS_DIR / "LUTs"

LOOK_COUNT = 3
LUT_SIZE = 33


def frame_signature(path: Path) -> dict | None:
    """Per-frame color stats mirroring the app's Scopes fields (linear 0-1 sRGB values)."""
    try:
        img = Image.open(path).convert("RGB").resize((128, 72))
    except OSError:
        return None
    rgb = np.asarray(img, dtype=np.float32) / 255.0
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

    mx = rgb.max(axis=-1)
    mn = rgb.min(axis=-1)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)

    shadows = luma < 1 / 3
    highs = luma > 2 / 3
    mids = ~shadows & ~highs

    def zone_mean(mask: np.ndarray) -> list[float]:
        if not mask.any():
            return [float(r.mean()), float(g.mean()), float(b.mean())]
        return [float(c[mask].mean()) for c in (r, g, b)]

    # Saturation-weighted 12-bin hue histogram (30° bins from red).
    hue = np.zeros_like(luma)
    delta = mx - mn
    nz = delta > 1e-6
    rc = np.where(nz, (mx - r) / np.maximum(delta, 1e-6), 0)
    gc = np.where(nz, (mx - g) / np.maximum(delta, 1e-6), 0)
    bc = np.where(nz, (mx - b) / np.maximum(delta, 1e-6), 0)
    hue = np.where(mx == r, bc - gc, np.where(mx == g, 2 + rc - bc, 4 + gc - rc))
    hue = (hue / 6.0) % 1.0
    hue_hist, _ = np.histogram(hue[nz], bins=12, range=(0, 1), weights=sat[nz])
    hue_hist = hue_hist / hue_hist.sum() if hue_hist.sum() > 0 else np.full(12, 1 / 12)

    luma_hist, _ = np.histogram(luma, bins=16, range=(0, 1))
    luma_hist = luma_hist / max(luma_hist.sum(), 1)

    return {
        "lumaMean": float(luma.mean()),
        "lumaBlack": float(np.percentile(luma, 2)),
        "lumaWhite": float(np.percentile(luma, 98)),
        "clipLow": float((luma < 0.02).mean()),
        "clipHigh": float((luma > 0.98).mean()),
        "lumaHistogram": [float(x) for x in luma_hist],
        "meanRGB": [float(r.mean()), float(g.mean()), float(b.mean())],
        "blackRGB": [float(np.percentile(c, 2)) for c in (r, g, b)],
        "whiteRGB": [float(np.percentile(c, 98)) for c in (r, g, b)],
        "shadowRGB": zone_mean(shadows),
        "midRGB": zone_mean(mids),
        "highRGB": zone_mean(highs),
        "saturationMean": float(sat.mean()),
        "warmCoolBias": float(r.mean() - b.mean()),
        "greenMagentaBias": float(g.mean() - (r.mean() + b.mean()) / 2),
        "hueHistogram": [float(x) for x in hue_hist],
        "colorfulPct": float((sat > 0.15).mean()),
    }


def average(signatures: list[dict]) -> dict:
    out: dict = {}
    for key in signatures[0]:
        vals = [s[key] for s in signatures]
        if isinstance(vals[0], list):
            out[key] = [round(float(np.mean([v[i] for v in vals])), 4) for i in range(len(vals[0]))]
        else:
            out[key] = round(float(np.mean(vals)), 4)
    return out


def cluster_feature(sig: dict) -> list[float]:
    return [
        sig["lumaMean"], sig["lumaBlack"], sig["lumaWhite"],
        *sig["meanRGB"], sig["saturationMean"],
        sig["warmCoolBias"] * 2, sig["greenMagentaBias"] * 2,
    ]


def bake_lut(sig: dict, baseline: dict, path: Path) -> None:
    """Bakes the look's grade into a .cube 3D LUT (red-fastest, size LUT_SIZE).

    Tone: black/white points + mid gamma from the look's luma stats.
    Color: per-zone tints (lift/gamma/gain style) from zone RGB deviations.
    Saturation: scaled relative to the dataset baseline.
    """
    lb = float(np.clip(sig["lumaBlack"], 0.0, 0.15))
    lw = float(np.clip(sig["lumaWhite"], 0.75, 1.0))
    mid = (sig["lumaMean"] - lb) / max(lw - lb, 1e-4)
    gamma = float(np.clip(np.log(max(mid, 0.05)) / np.log(0.45), 0.6, 1.6))

    def zone_tint(key: str) -> np.ndarray:
        z = np.array(sig[key], dtype=np.float64)
        return z - z.mean()

    tint_s, tint_m, tint_h = zone_tint("shadowRGB"), zone_tint("midRGB"), zone_tint("highRGB")
    sat_scale = float(np.clip(sig["saturationMean"] / max(baseline["saturationMean"], 1e-4), 0.6, 1.6))

    grid = np.linspace(0.0, 1.0, LUT_SIZE)
    # Red fastest per the .cube spec: b, g, r loop order with r innermost.
    bb, gg, rr = np.meshgrid(grid, grid, grid, indexing="ij")
    rgb = np.stack([rr, gg, bb], axis=-1).reshape(-1, 3)

    toned = lb + (lw - lb) * np.power(rgb, gamma)
    luma = (toned @ np.array([0.2126, 0.7152, 0.0722]))[:, None]
    w_s = np.clip(1 - luma, 0, 1) ** 2
    w_h = np.clip(luma, 0, 1) ** 2
    w_m = np.clip(1 - w_s - w_h, 0, 1)
    toned = toned + w_s * tint_s + w_m * tint_m + w_h * tint_h
    toned = luma + (toned - luma) * sat_scale
    toned = np.clip(toned, 0, 1)

    lines = [f"TITLE \"{path.stem}\"", f"LUT_3D_SIZE {LUT_SIZE}"]
    lines += [f"{r:.5f} {g:.5f} {b:.5f}" for r, g, b in toned]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    by_video: dict[str, list[dict]] = {}
    for path in sorted(FRAMES_DIR.glob("*/*.jpg")):
        sig = frame_signature(path)
        if sig:
            by_video.setdefault(path.parent.name, []).append(sig)
    if not by_video:
        raise SystemExit(f"no frames under {FRAMES_DIR} — run build_moment_prototypes.py first")

    video_sigs = {vid: average(frames) for vid, frames in by_video.items() if len(frames) >= 3}
    print(f"{sum(len(v) for v in by_video.values())} frames across {len(video_sigs)} videos")

    overall = average(list(video_sigs.values()))

    looks: list[dict] = []
    if len(video_sigs) >= LOOK_COUNT * 2:
        from sklearn.cluster import KMeans
        vids = sorted(video_sigs)
        features = np.array([cluster_feature(video_sigs[v]) for v in vids])
        labels = KMeans(n_clusters=LOOK_COUNT, n_init=10, random_state=0).fit_predict(features)
        for k in range(LOOK_COUNT):
            members = [video_sigs[v] for v, lab in zip(vids, labels) if lab == k]
            if not members:
                continue
            sig = average(members)
            warm = sig["warmCoolBias"]
            tone = "warm" if warm > 0.03 else "cool" if warm < -0.03 else "neutral"
            bright = "bright" if sig["lumaMean"] > 0.5 else "dark" if sig["lumaMean"] < 0.35 else "balanced"
            looks.append({
                "name": f"{tone}-{bright}",
                "videoCount": len(members),
                "signature": sig,
            })
        looks.sort(key=lambda l: -l["videoCount"])
        LUT_DIR.mkdir(parents=True, exist_ok=True)
        for i, look in enumerate(looks, 1):
            lut_file = f"malay_wedding_lut{i}.cube"
            look["id"] = f"lut{i}"
            look["lutFile"] = lut_file
            bake_lut(look["signature"], overall, LUT_DIR / lut_file)

    OUT.write_text(json.dumps({
        "_note": "Generated by scripts/build_color_profile.py from reference-video frames — do not edit by hand.",
        "domain": "malay_wedding",
        "videosAnalyzed": len(video_sigs),
        "overall": overall,
        "looks": looks,
    }, indent=1), encoding="utf-8")
    print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB)")
    for look in looks:
        s = look["signature"]
        print(f"  {look['id']:5s} {look['name']:16s} videos={look['videoCount']:3d} "
              f"luma={s['lumaMean']:.2f} sat={s['saturationMean']:.2f} warm={s['warmCoolBias']:+.3f} "
              f"-> LUTs/{look['lutFile']}")


if __name__ == "__main__":
    main()
