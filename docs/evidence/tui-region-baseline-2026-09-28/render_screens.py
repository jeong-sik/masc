"""Rebuild the region baseline's screens from a CI log, with no TUI binary.

The baseline suites print each measured screen's bytes, zlib-compressed and
base64-encoded, between `=== region-baseline <screen> <cols>x<rows> begin ===`
and `... end ===`. This writes, per screen, the raw ANSI (`.ansi`), the text a
terminal shows (`.txt`) and a picture of it (`.png`), rendered with pyte and
Pillow.

    python3 render_screens.py ci-run-tests.log OUT_DIR --font REGULAR.ttf \
        --bold-font BOLD.ttf

Colours are an approximation of a dark terminal theme; cell positions and
widths are the TUI's own.
"""
import argparse
import base64
import re
import zlib
from pathlib import Path

import pyte
from PIL import Image, ImageDraw, ImageFont

MARKER = re.compile(
    r"=== region-baseline (?P<screen>\S+) (?P<cols>\d+)x(?P<rows>\d+) begin ===\n"
    r"(?P<body>.*?)\n=== region-baseline (?P=screen) (?P=cols)x(?P=rows) end ===",
    re.S,
)

FONT_SIZE = 15
PALETTE_COLOURS = 64
CELL_HEIGHT = 19
BACKGROUND = (0x1E, 0x1E, 0x2E)
FOREGROUND = (0xCD, 0xD6, 0xF4)
NAMED = {
    "black": (0x45, 0x47, 0x5A), "red": (0xF3, 0x8B, 0xA8),
    "green": (0xA6, 0xE3, 0xA1), "brown": (0xF9, 0xE2, 0xAF),
    "yellow": (0xF9, 0xE2, 0xAF), "blue": (0x89, 0xB4, 0xFA),
    "magenta": (0xF5, 0xC2, 0xE7), "cyan": (0x94, 0xE2, 0xD5),
    "white": (0xBA, 0xC2, 0xDE), "brightblack": (0x58, 0x5B, 0x70),
    "brightred": (0xF3, 0x8B, 0xA8), "brightgreen": (0xA6, 0xE3, 0xA1),
    "brightyellow": (0xF9, 0xE2, 0xAF), "brightblue": (0x89, 0xB4, 0xFA),
    "brightmagenta": (0xF5, 0xC2, 0xE7), "brightcyan": (0x94, 0xE2, 0xD5),
    "brightwhite": (0xA6, 0xAD, 0xC8),
}


class Screen(pyte.Screen):
    """pyte with the TUI's escapes it does not take.

    pyte has no faint attribute, and the TUI dims most secondary text, so SGR 2
    is carried in the blink slot and drawn half-way to the background. The
    parameters of a 38/48/58 colour are copied through so a 2 inside
    `48;2;r;g;b` is not read as faint. The private device queries and modes
    pyte rejects are ignored: they change nothing on screen."""

    def select_graphic_rendition(self, *attrs, **kwargs):
        if not attrs or attrs == (0,):
            super().select_graphic_rendition(*attrs)
            return
        out, index, values = [], 0, list(attrs)
        while index < len(values):
            value = values[index]
            if value in (38, 48, 58) and index + 1 < len(values):
                span = 5 if values[index + 1] == 2 else 2
                out += values[index : index + span]
                index += span
                continue
            if value == 2:
                out.append(5)
            elif value == 22:
                out += [22, 25]
            elif value != 5:
                out.append(value)
            index += 1
        super().select_graphic_rendition(*out)

    def report_device_status(self, *args, **kwargs):
        pass

    def report_device_attributes(self, *args, **kwargs):
        pass

    def set_mode(self, *modes, **kwargs):
        try:
            super().set_mode(*modes, **kwargs)
        except TypeError:
            pass

    def reset_mode(self, *modes, **kwargs):
        try:
            super().reset_mode(*modes, **kwargs)
        except TypeError:
            pass


def colour(name, default):
    if name == "default":
        return default
    if name in NAMED:
        return NAMED[name]
    if re.fullmatch(r"[0-9a-fA-F]{6}", name):
        return tuple(int(name[i : i + 2], 16) for i in (0, 2, 4))
    return default


def picture(screen, cols, rows, regular, bold):
    width = round(regular.getlength("M"))
    image = Image.new("RGB", (cols * width, rows * CELL_HEIGHT), BACKGROUND)
    draw = ImageDraw.Draw(image)
    for y in range(rows):
        line = screen.buffer[y]
        for x in range(cols):
            cell = line[x]
            fg, bg = colour(cell.fg, FOREGROUND), colour(cell.bg, BACKGROUND)
            if cell.reverse:
                fg, bg = bg, fg
            if cell.blink:
                fg = tuple((f + b) // 2 for f, b in zip(fg, bg))
            span = 2 if cell.data and pyte.screens.wcwidth(cell.data[0]) == 2 else 1
            if bg != BACKGROUND:
                draw.rectangle(
                    [x * width, y * CELL_HEIGHT, (x + span) * width - 1,
                     (y + 1) * CELL_HEIGHT - 1],
                    fill=bg,
                )
            if cell.data and cell.data != " ":
                draw.text((x * width, y * CELL_HEIGHT + 1), cell.data,
                          font=bold if cell.bold else regular, fill=fg)
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log")
    parser.add_argument("out_dir")
    parser.add_argument("--font", required=True)
    parser.add_argument("--bold-font", required=True)
    args = parser.parse_args()
    regular = ImageFont.truetype(args.font, FONT_SIZE)
    bold = ImageFont.truetype(args.bold_font, FONT_SIZE)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    text = Path(args.log).read_text(encoding="utf-8")
    written = 0
    for match in MARKER.finditer(text):
        cols, rows = int(match["cols"]), int(match["rows"])
        raw = zlib.decompress(base64.b64decode("".join(match["body"].split())))
        name = f"{match['screen']}-{cols}x{rows}"
        (out / f"{name}.ansi").write_bytes(raw)
        screen = Screen(cols, rows)
        pyte.ByteStream(screen).feed(raw)
        (out / f"{name}.txt").write_text(
            "\n".join(line.rstrip() for line in screen.display) + "\n",
            encoding="utf-8",
        )
        # A terminal screen has a few dozen colours; a palette image keeps
        # them and stores a fraction of the bytes.
        picture(screen, cols, rows, regular, bold).quantize(
            colors=PALETTE_COLOURS).save(out / f"{name}.png", optimize=True)
        written += 1
    if written == 0:
        raise SystemExit(f"no region-baseline screens in {args.log}")
    print(f"{written} screens written to {out}")


if __name__ == "__main__":
    main()
