# pyright: strict
"""The screens idle.py measures, the keys that reach each, and the
allow-list those keys are checked against.

Every screen starts in a fresh TUI. A step jumps to a `Destination` with the
command palette and then presses its `Move`s. Two facts of the TUI shape the
types:

- The palette runs whichever entry ranks first for the typed text, and some
  entries act: `gate ...` sets the approval gate, `language: ...` stores a
  preference, `keeper ...` opens a chat (bin/masc_tui_palette.ml). So a jump
  names a `Destination`, whose value is one whole `go ...` entry. Typed
  whole, that entry is the only one that ranks as the whole query.
- One key means different things on different screens. `p` switches Usage
  to Telemetry, but on the Keeper list it pauses the Keeper under the cursor.
  Enter opens a row on most lists, but on the Keeper detail's Services tab it
  starts a login. So `MOVES` allows a move only from the screens it lists,
  and each entry names the screen the move leads to.

`plan` turns a step into keys only when every move is in `MOVES`, so a step
that leaves the table never reaches a terminal.

Opening a row uses Right, not Enter. Both open a row in the dispatcher's
shared arm (bin/masc_tui.ml), but two arms before it take Enter: on the
Keeper list it opens the Story window (bin/masc_tui_keeper_story.ml), and on
the Services tab it starts a login.
"""
from collections.abc import Mapping
from dataclasses import dataclass
import enum
from types import MappingProxyType
from typing import assert_never

from pty_driver import Jump, Key, Press


class Destination(enum.Enum):
    """A `go` entry of the command palette, spelled whole: `main_entries`,
    `palette_entries` and `config_panes` of bin/masc_tui_palette.ml and
    bin/masc_tui_types.ml."""
    OPERATIONS = 'go Operations'
    USAGE = 'go Operations / Usage'
    WORK = 'go Work'
    REQUESTS = 'go Work / Requests'
    BOARD = 'go Work / Board'
    TASK_REVIEW = 'go Work / Task Review'
    TASK_VERDICTS = 'go Work / Task Verdicts'
    KEEPERS = 'go Keepers'
    MEMORY = 'go Keepers / Memory'
    SCHEDULES = 'go Keepers / Schedules'
    FUSION = 'go Keepers / Fusion'
    CHANGES = 'go Keepers / Changes'
    FEATURES = 'go Features & plugins'
    TOOLS = 'go Features & plugins / Tools & Skills'
    RESOURCES = 'go Features & plugins / Resources'
    CLIENTS = 'go Features & plugins / Clients'
    CHANNELS = 'go Features & plugins / Channels'
    WORKSPACE = 'go Workspace'
    CODE = 'go Workspace / Code'
    SYSTEM = 'go System'
    MODELS = 'go System / models'
    RUNTIME = 'go System / Runtime'
    ACTIVITY = 'go System / Activity'
    LOGS = 'go System / Logs'


class Reached(enum.Enum):
    """A screen that a move opens over or inside a destination."""
    HELP = 'the help sheet of the screen'
    HELP_EVERYWHERE = 'the help sheet of every screen'
    PALETTE = 'the command palette'
    USAGE_TELEMETRY = 'Usage on Telemetry'
    WORK_TASKS = 'Work on Tasks'
    KEEPER_DETAIL = 'a Keeper detail'
    BOARD_POST = 'a Board post'
    REQUEST_DETAIL = 'a request detail'


type Place = Destination | Reached


class Move(enum.Enum):
    """A single key a step may press. Each one only moves, opens or reads on
    the screens `MOVES` allows it from."""
    HELP = '?'
    PALETTE = ':'
    NEXT_VIEW = 'v'
    TELEMETRY = 'p'
    TASKS = 't'
    OPEN = 'Right'
    NEXT_TAB = ']'
    PREVIOUS_TAB = '['


def move_bytes(move: Move) -> bytes:
    """The bytes a terminal sends for the key; bin/masc_tui_csi.ml decodes
    ESC [ C as `right`."""
    match move:
        case Move.HELP:
            return b'?'
        case Move.PALETTE:
            return b':'
        case Move.NEXT_VIEW:
            return b'v'
        case Move.TELEMETRY:
            return b'p'
        case Move.TASKS:
            return b't'
        case Move.OPEN:
            return b'\x1b[C'
        case Move.NEXT_TAB:
            return b']'
        case Move.PREVIOUS_TAB:
            return b'['
        case _:
            assert_never(move)


# The allow-list: (where the TUI is, the move) -> where the move leads. A pair
# that is not here is refused. Bindings are rows of bin/masc_tui_keys.ml.
MOVES: Mapping[tuple[Place, Move], Place] = MappingProxyType({
    # `global`: `?` draws this screen's keys, and on the sheet `?` widens it
    # to every screen (bin/masc_tui_help.ml `step`).
    (Destination.OPERATIONS, Move.HELP): Reached.HELP,
    (Reached.HELP, Move.HELP): Reached.HELP_EVERYWHERE,
    # `global`: `:` opens the palette; nothing runs until Enter.
    (Destination.OPERATIONS, Move.PALETTE): Reached.PALETTE,
    # `metrics_bindings`, both Navigate: v walks Plan, Trend, Keepers and
    # Calls; p switches between Usage and Telemetry.
    (Destination.USAGE, Move.NEXT_VIEW): Destination.USAGE,
    (Destination.USAGE, Move.TELEMETRY): Reached.USAGE_TELEMETRY,
    # Work's Navigate t: Goals / Tasks.
    (Destination.WORK, Move.TASKS): Reached.WORK_TASKS,
    # Right opens the row under the cursor (bin/masc_tui.ml, the arm of
    # "\r" | "\n" | "right"): the Keeper detail on its Info tab, the Board post,
    # the request's detail.
    (Destination.KEEPERS, Move.OPEN): Reached.KEEPER_DETAIL,
    (Destination.BOARD, Move.OPEN): Reached.BOARD_POST,
    (Destination.REQUESTS, Move.OPEN): Reached.REQUEST_DETAIL,
    # `keeper_detail_tab_hint` "[ ]:tab": the next or previous detail tab,
    # which reads its own data on entry.
    (Reached.KEEPER_DETAIL, Move.NEXT_TAB): Reached.KEEPER_DETAIL,
    (Reached.KEEPER_DETAIL, Move.PREVIOUS_TAB): Reached.KEEPER_DETAIL,
})


@dataclass(frozen=True, slots=True)
class Step:
    name: str
    start: Destination
    moves: tuple[Move, ...] = ()


@dataclass(frozen=True, slots=True)
class Planned:
    """A step whose every move the allow-list holds, with the keys that
    reach its screen."""
    name: str
    keys: tuple[Key, ...]


@dataclass(frozen=True, slots=True)
class Refused:
    step: str
    at: Place
    move: Move

    def why(self) -> str:
        return f'{self.step}: {self.move.value} is not allowed on {self.at.value}'


def route(step: Step) -> tuple[Place, ...] | Refused:
    """The screens the step passes through, from where its jump lands."""
    places: list[Place] = [step.start]
    for move in step.moves:
        following = MOVES.get((places[-1], move))
        if following is None:
            return Refused(step.name, places[-1], move)
        places.append(following)
    return tuple(places)


def plan(step: Step) -> Planned | Refused:
    passed = route(step)
    if isinstance(passed, Refused):
        return passed
    return Planned(step.name, (Jump(step.start.value),) + tuple(Press(move_bytes(move)) for move in step.moves))


# The Keeper detail's tabs in the order [ and ] walk them: keeper_detail_tabs
# of bin/masc_tui_types.ml, named by their tab labels. A fresh TUI opens the
# detail on Info.
KEEPER_TABS = ('info', 'items', 'sandbox', 'settings', 'secrets', 'github', 'services', 'channels',
               'automation', 'runs', 'terminal')


def keeper_tab_moves(index: int) -> tuple[Move, ...]:
    """The shorter way round from Info to the tab at `index`; ] and [ both wrap."""
    back = len(KEEPER_TABS) - index
    return (Move.NEXT_TAB,) * index if index <= back else (Move.PREVIOUS_TAB,) * back


# One row per screen. Every screen runs in a fresh TUI, so its jump starts
# from the screen the TUI opens on.
STEPS: tuple[Step, ...] = (
    Step('overview', Destination.OPERATIONS),
    Step('usage_plan', Destination.USAGE),
    # Usage opens on Plan; v walks Plan, Trend, Keepers, Calls.
    Step('usage_calls', Destination.USAGE, (Move.NEXT_VIEW,) * 3),
    Step('usage_telemetry', Destination.USAGE, (Move.TELEMETRY,)),
    Step('work_goals', Destination.WORK),
    Step('work_tasks', Destination.WORK, (Move.TASKS,)),
    Step('work_requests', Destination.REQUESTS),
    Step('work_board', Destination.BOARD),
    # The Keeper list opens on the view tui-keepers.toml stores, so a number of
    # `v` presses reaches a different view in each workspace.
    Step('keepers', Destination.KEEPERS),
    # The Lanes surface, which opens on its overview (lanes_mode).
    Step('features', Destination.FEATURES),
    Step('features_tools', Destination.TOOLS),
    Step('workspace', Destination.WORKSPACE),
    # Config opens on its runtime.toml pane (config_pane), so this is also
    # the runtime.toml screen.
    Step('system', Destination.SYSTEM),
    Step('help', Destination.OPERATIONS, (Move.HELP,)),
    Step('help_everywhere', Destination.OPERATIONS, (Move.HELP, Move.HELP)),
    Step('palette', Destination.OPERATIONS, (Move.PALETTE,)),
    Step('work_request_detail', Destination.REQUESTS, (Move.OPEN,)),
    Step('work_board_post', Destination.BOARD, (Move.OPEN,)),
    Step('work_task_review', Destination.TASK_REVIEW),
    Step('work_task_verdicts', Destination.TASK_VERDICTS),
    *(Step(f'keeper_{tab}', Destination.KEEPERS, (Move.OPEN, *keeper_tab_moves(index)))
      for index, tab in enumerate(KEEPER_TABS)),
    Step('keepers_memory', Destination.MEMORY),
    Step('keepers_schedules', Destination.SCHEDULES),
    Step('keepers_fusion', Destination.FUSION),
    Step('keepers_changes', Destination.CHANGES),
    Step('features_resources', Destination.RESOURCES),
    Step('features_clients', Destination.CLIENTS),
    Step('features_channels', Destination.CHANNELS),
    Step('workspace_code', Destination.CODE),
    Step('system_models', Destination.MODELS),
    # The Runtime surface, which opens on its Lanes reading (runtime_mode).
    Step('system_runtime', Destination.RUNTIME),
    Step('system_activity', Destination.ACTIVITY),
    Step('system_logs', Destination.LOGS),
)
STEP_NAMES: Mapping[str, Step] = MappingProxyType({step.name: step for step in STEPS})
