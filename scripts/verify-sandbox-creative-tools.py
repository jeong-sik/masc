#!/usr/bin/env python3
"""Create and reopen real creative artifacts inside the built Keeper image."""
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import wave

import cairosvg
from PIL import Image, ImageDraw, ImageFont
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen import canvas


def run(*argv):
    return subprocess.run(argv, check=True, capture_output=True, text=True).stdout


out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
title = "기억과 창작"
font_path = run("fc-match", "-f", "%{file}", "NanumGothic").strip()
font = ImageFont.truetype(font_path, 32)
card = Image.new("RGB", (640, 360), "white")
ImageDraw.Draw(card).text((40, 80), title, font=font, fill="navy")
card.save(out / "card.png")
card.save(out / "card.jpg")
card.save(out / "card.gif", save_all=True,
          append_images=[Image.new("RGB", card.size, "lightblue")], duration=250, loop=0)
for name in ("card.png", "card.jpg", "card.gif"):
    with Image.open(out / name) as im:
        im.load()
        assert im.size == (640, 360)

svg = f'<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360"><rect width="640" height="360" fill="white"/><text x="40" y="120" font-family="NanumGothic" font-size="32">{title}</text></svg>'
(out / "diagram.svg").write_text(svg)
cairosvg.svg2png(bytestring=svg.encode(), write_to=str(out / "diagram.png"))
with Image.open(out / "diagram.png") as im:
    im.load()
    assert im.size == (640, 360)
pdfmetrics.registerFont(TTFont("Korean", font_path))
pdf = canvas.Canvas(str(out / "guide.pdf"))
pdf.setFont("Korean", 24)
pdf.drawString(50, 760, title)
pdf.drawImage(str(out / "card.png"), 50, 450, width=480, height=270)
pdf.save()
assert title in run("pdftotext", str(out / "guide.pdf"), "-")
run("pdftoppm", "-singlefile", "-png", "-scale-to", "1000",
    str(out / "guide.pdf"), str(out / "guide-render"))
with Image.open(out / "guide-render.png") as im:
    im.load()
    assert im.convert("L").getextrema()[0] < 255

(out / "slides.md").write_text(f"# {title}\n\nA Keeper can create and inspect a presentation.\n")
run("pandoc", str(out / "slides.md"), "-o", str(out / "slides.pptx"))
run("libreoffice", "-env:UserInstallation=file:///tmp/masc-creative-proof-office",
    "--headless", "--convert-to", "pdf", "--outdir", str(out), str(out / "slides.pptx"))
assert title in run("pdftotext", str(out / "slides.pdf"), "-")
run("pdftoppm", "-singlefile", "-png", "-scale-to", "1000",
    str(out / "slides.pdf"), str(out / "slides-render"))
with Image.open(out / "slides-render.png") as im:
    im.load()
    assert min(im.size) > 0 and max(im.size) == 1000

# A one-second fixture exercises encoding/decoding; it is not a runtime budget.
with wave.open(str(out / "tone.wav"), "wb") as wav:
    wav.setparams((1, 2, 24000, 24000, "NONE", "not compressed"))
    wav.writeframes(b"".join(struct.pack("<h", int(4000 * math.sin(2 * math.pi * 440 * n / 24000))) for n in range(24000)))
run("ffmpeg", "-v", "error", "-y", "-i", str(out / "tone.wav"), str(out / "tone.mp3"))
run("ffmpeg", "-v", "error", "-y", "-loop", "1", "-i", str(out / "card.png"),
    "-i", str(out / "tone.wav"), "-t", "1", "-c:v", "libx264", "-pix_fmt", "yuv420p",
    "-c:a", "aac", str(out / "clip.mp4"))
media = {}
for name in ("tone.wav", "tone.mp3", "clip.mp4"):
    media[name] = json.loads(run("ffprobe", "-v", "error", "-show_streams", "-of", "json", str(out / name)))
    assert media[name]["streams"]
    run("ffmpeg", "-v", "error", "-i", str(out / name), "-f", "null", "-")
assert {s["codec_type"] for s in media["clip.mp4"]["streams"]} == {"audio", "video"}
files = {p.name: {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
         for p in out.iterdir() if p.is_file()}
(out / "receipt.json").write_text(json.dumps({"files": files, "media": media, "font": font_path,
    "scope": "Synthetic image capability proof; not autonomous Keeper behavior."}, indent=2) + "\n")
print(json.dumps({"artifacts": sorted(files), "status": "passed"}))
