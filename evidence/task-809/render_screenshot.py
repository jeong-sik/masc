#!/usr/bin/env python3
"""Render the committed contract-after.txt verbatim block as a terminal-style
PNG screenshot for task-809 (#26656).

Reproduces masc/evidence/task-809/status-degraded.png from the [broken]
is_success .. Credential block (after-fix output, agents dir broken).
The block is extracted from status-degraded.html (same verbatim source),
HTML-unescaped, and drawn with DejaVu mono fonts. Char-level font fallback
covers the banner warning sign; pictographs without a local glyph are drawn
as notdef boxes, matching what a browser without emoji fonts shows.

Usage: PYTHONPATH=<pillow target> python3 render_screenshot.py
"""
import html
import re
import sys

from PIL import Image, ImageDraw, ImageFont

MONO = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"
MONO_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
SANS = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

BG = (20, 23, 28)          # #14171c
FG = (214, 217, 222)       # #d6d9de
TITLE = (154, 164, 178)    # #9aa4b2
SCALE = 2
BASE = 13                  # px, matches the HTML css font-size
LINE = 19                  # px, 13 * 1.5 rounded
PAD_X, PAD_T, PAD_B = 24, 20, 20

html_src = open("status-degraded.html", encoding="utf-8").read()
h1 = html.unescape(re.search(r"<h1>(.*?)</h1>", html_src, re.S).group(1))
pre = html.unescape(re.search(r"<pre>(.*?)</pre>", html_src, re.S).group(1))

font_mono = ImageFont.truetype(MONO, BASE * SCALE)
font_bold = ImageFont.truetype(MONO_BOLD, BASE * SCALE)
font_sans = ImageFont.truetype(SANS, BASE * SCALE)


def has_glyph(f, ch):
    if ch.isspace():
        return True
    try:
        return f.getmask(ch).getbbox() is not None
    except Exception:
        return False


def line_fonts(line):
    """Pick (font, start, end) runs; prefer mono, fall back to sans."""
    runs = []
    cur_font, start = None, 0
    for i, ch in enumerate(line):
        f = font_mono if has_glyph(font_mono, ch) else (
            font_sans if has_glyph(font_sans, ch) else None)
        if f is not cur_font:
            if cur_font is not None:
                runs.append((cur_font, start, i))
            cur_font, start = f, i
    runs.append((cur_font, start, len(line)))
    return runs


def draw_line(d, y, line, color):
    for f, s, e in line_fonts(line):
        seg = line[s:e]
        d.text((PAD_X * SCALE, y), seg, font=f or font_mono, fill=color)


lines_pre = pre.split("\n")
h1_lines = [h1]
max_len = max(len(l) for l in h1_lines + lines_pre)
width = int(font_mono.getlength("M") * max_len) + PAD_X * 2 * SCALE
n_lines = len(h1_lines) + 1 + len(lines_pre)  # h1, gap, pre
height = (PAD_T + PAD_B) * SCALE + n_lines * LINE * SCALE

img = Image.new("RGB", (width, height), BG)
d = ImageDraw.Draw(img)

y = PAD_T * SCALE
for line in h1_lines:
    draw_line(d, y, line, TITLE)
    y += LINE * SCALE
y += 10 * SCALE  # h1 margin-bottom
for line in lines_pre:
    draw_line(d, y, line, FG)
    y += LINE * SCALE

out = sys.argv[1] if len(sys.argv) > 1 else "status-degraded.png"
img.save(out, "PNG")
print("wrote", out, img.size)
