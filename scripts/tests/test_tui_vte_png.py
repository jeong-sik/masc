# pyright: strict
"""PNG captures draw a wide character whole on a coloured background.

    python3 -m unittest scripts.tests.test_tui_vte_png

A wide character's glyph spans its own cell and the next. When the next cell
has a background colour, as a reverse-video selection row or a tinted pane
does, that background must not cover the glyph's right half. Needs Pillow and
a font with Hangul; the test is skipped without them. No TUI runs here.
"""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'harness' / 'tui'))
from vte import DEFAULT_BG, DEFAULT_FG, PNG_PAD, Rgb, Vte, png_cell_size, render_png  # noqa: E402

HANGUL_FONTS = (Path('/System/Library/Fonts/AppleSDGothicNeo.ttc'),
                Path('/usr/share/fonts/truetype/nanum/NanumGothicCoding.ttf'))
FONT = next((font for font in HANGUL_FONTS if font.is_file()), None)
HAS_PILLOW = importlib.util.find_spec('PIL') is not None
# 가: its vowel sits in the right half, the second cell.
WIDE = '가'
FONT_SIZE = 48  # large, so the second cell holds many glyph pixels


@unittest.skipUnless(HAS_PILLOW and FONT is not None, 'needs Pillow and a font with Hangul')
class WideGlyphTest(unittest.TestCase):
    def test_a_reverse_video_wide_glyph_keeps_its_right_half(self) -> None:
        assert FONT is not None
        from PIL import Image
        vte = Vte(4, 2)
        vte.feed(f'\x1b[1;1H{WIDE}\x1b[2;1H\x1b[7m{WIDE}\x1b[0m'.encode())
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / 'wide.png'
            self.assertIsNone(render_png(vte, path, [FONT], FONT_SIZE))
            size = png_cell_size(FONT, FONT_SIZE)
            assert not isinstance(size, str)
            cell_w, cell_h = size
            with Image.open(path) as opened:
                image = opened.convert('RGB')

        def ink_in_second_cell(row: int, background: Rgb) -> int:
            top = PNG_PAD + row * cell_h
            left = PNG_PAD + cell_w
            return sum(1 for x in range(left, left + cell_w) for y in range(top, top + cell_h)
                       if image.getpixel((x, y)) != background)

        plain = ink_in_second_cell(0, DEFAULT_BG)
        reversed_ink = ink_in_second_cell(1, DEFAULT_FG)  # reverse video: the background is the foreground colour
        self.assertGreater(plain, 0)
        self.assertGreater(reversed_ink, plain // 2)


if __name__ == '__main__':
    unittest.main()
