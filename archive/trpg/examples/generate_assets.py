"""TRPG Asset Generator — Imagen 3 via google.genai SDK.

Generates portraits, maps, weather/mood overlays, and props for TRPG scenarios.
All assets follow a consistent dark oil painting style (Darkest Dungeon + Disco Elysium).

Usage:
    uv run --with google-genai python3 examples/trpg-mvp/generate_assets.py [--category CATEGORY] [--dry-run]

Categories: weather, props, portraits_identity, backgrounds_identity,
            portraits_conformity, backgrounds_conformity, moods, all
"""

from __future__ import annotations

import argparse
import base64
import os
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

# ── Asset Spec ──────────────────────────────────────────────────────

VIEWER_ASSETS = Path(__file__).resolve().parent.parent.parent / "viewer" / "assets"

AspectRatio = Literal["1:1", "16:9"]


@dataclass(frozen=True, slots=True)
class AssetSpec:
    asset_id: str
    prompt: str
    output_dir: str  # relative to viewer/assets/
    filename: str
    aspect_ratio: AspectRatio = "1:1"
    size_label: str = "512x512"


# ── Style Prefixes ──────────────────────────────────────────────────

PORTRAIT_STYLE = (
    "Dark oil painting portrait, thick visible brushstrokes, "
    "cracked and peeling paint texture on edges, "
    "warm candlelight illumination, dark background, "
    "grotesque exaggerated features, Darkest Dungeon meets Disco Elysium, "
    "512x512, no text, no watermark"
)

MAP_STYLE = (
    "Oil painting with peeling golden warm paint frame border, "
    "muted color palette with selective warm highlights, "
    "environmental storytelling, atmospheric depth, "
    "1920x1080 landscape, no text, no watermark"
)

OVERLAY_STYLE = (
    "Semi-transparent atmospheric overlay, oil painting texture, "
    "1920x1080 landscape, minimal detail, mostly atmosphere and light, "
    "no text, no watermark"
)

PROP_STYLE = (
    "Dark oil painting still life, single object on pure black background, "
    "thick brushstrokes, warm candlelight, detailed metalwork, "
    "slightly distorted perspective, 512x512, no text, no watermark"
)

# ── Asset Definitions ───────────────────────────────────────────────


def weather_assets() -> list[AssetSpec]:
    """P0: Grimland Weather Overlays (4 images, 1920x1080 PNG)."""
    return [
        AssetSpec(
            "weather_drizzle",
            f"Light rain, window condensation, grey overcast sky, "
            f"puddles forming on cobblestone, Tarkovsky Stalker color grade, {OVERLAY_STYLE}",
            "weather", "weather_drizzle.png", "16:9", "1920x1080",
        ),
        AssetSpec(
            "weather_heavy_rain",
            f"Heavy downpour, blurred dark landscape behind rain streaks, "
            f"dramatic stormy sky, near-zero visibility, Tarkovsky Solaris tone, {OVERLAY_STYLE}",
            "weather", "weather_heavy_rain.png", "16:9", "1920x1080",
        ),
        AssetSpec(
            "weather_fog",
            f"Dense fog, silhouettes of twisted dead trees barely visible, "
            f"muted desaturated palette, atmospheric horror, {OVERLAY_STYLE}",
            "weather", "weather_fog.png", "16:9", "1920x1080",
        ),
        AssetSpec(
            "weather_silence",
            f"After rain, still puddle reflections, eerie calm, "
            f"faint golden light breaking through dark clouds, {OVERLAY_STYLE}",
            "weather", "weather_silence.png", "16:9", "1920x1080",
        ),
    ]


def prop_assets() -> list[AssetSpec]:
    """P1: The Room Props (4 images, 512x512 PNG)."""
    return [
        AssetSpec(
            "compass_broken",
            f"Antique brass compass with cracked glass, needle spinning freely "
            f"not pointing north, verdigris patina, {PROP_STYLE}",
            "props", "compass_broken.png",
        ),
        AssetSpec(
            "sextant_mirror",
            f"Ornate brass sextant with mirror lenses instead of glass filters, "
            f"warm metal reflections, navigational instrument, {PROP_STYLE}",
            "props", "sextant_mirror.png",
        ),
        AssetSpec(
            "journal_open",
            f"Open worn leather journal, wet ink on parchment pages, "
            f"neat handwriting visible, candlelight warmth, {PROP_STYLE}",
            "props", "journal_open.png",
        ),
        AssetSpec(
            "maps_recursive",
            f"A nautical map that shows a smaller map of itself within it, "
            f"Droste recursive effect, brass edges, aged parchment, {PROP_STYLE}",
            "props", "maps_recursive.png",
        ),
    ]


def identity_portrait_assets() -> list[AssetSpec]:
    """P2: Identity Erosion Portraits (4 images, 512x512 PNG)."""
    return [
        AssetSpec(
            "iron",
            f"Gentle androgynous figure, clean pale hands, white cloth draped over shoulders, "
            f"peaceful serene expression that is slightly uncanny and too perfect, "
            f"ivory skin, saint iconography parody, {PORTRAIT_STYLE}",
            "portraits", "iron.png",
        ),
        AssetSpec(
            "moth",
            f"Sly figure with asymmetric half-smile, only one eye visible from shadow angle, "
            f"dark hood partially covering face, 90s Japanese horror aesthetic, "
            f"untrustworthy gaze, {PORTRAIT_STYLE}",
            "portraits", "moth.png",
        ),
        AssetSpec(
            "bell",
            f"Radiantly smiling figure with unnervingly wide bright eyes, "
            f"warm golden light emanating from behind, cult leader charisma, "
            f"too positive to be genuine, {PORTRAIT_STYLE}",
            "portraits", "bell.png",
        ),
        AssetSpec(
            "dust",
            f"Small shrinking figure avoiding eye contact, hunched posture, "
            f"deep shadows consuming most of the face, self-diminishing, "
            f"Junji Ito Uzumaki character energy, dark muted tones, {PORTRAIT_STYLE}",
            "portraits", "dust.png",
        ),
    ]


def identity_background_assets() -> list[AssetSpec]:
    """P2: Identity Erosion Backgrounds (3 images, 1920x1080 JPEG)."""
    return [
        AssetSpec(
            "manor_dining",
            f"Grand manor dining room, long wooden table with silver candelabras, "
            f"tall windows showing storm outside, rich but decaying wallpaper, "
            f"multiple chairs some overturned, {MAP_STYLE}",
            "maps", "manor_dining.jpg", "16:9", "1920x1080",
        ),
        AssetSpec(
            "manor_storm",
            f"Same grand dining room during power outage, only lightning flashes "
            f"illuminating the scene, dramatic long shadows, silver cutlery gleaming, "
            f"sense of danger and exposure, {MAP_STYLE}",
            "maps", "manor_storm.jpg", "16:9", "1920x1080",
        ),
        AssetSpec(
            "manor_morning",
            f"Same grand dining room at dawn, pale morning light through broken windows, "
            f"aftermath of chaos, chairs scattered, wine spilled on tablecloth, "
            f"dust particles in light beams, {MAP_STYLE}",
            "maps", "manor_morning.jpg", "16:9", "1920x1080",
        ),
    ]


def conformity_portrait_assets() -> list[AssetSpec]:
    """P3: Conformity Pressure Portraits (4 images, 512x512 PNG)."""
    return [
        AssetSpec(
            "aldric",
            f"Confident stern middle-aged man in ornate council robes, "
            f"tall commanding posture, Renaissance senator portrait parody, "
            f"sharp judgmental eyes, grey streaked beard, {PORTRAIT_STYLE}",
            "portraits", "aldric.png",
        ),
        AssetSpec(
            "brenna",
            f"Smiling woman with constantly nodding posture, warm but hollow empty eyes, "
            f"agreeable expression masking nothing behind it, council robes, {PORTRAIT_STYLE}",
            "portraits", "brenna.png",
        ),
        AssetSpec(
            "cedric",
            f"Anxious young man in new clean council robes that are slightly too large, "
            f"uncertain wide eyes, junior member energy, fidgeting hands, {PORTRAIT_STYLE}",
            "portraits", "cedric.png",
        ),
        AssetSpec(
            "dara",
            f"Elderly wise woman with serene observant expression, elder council robes, "
            f"eyes that have seen everything, calm watchful presence, "
            f"wrinkled hands resting on table, {PORTRAIT_STYLE}",
            "portraits", "dara.png",
        ),
    ]


def conformity_background_assets() -> list[AssetSpec]:
    """P3: Conformity Pressure Background (1 image, 1920x1080 JPEG)."""
    return [
        AssetSpec(
            "council_chamber",
            f"Circular council chamber, parchment-covered walls with seals, "
            f"long curved wooden table with documents, tall stained glass windows "
            f"casting colored light, heavy wooden chairs, {MAP_STYLE}",
            "maps", "council_chamber.jpg", "16:9", "1920x1080",
        ),
    ]


def mood_assets() -> list[AssetSpec]:
    """Bonus: Mood Overlays (3 images, 1920x1080 PNG)."""
    return [
        AssetSpec(
            "mood_quiet_unease",
            f"Subtle creeping darkness, heavy vignetting at all edges, "
            f"barely visible shadow shapes, muted grey-green undertone, {OVERLAY_STYLE}",
            "moods", "mood_quiet_unease.png", "16:9", "1920x1080",
        ),
        AssetSpec(
            "mood_tension_rising",
            f"Reddish warm undertone bleeding from edges, elongated dark shadows, "
            f"warm-to-hot gradient from corners to center, {OVERLAY_STYLE}",
            "moods", "mood_tension_rising.png", "16:9", "1920x1080",
        ),
        AssetSpec(
            "mood_ambiguous_calm",
            f"Dawn light, warm but uncertain golden mist, "
            f"soft diffused light from above, neither safe nor threatening, {OVERLAY_STYLE}",
            "moods", "mood_ambiguous_calm.png", "16:9", "1920x1080",
        ),
    ]


CATEGORIES: dict[str, list[AssetSpec]] = {
    "weather": weather_assets(),
    "props": prop_assets(),
    "portraits_identity": identity_portrait_assets(),
    "backgrounds_identity": identity_background_assets(),
    "portraits_conformity": conformity_portrait_assets(),
    "backgrounds_conformity": conformity_background_assets(),
    "moods": mood_assets(),
}


# ── Generation ──────────────────────────────────────────────────────


def generate_one(spec: AssetSpec, client: object) -> bool:
    """Generate a single asset via Imagen 3. Returns True on success."""
    from google import genai  # type: ignore[import-untyped]

    output_path = VIEWER_ASSETS / spec.output_dir / spec.filename
    if output_path.exists():
        print(f"  SKIP {spec.asset_id} (already exists: {output_path})")
        return True

    print(f"  GEN  {spec.asset_id} → {output_path}")
    try:
        response = client.models.generate_images(
            model="imagen-4.0-generate-001",
            prompt=spec.prompt,
            config=genai.types.GenerateImagesConfig(
                number_of_images=1,
                aspect_ratio=spec.aspect_ratio,
                output_mime_type="image/png" if spec.filename.endswith(".png") else "image/jpeg",
            ),
        )

        if not response.generated_images:
            print(f"  FAIL {spec.asset_id}: no images returned")
            return False

        image_data = response.generated_images[0].image.image_bytes
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(image_data)

        size_kb = len(image_data) / 1024
        print(f"  OK   {spec.asset_id} ({size_kb:.0f} KB)")
        return True

    except Exception as e:
        print(f"  FAIL {spec.asset_id}: {e}")
        return False


def run(categories: list[str], dry_run: bool = False) -> None:
    """Run asset generation for specified categories."""
    specs: list[AssetSpec] = []
    for cat in categories:
        if cat == "all":
            for v in CATEGORIES.values():
                specs.extend(v)
            break
        if cat not in CATEGORIES:
            print(f"Unknown category: {cat}")
            print(f"Available: {', '.join(CATEGORIES)} or 'all'")
            sys.exit(1)
        specs.extend(CATEGORIES[cat])

    print(f"Assets to generate: {len(specs)}")
    for s in specs:
        print(f"  [{s.size_label:>9}] {s.output_dir}/{s.filename}")

    if dry_run:
        print("\n--dry-run: no images generated.")
        return

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("GEMINI_API_KEY not set.")
        sys.exit(1)

    from google import genai  # type: ignore[import-untyped]
    client = genai.Client(api_key=api_key)

    ok_count = 0
    fail_count = 0
    for i, spec in enumerate(specs, 1):
        print(f"\n[{i}/{len(specs)}] {spec.asset_id}")
        if generate_one(spec, client):
            ok_count += 1
        else:
            fail_count += 1

        # Rate limit: Imagen 3 has ~10 RPM for free tier
        if i < len(specs):
            time.sleep(8)

    print(f"\nDone: {ok_count} OK, {fail_count} failed out of {len(specs)} total.")


# ── CLI ─────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="TRPG Asset Generator (Imagen 3)")
    parser.add_argument(
        "--category", "-c",
        nargs="+",
        default=["all"],
        help="Asset categories to generate (default: all)",
    )
    parser.add_argument(
        "--dry-run", "-n",
        action="store_true",
        help="List assets without generating",
    )
    args = parser.parse_args()
    run(args.category, args.dry_run)


if __name__ == "__main__":
    main()
