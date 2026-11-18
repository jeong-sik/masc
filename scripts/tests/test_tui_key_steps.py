# pyright: strict
"""The key steps of idle.py: which keys may be pressed, how a captured screen's
layout kind is read from its card edges, and what each key reports.

    python3 -m unittest scripts.tests.test_tui_key_steps

Screens are drawn into the harness's own terminal emulator, so cells, wide
characters and colours are the ones a real capture holds. No TUI, relay or
MASC server runs here.
"""
from pathlib import Path
import sys
from typing import cast
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'harness' / 'tui'))
from key_steps import (Capture, NavKey, Outcome, Pressed, PngWritten, key_bytes, key_steps_report,  # noqa: E402
                       parse_keys)
from screen_layout import Kind, Screen, Shape, changed_rows, layout_of, snapshot, text_changed_rows  # noqa: E402
from vte import Vte  # noqa: E402

COLUMNS = 60
REVERSE = '\x1b[7m'
RESET = '\x1b[0m'

# Two full cards side by side, then a full card beside a squashed one, as
# bin/masc_tui_card.ml draws them. Names are Hangul, two cells each.
CARDS = (
    'tabs',
    '╭─ p 확인할 일 ───── 0 ─╮  ╭─ v 조치 ───────── 5 ─╮',
    '│ 대기 없음             │  │ fleet              │',
    '╰──────────────────────╯  │ memory             │',
    '╭─ 대화 ─────────── 2 ─╮  ╰────────────────────╯',
    '│ 이어가기              │  ╶─ m 실행 여력 ◌ ─────╴',
    '╰──────────────────────╯',
    'footer',
)
PLAIN = (
    'tabs',
    '──────────────────────────────────────────── │ side pane',
    'p 확인할 일 0                                 │ row',
    'v 조치 5                                      ├────────',
    '  fleet                                       │ row',
    '  memory                                      │',
    '',
    'footer',
)
# Glyphs that are no card edge: a chat's turn rail (a glyph, then a space),
# an opening whose closing is cut off, and closings without an opening.
PARTIAL = (
    '  ╭ 02:13 said something',
    '  ╶ tool call',
    '╭─ cut at the screen edge ─────────',
    '───╮ ─╯ ─╴',
    '╶─ next card opens before ╭─ x ─╮',
    '',
)


def one(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    return cast(dict[str, object], value)


def each(value: object) -> list[dict[str, object]]:
    assert isinstance(value, list)
    return [one(item) for item in cast(list[object], value)]


def screen(lines: tuple[str, ...], selected: int | None = None) -> Screen:
    vte = Vte(COLUMNS, len(lines))
    for row, line in enumerate(lines):
        styled = f'{REVERSE}{line}{RESET}' if row == selected else line
        vte.feed(f'\x1b[{row + 1};1H{styled}'.encode())
    return snapshot(vte)


class ParseKeysTest(unittest.TestCase):
    def test_navigation_keys_are_read_in_order(self) -> None:
        self.assertEqual(parse_keys('j,j,k, PgDn,Home,End,Tab,PgUp'),
                         (NavKey.J, NavKey.J, NavKey.K, NavKey.PG_DN, NavKey.HOME, NavKey.END, NavKey.TAB,
                          NavKey.PG_UP))
        self.assertEqual(parse_keys(''), ())

    def test_keys_that_can_write_or_leave_a_chat_are_refused(self) -> None:
        for name in ('p', 'w', 's', 'x', 'g', 'U', 'Esc', 'Enter', 'J'):
            with self.subTest(name):
                refused = parse_keys(f'j,{name}')
                assert isinstance(refused, str)
                self.assertIn(name, refused)

    def test_keys_are_the_bytes_the_tui_decodes(self) -> None:
        # bin/masc_tui_csi.ml: ESC [ 5 ~ is pageup, ESC [ 6 ~ pagedown, ESC [ H home, ESC [ F end.
        self.assertEqual([key_bytes(key) for key in NavKey],
                         [b'j', b'k', b'\x1b[5~', b'\x1b[6~', b'\x1b[H', b'\x1b[F', b'\t'])


class LayoutTest(unittest.TestCase):
    def test_cards_are_found_with_their_shapes(self) -> None:
        layout = layout_of(screen(CARDS))
        self.assertIs(layout.kind, Kind.CARDS)
        self.assertEqual(layout.card_rows, (1, 3, 4, 5, 6))
        shapes = [(edge.row, edge.shape) for edge in layout.edges]
        self.assertEqual(shapes, [(1, Shape.TOP), (1, Shape.TOP), (3, Shape.BOTTOM), (4, Shape.TOP),
                                  (4, Shape.BOTTOM), (5, Shape.SQUASHED), (6, Shape.BOTTOM)])

    def test_edge_columns_count_wide_characters_as_two_cells(self) -> None:
        first = layout_of(screen(CARDS)).edges[0]
        # '╭─ p ' is 5 cells, '확인할 일' 9 (four wide characters and a space),
        # then ' ───── 0 ─╮' 11: the closing is cell 24, character 20.
        self.assertEqual((first.start, first.end), (0, 24))

    def test_a_screen_without_card_edges_is_plain(self) -> None:
        layout = layout_of(screen(PLAIN))
        self.assertIs(layout.kind, Kind.PLAIN)
        self.assertEqual(layout.card_rows, ())

    def test_stray_and_unclosed_glyphs_are_no_edges(self) -> None:
        layout = layout_of(screen(PARTIAL))
        # Only the closed card at the end of the last line counts.
        self.assertEqual([(edge.row, edge.shape) for edge in layout.edges], [(4, Shape.TOP)])
        self.assertIs(layout_of(screen(PARTIAL[:4])).kind, Kind.PLAIN)

    def test_a_card_whose_bottom_is_off_screen_still_counts(self) -> None:
        self.assertIs(layout_of(screen(CARDS[:3])).kind, Kind.CARDS)

    def test_one_edge_alone_makes_cards(self) -> None:
        layout = layout_of(screen(('', '╰──────────╯', '')))
        self.assertIs(layout.kind, Kind.CARDS)
        self.assertEqual(layout.card_rows, (1,))

    def test_a_name_that_fills_the_edge_up_to_its_corner_still_makes_an_edge(self) -> None:
        # An edge with no count and a name cut to the room it has leaves no
        # rule before the closing glyph: card.ml draws `╭─ <name> ╮` and the
        # squashed `╶─ <name> ╴`. A focused list's edge writes no count.
        lines = ('╭─ 조치가 필요한 이유 ╮', '│ 대기 없음           │', '╰────────────────────╯',
                 '╶─ m 실행 여력 ◌ ╴')
        layout = layout_of(screen(lines))
        self.assertEqual([(edge.row, edge.shape) for edge in layout.edges],
                         [(0, Shape.TOP), (2, Shape.BOTTOM), (3, Shape.SQUASHED)])
        self.assertIs(layout_of(screen(lines[3:])).kind, Kind.CARDS)

    def test_an_opening_before_a_closing_starts_the_edge_over(self) -> None:
        # The first opening has no closing of its own, so the edge runs from
        # the second opening (cell 5) to the closing (cell 11), not from cell 0.
        edges = layout_of(screen(('╭─ a ╭─ b ─╮',))).edges
        self.assertEqual([(edge.start, edge.end, edge.shape) for edge in edges], [(5, 11, Shape.TOP)])


class ChangedRowsTest(unittest.TestCase):
    def test_a_moved_highlight_changes_cells_but_not_text(self) -> None:
        before, after = screen(CARDS, selected=2), screen(CARDS, selected=3)
        self.assertEqual(changed_rows(before, after), (2, 3))
        self.assertEqual(text_changed_rows(before, after), ())

    def test_a_new_layout_changes_text(self) -> None:
        self.assertEqual(text_changed_rows(screen(CARDS), screen(PLAIN)), (1, 2, 3, 4, 5, 6))


class ReportTest(unittest.TestCase):
    def test_each_key_reports_its_rows_and_layout_against_the_capture_before_it(self) -> None:
        start = Capture(screen(CARDS, selected=2), PngWritten('overview.key0.png'))
        pressed = (
            Pressed(NavKey.J, Outcome.QUIET, Capture(screen(CARDS, selected=3), PngWritten('overview.key1-j.png'))),
            Pressed(NavKey.K, Outcome.NOTHING, Capture(screen(CARDS, selected=3), None)),
            Pressed(NavKey.PG_DN, Outcome.BUSY, Capture(screen(PLAIN), None)),
            Pressed(NavKey.K, Outcome.CLOSED, None),
        )
        report = key_steps_report(Outcome.QUIET, start, pressed)
        start_entry = one(report['start'])
        self.assertEqual(start_entry['outcome'], 'quiet')
        self.assertEqual(start_entry['png'], 'overview.key0.png')
        keys = each(report['keys'])
        self.assertEqual([entry['key'] for entry in keys], ['j', 'k', 'PgDn', 'k'])
        self.assertEqual([entry['outcome'] for entry in keys], ['quiet', 'nothing', 'busy', 'closed'])
        j, k, page, closed = keys
        self.assertEqual((j['changed_rows'], j['text_changed_rows']), ([2, 3], []))
        self.assertEqual((j['kind_changed'], j['card_rows_changed'], j['png']), (False, False, 'overview.key1-j.png'))
        self.assertEqual((k['changed_rows'], k['kind_changed'], k['png']), ([], False, None))
        self.assertEqual((page['kind_changed'], page['card_rows_changed']), (True, True))
        page_layout = one(page['layout'])
        self.assertEqual((page_layout['kind'], page_layout['card_rows'], page_layout['edges']), ('plain', [], []))
        self.assertEqual(closed, {'key': 'k', 'outcome': 'closed'})
        self.assertEqual(report['kinds'], ['cards', 'cards', 'cards', 'plain'])
        self.assertIs(report['kind_stable'], False)

    def test_kinds_stay_stable_while_only_the_selection_moves(self) -> None:
        start = Capture(screen(CARDS, selected=2), None)
        pressed = tuple(Pressed(key, Outcome.QUIET, Capture(screen(CARDS, selected=row), None))
                        for key, row in ((NavKey.J, 3), (NavKey.J, 5), (NavKey.K, 3)))
        report = key_steps_report(Outcome.QUIET, start, pressed)
        self.assertEqual(report['kinds'], ['cards'] * 4)
        self.assertIs(report['kind_stable'], True)

    def test_a_terminal_closed_before_the_first_key_reports_no_kinds(self) -> None:
        self.assertEqual(key_steps_report(Outcome.CLOSED, None, ()),
                         {'start': {'outcome': 'closed'}, 'keys': [], 'kinds': [], 'kind_stable': None})


if __name__ == '__main__':
    unittest.main()
