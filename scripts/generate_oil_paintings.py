#!/usr/bin/env python3
"""
Generate oil painting style assets for MASC Viewer using Gemini API.
Uses google.genai (new SDK) for image generation support.
"""

import os
import sys
import base64
import time
from pathlib import Path

from google import genai
from google.genai import types
from PIL import Image
import io

# Configure Gemini client
client = genai.Client(api_key=os.environ.get("GEMINI_API_KEY"))

# Style prompt prefix for all images
STYLE_PREFIX = """Classical oil painting on canvas, thick impasto brushstrokes clearly visible,
palette knife texture, paint layered and cracking at edges, like a Rembrandt
or Caravaggio dark master painting. Dramatic chiaroscuro single-source lighting.
NOT digital art, NOT illustration — real oil paint on canvas texture must be
visible. Muted earthy tones: burnt umber, raw sienna, lamp black, Naples yellow.
Disco Elysium concept art aesthetic mixed with old master technique."""

# Portrait prompts
PORTRAITS = {
    "grimja": "battle-ravaged human warrior woman, crude wire jaw, cracked armor, broken-tooth grin, dried blood in beard, one swollen eye, fierce determination",
    "luna": "gaunt elf mage, hollow cheekbones, too-bright eyes, staff wrapped in hair, ink-stained robes, nervous crooked smile, ethereal but unsettling",
    "songarak": "sharp-faced halfling rogue, missing fingers, unsettling wide grin, moth-eaten cloak, necklace of teeth, cunning and dangerous",
    "miso": "sweating human cleric, cracked holy symbol, darting eyes, too-wide practiced smile, yellow-stained vestments, false piety",
}

# Map prompts
MAPS = {
    "area_a": "dark forest trail at night, trees like screaming faces, goblin eyes glowing in branches, dark wet muddy ground, unnatural purple fungus growing on rotting logs, fog rolling between twisted roots",
    "area_b": "cracked ancient stone well in clearing, sickly green glowing water inside, dead birds scattered around edge, wilted grey vegetation, small floating doll in water, ominous moonlight",
    "area_c": "medieval tavern interior, peeling walls with water stains, skull candle holders on tables, shadowed patrons in corners, noose hanging behind bar, dim lantern light through smoke",
    "area_d": "cave mouth wrapped in thick spider webs, desiccated husks cocooned in silk, breathing darkness within, web patterns forming strange letters, bones scattered at entrance",
    "area_e": "underground market in cavern, rib-cage chandeliers with candles, mysterious jars on stalls, merchants with too many fingers, red and green dramatic lighting, exotic and dangerous goods",
    "area_f": "crumbling ancient stone bridge over chasm, massive troll silhouette in mist, stones carved with faces in agony, copper-smelling mist rising from below, moonlight breaking through clouds",
}


def generate_image(prompt: str, output_path: Path, size: tuple[int, int]) -> bool:
    """Generate an image using Gemini 2.5 Flash Image and save it."""
    full_prompt = f"{STYLE_PREFIX}\n\n{prompt}"

    try:
        response = client.models.generate_content(
            model=os.getenv("MASC_IMAGE_MODEL", "gemini-3-flash-preview"),
            contents=full_prompt,
            config=types.GenerateContentConfig(
                response_modalities=["IMAGE", "TEXT"],
            )
        )

        # Extract image from response
        for part in response.candidates[0].content.parts:
            if part.inline_data is not None:
                # Data is already raw bytes, not base64 encoded
                image = Image.open(io.BytesIO(part.inline_data.data))

                # Resize to target size
                image = image.resize(size, Image.Resampling.LANCZOS)

                # Save as PNG for portraits, JPG for maps
                if output_path.suffix == ".png":
                    image.save(output_path, "PNG")
                else:
                    image.save(output_path, "JPEG", quality=90)

                print(f"✓ Generated: {output_path.name} ({output_path.stat().st_size // 1024}KB)")
                return True

        print(f"✗ No image in response for {output_path.name}")
        return False

    except Exception as e:
        print(f"✗ Error generating {output_path.name}: {e}")
        return False


def main():
    base_dir = Path(__file__).parent.parent / "viewer" / "assets"
    portraits_dir = base_dir / "portraits"
    maps_dir = base_dir / "maps"

    print("🎨 Generating oil painting style assets...\n")

    # Generate portraits (512x512)
    print("📷 Portraits (512x512):")
    for name, prompt in PORTRAITS.items():
        output_path = portraits_dir / f"{name}.png"
        generate_image(prompt, output_path, (512, 512))
        time.sleep(2)  # Rate limiting

    print()

    # Generate maps (1920x1080)
    print("🗺️  Maps (1920x1080):")
    for name, prompt in MAPS.items():
        output_path = maps_dir / f"{name}.jpg"
        generate_image(prompt, output_path, (1920, 1080))
        time.sleep(2)  # Rate limiting

    print("\n✅ Done!")


if __name__ == "__main__":
    main()
