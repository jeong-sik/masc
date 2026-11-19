# pyright: strict
"""A terminal grid that reads what a TUI draws, row by row.

It knows what the TUI's frame presenter writes (bin/masc_tui_frame_presenter.ml):
cursor addressing, erase in line and display, SGR colours and weights, and
private modes, which it ignores. Wide characters take two cells by East Asian
Width, as the TUI measures them. It answers the queries a TUI asks at start:
cursor position (CSI 6n), device attributes (CSI c) and the OSC 10, 11 and 4
colour queries. `feed` returns those answers; the caller writes them back.

`render_png` draws the grid with Pillow and a monospace font the caller names.
It is optional: nothing here imports Pillow unless it is called.
"""
import codecs
from dataclasses import dataclass, replace
from pathlib import Path
from collections.abc import Sequence
import unicodedata

type Rgb = tuple[int, int, int]

DEFAULT_BG: Rgb = (13, 16, 23)
DEFAULT_FG: Rgb = (230, 237, 243)
ANSI_16: tuple[Rgb, ...] = (
    (21, 26, 36), (244, 112, 103), (87, 219, 138), (235, 192, 109),
    (108, 182, 255), (210, 168, 255), (86, 212, 221), (184, 196, 210),
    (99, 110, 123), (255, 123, 114), (126, 231, 135), (242, 204, 96),
    (121, 192, 255), (219, 171, 255), (121, 228, 238), (240, 246, 252),
)
ESC = '\x1b'
BEL = '\x07'
TAB_STOP = 8
CUBE_BASE = 16
CUBE_STEPS = 6
CUBE_FIRST = 55
CUBE_STEP = 40
GRAY_BASE = 232
GRAY_FIRST = 8
GRAY_STEP = 10
DEVICE_ATTRIBUTES = b'\x1b[?62;22c'
STRING_INTRODUCERS = frozenset({']', 'P', '_', '^'})
CHARSET_INTRODUCERS = frozenset({'(', ')', '*', '+'})
ZERO_WIDTH = frozenset({0x200B, 0x200D, 0xFE0F})
FAINT_MIX = 0.5  # how far faint text moves toward its background in a PNG
PNG_FONT_SIZE = 18
PNG_PAD = 10
PNG_LINE_GAP = 3


@dataclass(frozen=True, slots=True)
class Pen:
    fg: Rgb = DEFAULT_FG
    bg: Rgb = DEFAULT_BG
    bold: bool = False
    faint: bool = False
    underline: bool = False
    reverse: bool = False


@dataclass(frozen=True, slots=True)
class Cell:
    text: str = ' '
    pen: Pen = Pen()
    wide_tail: bool = False  # the second cell of a wide character


BLANK = Cell()


def xterm_256(index: int) -> Rgb:
    if index < CUBE_BASE:
        return ANSI_16[index]
    if index < GRAY_BASE:
        cube = index - CUBE_BASE

        def level(value: int) -> int:
            return 0 if value == 0 else CUBE_FIRST + value * CUBE_STEP

        return (level(cube // (CUBE_STEPS * CUBE_STEPS) % CUBE_STEPS), level(cube // CUBE_STEPS % CUBE_STEPS),
                level(cube % CUBE_STEPS))
    gray = GRAY_FIRST + (index - GRAY_BASE) * GRAY_STEP
    return (gray, gray, gray)


def is_control(ch: str) -> bool:
    code = ord(ch[0])
    return code < 0x20 or 0x7F <= code < 0xA0


def char_width(ch: str) -> int:
    if unicodedata.combining(ch[0]) or ord(ch[0]) in ZERO_WIDTH:
        return 0
    return 2 if unicodedata.east_asian_width(ch[0]) in ('W', 'F') else 1


def clamp_byte(value: int) -> int:
    return max(0, min(255, value))


def colour_reply(code: str, rgb: Rgb) -> bytes:
    r, g, b = rgb
    return f'\x1b]{code};rgb:{r:02x}{r:02x}/{g:02x}{g:02x}/{b:02x}{b:02x}\x1b\\'.encode()


class Vte:
    def __init__(self, columns: int, rows: int) -> None:
        self.columns = columns
        self.rows = rows
        self._grid = [[BLANK] * columns for _ in range(rows)]
        self._pen = Pen()
        self._x = 0
        self._y = 0
        self._decoder = codecs.getincrementaldecoder('utf-8')('replace')
        self._pending = ''

    def row_text(self, row: int) -> str:
        return ''.join(cell.text for cell in self._grid[row] if not cell.wide_tail).rstrip()

    def screen_text(self) -> str:
        return '\n'.join(self.row_text(row) for row in range(self.rows))

    def row_cells(self, row: int) -> tuple[Cell, ...]:
        return tuple(self._grid[row])

    def feed(self, data: bytes) -> bytes:
        """Apply what the TUI wrote; return the answers it asked for."""
        text = self._pending + self._decoder.decode(data, final=False)
        self._pending = ''
        replies = bytearray()
        at, end = 0, len(text)
        while at < end:
            ch = text[at]
            if ch != ESC:
                self._put(ch)
                at += 1
                continue
            if at + 1 >= end:
                self._pending = text[at:]
                break
            kind = text[at + 1]
            if kind == '[':
                finished = self._csi(text, at, replies)
            elif kind in STRING_INTRODUCERS:
                finished = self._string(text, at, replies)
            elif kind in CHARSET_INTRODUCERS:
                finished = at + 3 if at + 2 < end else None
            else:
                finished = at + 2
            if finished is None:
                self._pending = text[at:]
                break
            at = finished
        return bytes(replies)

    def _csi(self, text: str, at: int, replies: bytearray) -> int | None:
        cursor = at + 2
        private = ''
        if cursor < len(text) and text[cursor] in '?=>!<':
            private = text[cursor]
            cursor += 1
        start = cursor
        while cursor < len(text) and not 0x40 <= ord(text[cursor]) <= 0x7E:
            cursor += 1
        if cursor >= len(text):
            return None
        self._apply_csi(private, text[start:cursor], text[cursor], replies)
        return cursor + 1

    def _string(self, text: str, at: int, replies: bytearray) -> int | None:
        cursor = at + 2
        while cursor < len(text):
            if text[cursor] == BEL:
                body_end, finished = cursor, cursor + 1
                break
            if text[cursor] == ESC and cursor + 1 < len(text) and text[cursor + 1] == '\\':
                body_end, finished = cursor, cursor + 2
                break
            cursor += 1
        else:
            return None
        if text[at + 1] == ']':
            replies.extend(self._osc(text[at + 2:body_end]))
        return finished

    def _osc(self, payload: str) -> bytes:
        if payload == '10;?':
            return colour_reply('10', DEFAULT_FG)
        if payload == '11;?':
            return colour_reply('11', DEFAULT_BG)
        parts = payload.split(';')
        if len(parts) == 3 and parts[0] == '4' and parts[2] == '?' and parts[1].isdigit():
            index = int(parts[1])
            if index < len(ANSI_16):
                return colour_reply(f'4;{index}', ANSI_16[index])
        return b''

    def _apply_csi(self, private: str, body: str, final: str, replies: bytearray) -> None:
        numbers = [int(head) if (head := part.split(':')[0]).isdigit() else 0 for part in body.split(';')]
        first = numbers[0] if numbers else 0
        count = first or 1
        if private == '' and final == 'm':
            self._sgr(numbers if body else [0])
            return
        if private != '':
            return
        match final:
            case 'H' | 'f':
                row = (numbers[0] if numbers and numbers[0] > 0 else 1) - 1
                column = (numbers[1] if len(numbers) > 1 and numbers[1] > 0 else 1) - 1
                self._y = max(0, min(self.rows - 1, row))
                self._x = max(0, min(self.columns - 1, column))
            case 'A':
                self._y = max(0, self._y - count)
            case 'B':
                self._y = min(self.rows - 1, self._y + count)
            case 'C':
                self._x = min(self.columns - 1, self._x + count)
            case 'D':
                self._x = max(0, self._x - count)
            case 'G':
                self._x = max(0, min(self.columns - 1, count - 1))
            case 'd':
                self._y = max(0, min(self.rows - 1, count - 1))
            case 'J':
                self._erase_display(first)
            case 'K':
                self._erase_line(first)
            case 'X':
                for column in range(self._x, min(self.columns, self._x + count)):
                    self._grid[self._y][column] = self._blank()
            case 'n' if body == '6':
                replies.extend(f'\x1b[{self._y + 1};{self._x + 1}R'.encode())
            case 'c':
                replies.extend(DEVICE_ATTRIBUTES)
            case _:
                pass

    def _blank(self) -> Cell:
        return Cell(pen=Pen(bg=self._pen.bg))

    def _erase_display(self, mode: int) -> None:
        if mode in (2, 3):
            self._grid = [[self._blank()] * self.columns for _ in range(self.rows)]
        elif mode == 0:
            self._erase_line(0)
            for row in range(self._y + 1, self.rows):
                self._grid[row] = [self._blank()] * self.columns

    def _erase_line(self, mode: int) -> None:
        span = {0: range(self._x, self.columns), 1: range(0, min(self.columns, self._x + 1)),
                2: range(self.columns)}.get(mode, range(0))
        for column in span:
            self._grid[self._y][column] = self._blank()

    def _sgr(self, params: list[int]) -> None:
        at = 0
        pen = self._pen
        while at < len(params):
            code = params[at]
            match code:
                case 0:
                    pen = Pen()
                case 1:
                    pen = replace(pen, bold=True)
                case 2:
                    pen = replace(pen, faint=True)
                case 4:
                    pen = replace(pen, underline=True)
                case 7:
                    pen = replace(pen, reverse=True)
                case 22:
                    pen = replace(pen, bold=False, faint=False)
                case 24:
                    pen = replace(pen, underline=False)
                case 27:
                    pen = replace(pen, reverse=False)
                case 39:
                    pen = replace(pen, fg=DEFAULT_FG)
                case 49:
                    pen = replace(pen, bg=DEFAULT_BG)
                case 38 | 48 | 58:
                    # 58 is the underline colour, not drawn; its parameters are skipped.
                    colour, used = self._extended_colour(params, at)
                    if colour is not None and code == 38:
                        pen = replace(pen, fg=colour)
                    elif colour is not None and code == 48:
                        pen = replace(pen, bg=colour)
                    at += used
                case _ if 30 <= code <= 37:
                    pen = replace(pen, fg=ANSI_16[code - 30])
                case _ if 40 <= code <= 47:
                    pen = replace(pen, bg=ANSI_16[code - 40])
                case _ if 90 <= code <= 97:
                    pen = replace(pen, fg=ANSI_16[code - 90 + 8])
                case _ if 100 <= code <= 107:
                    pen = replace(pen, bg=ANSI_16[code - 100 + 8])
                case _:
                    pass
            at += 1
        self._pen = pen

    @staticmethod
    def _extended_colour(params: list[int], at: int) -> tuple[Rgb | None, int]:
        """The colour of SGR 38 or 48 at `at`, and how many parameters after it it used."""
        if at + 2 < len(params) and params[at + 1] == 5:
            return xterm_256(clamp_byte(params[at + 2])), 2
        if at + 4 < len(params) and params[at + 1] == 2:
            r, g, b = (clamp_byte(value) for value in params[at + 2:at + 5])
            return (r, g, b), 4
        return None, 0

    def _put(self, ch: str) -> None:
        match ch:
            case '\r':
                self._x = 0
                return
            case '\n':
                self._y = min(self.rows - 1, self._y + 1)
                return
            case '\b':
                self._x = max(0, self._x - 1)
                return
            case '\t':
                self._x = min(self.columns - 1, (self._x + TAB_STOP) // TAB_STOP * TAB_STOP)
                return
            case _ if is_control(ch):
                return
            case _:
                pass
        width = char_width(ch)
        row = self._grid[self._y]
        if width == 0:
            if self._x > 0:
                base = self._x - 1
                if row[base].wide_tail and base > 0:
                    base -= 1
                row[base] = replace(row[base], text=row[base].text + ch)
            return
        if self._x + width > self.columns:
            return
        row[self._x] = Cell(ch, self._pen)
        if width == 2:
            row[self._x + 1] = Cell('', self._pen, wide_tail=True)
        self._x = min(self.columns, self._x + width)


def mix(a: Rgb, b: Rgb, t: float) -> Rgb:
    return (round(a[0] * (1 - t) + b[0] * t), round(a[1] * (1 - t) + b[1] * t), round(a[2] * (1 - t) + b[2] * t))


def cell_colours(cell: Cell) -> tuple[Rgb, Rgb]:
    """The foreground and background a cell is drawn with, reverse video applied."""
    return (cell.pen.bg, cell.pen.fg) if cell.pen.reverse else (cell.pen.fg, cell.pen.bg)


def png_cell_size(font_path: Path, font_size: int = PNG_FONT_SIZE) -> tuple[int, int] | str:
    """The pixel size of one cell drawn with this font, or why the font cannot draw."""
    try:
        from PIL import ImageFont
    except ImportError:
        return 'PNG output needs Pillow (python3 -m pip install Pillow)'
    try:
        font = ImageFont.truetype(str(font_path), font_size)
    except OSError as exc:
        return f'{font_path}: {exc}'
    ascent, descent = font.getmetrics()
    return round(font.getlength('M')), ascent + descent + PNG_LINE_GAP


def render_png(vte: Vte, path: Path, font_paths: Sequence[Path], font_size: int = PNG_FONT_SIZE) -> str | None:
    """Draw the grid to `path`; None once written, else why it was not.

    The first font sets the cell size. Each glyph is drawn with the first font
    that has it, so a fallback font fills in what the first one lacks (a
    monospace font often has no braille, and a graph row would draw blank).
    A glyph no font has is drawn with the first font."""
    if not font_paths:
        return 'no font given'
    size = png_cell_size(font_paths[0], font_size)
    if isinstance(size, str):
        return size
    from PIL import Image, ImageDraw, ImageFont
    cell_w, cell_h = size
    fonts: list[ImageFont.FreeTypeFont] = []
    for font_path in font_paths:
        try:
            fonts.append(ImageFont.truetype(str(font_path), font_size))
        except OSError as exc:
            return f'{font_path}: {exc}'
    chosen: dict[str, ImageFont.FreeTypeFont] = {}

    def font_for(text: str) -> ImageFont.FreeTypeFont:
        found = chosen.get(text)
        if found is None:
            # A font without the glyph draws an empty mask.
            found = next((f for f in fonts if f.getmask(text).getbbox() is not None), fonts[0])
            chosen[text] = found
        return found
    image = Image.new('RGB', (vte.columns * cell_w + 2 * PNG_PAD, vte.rows * cell_h + 2 * PNG_PAD), DEFAULT_BG)
    draw = ImageDraw.Draw(image)
    cells = [(PNG_PAD + column * cell_w, PNG_PAD + row * cell_h, cell)
             for row in range(vte.rows) for column, cell in enumerate(vte.row_cells(row))]
    # Every background before any glyph: a wide glyph runs into the next
    # cell, and that cell's background would cover its right half.
    for x, y, cell in cells:
        _, bg = cell_colours(cell)
        if bg != DEFAULT_BG:
            draw.rectangle((x, y, x + cell_w - 1, y + cell_h - 1), fill=bg)
    for x, y, cell in cells:
        if cell.wide_tail or cell.text in (' ', ''):
            continue
        fg, bg = cell_colours(cell)
        ink = mix(fg, bg, FAINT_MIX) if cell.pen.faint else fg
        draw.text((x, y + 2), cell.text, font=font_for(cell.text), fill=ink)
        if cell.pen.underline:
            draw.line((x, y + cell_h - 2, x + cell_w - 1, y + cell_h - 2), fill=ink)
    try:
        image.save(path)
    except OSError as exc:
        return f'{path}: {exc}'
    return None
