# pyright: strict
"""The screen table of idle.py: every step stays inside the allow-list of
read-only moves, and names are unique.

    python3 -m unittest scripts.tests.test_tui_screen_steps

No TUI, relay or MASC server runs here.
"""
from collections import Counter
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'harness' / 'tui'))
from pty_driver import Jump, Press  # noqa: E402
from screen_steps import (KEEPER_TABS, MOVES, STEP_NAMES, STEPS, Destination, Move, Planned, Reached,  # noqa: E402
                          Refused, Step, move_bytes, plan, route)

# Keys that act somewhere in the TUI: Enter runs a palette entry, sends a
# chat and starts a Services login; y answers; a lone Esc leaves a Keeper
# chat. No move may send them.
NEVER = frozenset({b'\r', b'\n', b'y', b'\x1b'})
# What the Keeper list and detail do with these: pause, wake, shut down,
# delete, toggle the gate, unbind all channels (bin/masc_tui_keys.ml
# keeper_actions, keeper_detail_tab_bindings), and toggle a Services provider.
KEEPER_ACTS = frozenset({b'p', b'w', b's', b'x', b'g', b'U', b't', b'T'})
KEEPER_PLACES = frozenset({Destination.KEEPERS, Reached.KEEPER_DETAIL})


def planned(step: Step) -> Planned:
    match plan(step):
        case Planned() as result:
            return result
        case Refused() as refused:
            raise AssertionError(refused.why())


class AllowListTest(unittest.TestCase):
    def test_every_step_stays_inside_the_allow_list(self) -> None:
        for step in STEPS:
            with self.subTest(step.name):
                self.assertNotIsInstance(route(step), Refused)

    def test_every_key_is_a_whole_go_entry_then_allowed_moves(self) -> None:
        moves_by_bytes = {move_bytes(move): move for move in Move}
        for step in STEPS:
            with self.subTest(step.name):
                jump, *presses = planned(step).keys
                assert isinstance(jump, Jump)
                self.assertIn(jump.entry, {destination.value for destination in Destination})
                pressed: list[Move] = []
                for key in presses:
                    assert isinstance(key, Press)
                    pressed.append(moves_by_bytes[key.key])
                self.assertEqual(tuple(pressed), step.moves)

    def test_a_jump_names_only_go_entries(self) -> None:
        # Palette entries that act start otherwise: gate, language:, keeper,
        # task, usage account.
        for destination in Destination:
            with self.subTest(destination.name):
                self.assertTrue(destination.value.startswith('go '))

    def test_moves_send_distinct_bytes_and_none_that_act(self) -> None:
        sent = [move_bytes(move) for move in Move]
        self.assertEqual(len(set(sent)), len(sent))
        self.assertFalse(NEVER & set(sent))

    def test_no_move_from_a_keeper_screen_sends_a_keeper_action(self) -> None:
        for (place, move) in MOVES:
            if place in KEEPER_PLACES:
                with self.subTest(place=place.name, move=move.name):
                    self.assertNotIn(move_bytes(move), KEEPER_ACTS)

    def test_a_move_off_its_screen_is_refused(self) -> None:
        # p pauses on the Keeper list; Right on Usage and ? on Work are not in
        # the table; a tab key needs an open detail.
        for step, at, move in (
            (Step('pause', Destination.KEEPERS, (Move.TELEMETRY,)), Destination.KEEPERS, Move.TELEMETRY),
            (Step('open', Destination.USAGE, (Move.OPEN,)), Destination.USAGE, Move.OPEN),
            (Step('help', Destination.WORK, (Move.HELP,)), Destination.WORK, Move.HELP),
            (Step('tab', Destination.KEEPERS, (Move.NEXT_TAB,)), Destination.KEEPERS, Move.NEXT_TAB),
            (Step('wide', Destination.OPERATIONS, (Move.HELP, Move.HELP, Move.HELP)), Reached.HELP_EVERYWHERE,
             Move.HELP),
        ):
            with self.subTest(step.name):
                self.assertEqual(plan(step), Refused(step.name, at, move))


class TableTest(unittest.TestCase):
    def test_step_names_are_unique(self) -> None:
        repeated = [name for name, count in Counter(step.name for step in STEPS).items() if count > 1]
        self.assertEqual(repeated, [])
        self.assertEqual(len(STEP_NAMES), len(STEPS))

    def test_each_keeper_tab_step_lands_on_its_tab(self) -> None:
        for index, tab in enumerate(KEEPER_TABS):
            step = STEP_NAMES[f'keeper_{tab}']
            with self.subTest(tab):
                passed = route(step)
                assert isinstance(passed, tuple)
                self.assertIs(passed[-1], Reached.KEEPER_DETAIL)
                first, *walk = step.moves
                self.assertIs(first, Move.OPEN)
                net = sum(1 if move is Move.NEXT_TAB else -1 for move in walk)
                self.assertEqual(net % len(KEEPER_TABS), index)
                self.assertLessEqual(len(walk), len(KEEPER_TABS) // 2)

    def test_the_existing_screens_keep_their_keys(self) -> None:
        # Runs before this table compare by screen name, so these rows keep
        # the palette entry and the bytes they had.
        expected = {
            'overview': (':go Operations',),
            'usage_calls': (':go Operations / Usage', 'v', 'v', 'v'),
            'usage_telemetry': (':go Operations / Usage', 'p'),
            'work_tasks': (':go Work', 't'),
            'features_tools': (':go Features & plugins / Tools & Skills',),
            'system': (':go System',),
        }
        for name, keys in expected.items():
            with self.subTest(name):
                spelled = tuple(f':{key.entry}' if isinstance(key, Jump) else key.key.decode()
                                for key in planned(STEP_NAMES[name]).keys)
                self.assertEqual(spelled, keys)


if __name__ == '__main__':
    unittest.main()
