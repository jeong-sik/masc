# pyright: strict
"""What a captured screen holds: the rows that differ between two captures,
and the layout kind, read from the cells alone.

A capture keeps every cell, so a key that only moves the selection highlight
still changes rows.

The layout kind is read from box-drawing glyphs, never from words.
bin/masc_tui_card.ml draws a full card's top edge as `╭─ … ─╮` and its bottom
as `╰─ … ─╯`, and a squashed card as the one row `╶─ … ─╴`. A card edge is an
opening glyph followed by `─`, then the matching closing glyph after a `─`,
on one row. A screen with at least one edge is `cards`; one with none is
`plain`. A chat's turn rail draws `╭` and `╶` followed by a space
(bin/masc_tui_message_layout.ml), so it is no edge. A pane frame drawn with
the same rounded corners is one, so compare kinds only on a screen whose
plain layout draws no rounded box.
"""
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
import enum

from vte import Cell, Vte

RULE = '─'

type Row = tuple[Cell, ...]
type Screen = tuple[Row, ...]


def snapshot(vte: Vte) -> Screen:
    return tuple(vte.row_cells(row) for row in range(vte.rows))


def row_text(row: Row) -> str:
    return ''.join(cell.text for cell in row if not cell.wide_tail).rstrip()


def changed_rows(before: Screen, after: Screen) -> tuple[int, ...]:
    """Rows whose cells differ, colours and weights included."""
    return tuple(index for index, (old, new) in enumerate(zip(before, after, strict=True)) if old != new)


def text_changed_rows(before: Screen, after: Screen) -> tuple[int, ...]:
    return tuple(index for index, (old, new) in enumerate(zip(before, after, strict=True))
                 if row_text(old) != row_text(new))


class Shape(enum.Enum):
    TOP = 'top'
    BOTTOM = 'bottom'
    SQUASHED = 'squashed'


# Opening glyph: its closing glyph and the edge they make (bin/masc_tui_card.ml,
# Box.*_round in bin/masc_tui_theme.ml).
EDGE_ENDS: Mapping[str, tuple[str, Shape]] = {
    '╭': ('╮', Shape.TOP),
    '╰': ('╯', Shape.BOTTOM),
    '╶': ('╴', Shape.SQUASHED),
}


@dataclass(frozen=True, slots=True)
class Edge:
    row: int
    start: int  # column of the opening glyph
    end: int  # column of the closing glyph
    shape: Shape

    def report(self) -> dict[str, object]:
        return {'row': self.row, 'from': self.start, 'to': self.end, 'shape': self.shape.value}


def opens_edge(texts: Sequence[str], column: int) -> bool:
    return texts[column] in EDGE_ENDS and column + 1 < len(texts) and texts[column + 1] == RULE


def row_edges(index: int, row: Row) -> list[Edge]:
    """The card edges on one row, left to right. An opening without its
    closing before the next opening is no edge."""
    texts = [cell.text for cell in row]
    edges: list[Edge] = []
    column = 0
    while column < len(texts):
        if not opens_edge(texts, column):
            column += 1
            continue
        closing, shape = EDGE_ENDS[texts[column]]
        end: int | None = None
        for at in range(column + 2, len(texts)):
            if texts[at] == closing and texts[at - 1] == RULE:
                end = at
                break
            if opens_edge(texts, at):
                break
        if end is None:
            column += 1
            continue
        edges.append(Edge(index, column, end, shape))
        column = end + 1
    return edges


class Kind(enum.Enum):
    CARDS = 'cards'
    PLAIN = 'plain'


@dataclass(frozen=True, slots=True)
class Layout:
    edges: tuple[Edge, ...]

    @property
    def kind(self) -> Kind:
        return Kind.CARDS if self.edges else Kind.PLAIN

    @property
    def card_rows(self) -> tuple[int, ...]:
        return tuple(sorted({edge.row for edge in self.edges}))

    def report(self) -> dict[str, object]:
        return {'kind': self.kind.value, 'card_rows': list(self.card_rows),
                'edges': [edge.report() for edge in self.edges]}


def layout_of(screen: Screen) -> Layout:
    return Layout(tuple(edge for index, row in enumerate(screen) for edge in row_edges(index, row)))
