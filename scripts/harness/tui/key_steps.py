# pyright: strict
"""Navigation keys pressed after a screen's idle window, each captured once
the screen is quiet.

Only the keys in `NavKey` can be pressed: j, k, PgUp, PgDn, Home, End and
Tab, which move. Keys that act on some screens, such as p, w, s, x, g and U,
are not among them, and neither is Esc. Each key is sent as the bytes a
terminal sends for it, which bin/masc_tui_csi.ml names `pageup`, `pagedown`,
`home` and `end`.

Before the first key the screen must go quiet, and that screen is the start
capture. After each key the TUI has KEY_DRAW_WAIT_S to draw. Once it draws,
the capture waits for KEY_QUIET_S of silence, up to KEY_SETTLE_LIMIT_S. Each
key reports the rows that changed against the capture before it and the
layout after it (screen_layout.py).
"""
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
import enum
from pathlib import Path
import time
from typing import assert_never

from pty_driver import POLL_S, Child, read_chunk, send, take
from screen_layout import Screen, changed_rows, layout_of, snapshot, text_changed_rows
from vte import Vte, render_png

KEY_DRAW_WAIT_S = 1.0  # a key that draws nothing in this time drew nothing
KEY_QUIET_S = 0.5  # silence that counts as a settled screen
KEY_SETTLE_LIMIT_S = 5.0


class NavKey(enum.Enum):
    J = 'j'
    K = 'k'
    PG_UP = 'PgUp'
    PG_DN = 'PgDn'
    HOME = 'Home'
    END = 'End'
    TAB = 'Tab'


KEYS_BY_NAME: Mapping[str, NavKey] = {key.value: key for key in NavKey}


def key_bytes(key: NavKey) -> bytes:
    match key:
        case NavKey.J:
            return b'j'
        case NavKey.K:
            return b'k'
        case NavKey.PG_UP:
            return b'\x1b[5~'
        case NavKey.PG_DN:
            return b'\x1b[6~'
        case NavKey.HOME:
            return b'\x1b[H'
        case NavKey.END:
            return b'\x1b[F'
        case NavKey.TAB:
            return b'\t'
        case _:
            assert_never(key)


def parse_keys(text: str) -> tuple[NavKey, ...] | str:
    """Comma-separated key names, or why they cannot be pressed."""
    names = [name.strip() for name in text.split(',') if name.strip()]
    unknown = [name for name in names if name not in KEYS_BY_NAME]
    if unknown:
        return (f'unknown key {", ".join(unknown)}; only navigation keys are pressed: '
                f'{", ".join(KEYS_BY_NAME)}')
    return tuple(KEYS_BY_NAME[name] for name in names)


@dataclass(frozen=True, slots=True)
class PngWritten:
    name: str


@dataclass(frozen=True, slots=True)
class PngFailed:
    why: str


type Png = PngWritten | PngFailed | None


def png_report(png: Png) -> object:
    match png:
        case PngWritten(name):
            return name
        case PngFailed(why):
            return {'error': why}
        case None:
            return None


class Outcome(enum.Enum):
    QUIET = 'quiet'  # drew, then KEY_QUIET_S passed without output
    NOTHING = 'nothing'  # drew nothing within KEY_DRAW_WAIT_S
    BUSY = 'busy'  # still drawing at KEY_SETTLE_LIMIT_S; the capture may be mid-frame
    CLOSED = 'closed'  # the terminal closed


@dataclass(frozen=True, slots=True)
class Capture:
    screen: Screen
    png: Png


@dataclass(frozen=True, slots=True)
class Pressed:
    key: NavKey
    outcome: Outcome
    capture: Capture | None  # None once the terminal closed


@dataclass(frozen=True, slots=True)
class KeySteps:
    start_outcome: Outcome
    start: Capture | None  # None when the terminal closed before the first key
    pressed: tuple[Pressed, ...]

    @property
    def closed(self) -> bool:
        return self.start_outcome is Outcome.CLOSED or any(step.outcome is Outcome.CLOSED for step in self.pressed)

    def report(self) -> dict[str, object]:
        return key_steps_report(self.start_outcome, self.start, self.pressed)


def key_steps_report(start_outcome: Outcome, start: Capture | None,
                     pressed: Sequence[Pressed]) -> dict[str, object]:
    """Per key: what it did, the rows that changed against the capture before
    it, and the layout after it. `kinds` lists the start's kind and each
    captured key's, in order."""
    if start is None:
        no_kinds: list[str] = []
        return {'start': {'outcome': start_outcome.value}, 'keys': no_kinds, 'kinds': no_kinds,
                'kind_stable': None}
    previous, previous_layout = start, layout_of(start.screen)
    report: dict[str, object] = {'start': {'outcome': start_outcome.value, 'png': png_report(start.png),
                                           'layout': previous_layout.report()}}
    kinds = [previous_layout.kind]
    keys: list[dict[str, object]] = []
    for step in pressed:
        entry: dict[str, object] = {'key': step.key.value, 'outcome': step.outcome.value}
        if step.capture is not None:
            layout = layout_of(step.capture.screen)
            entry |= {'png': png_report(step.capture.png),
                      'changed_rows': list(changed_rows(previous.screen, step.capture.screen)),
                      'text_changed_rows': list(text_changed_rows(previous.screen, step.capture.screen)),
                      'layout': layout.report(),
                      'kind_changed': layout.kind is not previous_layout.kind,
                      'card_rows_changed': layout.card_rows != previous_layout.card_rows}
            kinds.append(layout.kind)
            previous, previous_layout = step.capture, layout
        keys.append(entry)
    return report | {'keys': keys, 'kinds': [kind.value for kind in kinds], 'kind_stable': len(set(kinds)) == 1}


def quiet(child: Child, vte: Vte) -> Outcome:
    """Read until KEY_QUIET_S pass without output."""
    start = last = time.monotonic()
    while True:
        now = time.monotonic()
        if now - last >= KEY_QUIET_S:
            return Outcome.QUIET
        if now - start >= KEY_SETTLE_LIMIT_S:
            return Outcome.BUSY
        chunk = read_chunk(child, POLL_S)
        if chunk is None:
            return Outcome.CLOSED
        if chunk:
            if not take(child, vte, chunk):
                return Outcome.CLOSED
            last = time.monotonic()


def press_key(child: Child, vte: Vte, key: NavKey) -> Outcome:
    """A terminal that closed before the key, or while it draws, is CLOSED,
    whether the write or the read finds it."""
    if not send(child, key_bytes(key)):
        return Outcome.CLOSED
    first = read_chunk(child, KEY_DRAW_WAIT_S)
    if first is None:
        return Outcome.CLOSED
    if not first:
        return Outcome.NOTHING
    if not take(child, vte, first):
        return Outcome.CLOSED
    return quiet(child, vte)


def capture(vte: Vte, png_path: Path, fonts: Sequence[Path]) -> Capture:
    if not fonts:
        return Capture(snapshot(vte), None)
    failed = render_png(vte, png_path, fonts)
    return Capture(snapshot(vte), PngWritten(png_path.name) if failed is None else PngFailed(failed))


def run_keys(child: Child, vte: Vte, keys: Sequence[NavKey], out: Path, name: str,
             fonts: Sequence[Path]) -> KeySteps:
    """Press `keys` in order. With `fonts`, each capture is drawn to
    <name>.key<N>-<key>.png in `out`, the start to <name>.key0.png. A closed
    terminal ends the sequence."""
    start_outcome = quiet(child, vte)
    if start_outcome is Outcome.CLOSED:
        return KeySteps(start_outcome, None, ())
    start = capture(vte, out / f'{name}.key0.png', fonts)
    pressed: list[Pressed] = []
    for number, key in enumerate(keys, 1):
        outcome = press_key(child, vte, key)
        if outcome is Outcome.CLOSED:
            pressed.append(Pressed(key, outcome, None))
            break
        pressed.append(Pressed(key, outcome, capture(vte, out / f'{name}.key{number}-{key.value}.png', fonts)))
    return KeySteps(start_outcome, start, tuple(pressed))
