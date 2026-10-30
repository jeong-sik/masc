"""Rebuild the region baseline's screens with no TUI binary.

The baseline suites print each measured screen's bytes, zlib-compressed and
base64-encoded, between `=== region-baseline <screen> <cols>x<rows> begin ===`
and `... end ===`. Two ways in:

    python3 render_screens.py log ci-run-tests.log OUT_DIR [--png NAME ...]
    python3 render_screens.py ansi SCREENS_DIR [--png NAME ...]

`log` writes, per screen in a CI run's `suite-runner-log`, the raw ANSI
(`<screen>-<cols>x<rows>.ansi`) and the text a terminal shows (`.txt`).
`ansi` reads the committed `.ansi` files and writes their `.txt` again: the
CI artifact expires, the committed bytes do not. Either renders a `.png`,
with pyte and Pillow, for each screen named by `--png` (`keepers-80x30`), with
the fonts given by `--font` and `--bold-font`.

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


def screens_from_log(path: Path):
    text = path.read_text(encoding="utf-8")
    for match in MARKER.finditer(text):
        name = f"{match['screen']}-{match['cols']}x{match['rows']}"
        raw = zlib.decompress(base64.b64decode("".join(match["body"].split())))
        yield name, int(match["cols"]), int(match["rows"]), raw


ANSI_NAME = re.compile(r"(?P<screen>.+)-(?P<cols>\d+)x(?P<rows>\d+)\.ansi")


def screens_from_ansi(directory: Path):
    for path in sorted(directory.glob("*.ansi")):
        match = ANSI_NAME.fullmatch(path.name)
        if match is None:
            raise SystemExit(f"not a screen file: {path}")
        yield path.stem, int(match["cols"]), int(match["rows"]), path.read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="source", required=True)
    from_log = sub.add_parser("log")
    from_log.add_argument("log")
    from_log.add_argument("out_dir")
    from_ansi = sub.add_parser("ansi")
    from_ansi.add_argument("out_dir")
    for each in (from_log, from_ansi):
        each.add_argument("--png", nargs="*", default=[])
        each.add_argument("--font")
        each.add_argument("--bold-font")
    args = parser.parse_args()
    if args.png and not (args.font and args.bold_font):
        raise SystemExit("--png needs --font and --bold-font")
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    screens = (screens_from_log(Path(args.log)) if args.source == "log"
               else screens_from_ansi(out))
    fonts = ((ImageFont.truetype(args.font, FONT_SIZE),
              ImageFont.truetype(args.bold_font, FONT_SIZE)) if args.png else None)
    written = 0
    for name, cols, rows, raw in screens:
        if args.source == "log":
            (out / f"{name}.ansi").write_bytes(raw)
        screen = Screen(cols, rows)
        pyte.ByteStream(screen).feed(raw)
        (out / f"{name}.txt").write_text(
            "\n".join(line.rstrip() for line in screen.display) + "\n",
            encoding="utf-8",
        )
        if name in args.png:
            # A terminal screen has a few dozen colours; a palette image keeps
            # them and stores a fraction of the bytes.
            picture(screen, cols, rows, *fonts).quantize(
                colors=PALETTE_COLOURS).save(out / f"{name}.png", optimize=True)
        written += 1
    missing = set(args.png) - {path.stem for path in out.glob("*.png")}
    if written == 0 or missing:
        raise SystemExit(f"{written} screens written; no screen for {sorted(missing)}")
    print(f"{written} screens written to {out}")


if __name__ == "__main__":
    main()
