"""Real PTY coverage for Skill totals, bounded cards and retained readings."""
import base64
import hashlib
import json
import os
import re
from pathlib import Path
import sys
import threading
import unicodedata

import tui_keyboard_chat as _keyboard_chat
import tui_keyboard_harness as _keyboard_harness
import tui_keyboard_tools as _keyboard_tools

SOURCE_MODULES = (
    'bin/masc_tui_render_tools.ml',
    'bin/masc_tui_tool_table.ml',
    'bin/masc_tui_render.ml',
    'lib/tui_decode_skill_evidence.ml',
    'lib/tui_decode_skill_evidence.mli',
    'lib/tui_decode_tools.ml',
    'lib/tui_decode_tools.mli',
    'lib/tui_decode_fields.ml',
    'lib/tui_decode_fields.mli',
    'test/tui_keyboard_chat.py',
    'test/tui_keyboard_harness.py',
    'test/tui_keyboard_observer.py',
    'test/tui_keyboard_tools.py',
)
LONG_NAME = 'long-skill-' + 'x' * 100 + '-tail'


def width(text):
    return sum(0 if unicodedata.combining(c) or unicodedata.category(c).startswith('C')
               else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in text)


def run(binary, columns, mode):
    partial = mode == 'partial'
    fixtures = _keyboard_tools.skills_usage_clarity_http_fixtures(
        ledgers_loaded=1 if partial else 19,
        unavailable=('bravo: metadata unavailable',) if partial else ())
    good = fixtures['/api/v1/skills']
    surfaces = good[1]['surfaces']
    surfaces[1]['reference']['identity']['name'] = LONG_NAME
    surfaces[1]['usage'] = [
        {'keeper': 'alpha', 'invocations': 4, 'deliveries': 3, 'actions': 2,
         'last_used_at': '2026-08-28T03:04:05Z'},
        {'keeper': 'beta', 'invocations': 3, 'deliveries': 2, 'actions': 1,
         'last_used_at': '2026-08-28T03:04:05Z'},
    ]
    failed = threading.Event()
    if mode == 'initial-error':
        failed.set()
    fixtures['/api/v1/skills'] = lambda: (
        (503, {'error': 'fixture catalog unavailable'}) if failed.is_set() else good)

    def interact(process, fd, _slave, output, _base):
        _keyboard_harness.resize_and_wait(process, fd, output, rows=48, columns=columns, needle=b'MASC Dashboard')
        # At 68 and 80 columns the System pane drops its "MASC System" title
        # so its sub-tabs fit (config_pane_title_head), so the walk reads the
        # strip's selected token instead.
        _keyboard_harness.tab_until(process, fd, output, b'\xe2\x96\xb8System')
        _keyboard_harness.send_and_wait(process, fd, output, b't', b'MASC System / Tools')
        _keyboard_harness.send_and_wait(process, fd, output, b'p' * 3,
                        b'skills catalog load failed:' if mode == 'initial-error'
                        else b'2 of 2 catalog Skills observed')
        if mode == 'stale':
            failed.set()
            _keyboard_harness.send_and_wait(process, fd, output, b'r', b'Previous catalog reading retained')
        _keyboard_harness.drain_until_quiet(process, fd, output)
        end = output.rfind(_keyboard_harness.FRAME_END) + len(_keyboard_harness.FRAME_END)
        raw = bytes(output[:end])
        rows = _keyboard_harness.screen_rows(raw)
        screen = '\n'.join(row.decode('utf-8') for _, row in sorted(rows.items()))
        if mode == 'initial-error':
            assert 'unavailable (no catalog reading)' in screen, screen
            assert 'TRIGGERED 0' not in screen and 'Keepers 0' not in screen, screen
        else:
            for label in ('Keepers 2', 'TRIGGERED 19', 'DELIVERED 17', 'ACTIONS 12',
                          'work-intake', 'alpha', 'beta',
                          'TRIGGERED 12', 'TRIGGERED 7'):
                assert label in screen, (label, screen)
            # The long name wraps inside its card, and where the break falls
            # depends on the width (at 120 columns it lands after the last
            # hyphen), so read the card rows joined rather than one row.
            joined = ''.join(row.decode('utf-8').strip().strip('│').strip()
                             for _, row in sorted(rows.items()))
            assert LONG_NAME in joined, (LONG_NAME, screen)
            assert screen.count('┌') >= 3 and screen.count('└') >= 3, screen
            for row in rows.values():
                text = row.decode('utf-8')
                if '┌' in text or '└' in text or 'TRIGGERED' in text:
                    assert width(text) <= columns, (columns, width(text), text)
                if '┌' in text:
                    assert '┐' in text, text
                if '└' in text:
                    assert '┘' in text, text
            # Each named Skill must have its own complete card, not merely
            # borrow the summary's opening and closing borders.
            ordered = [row.decode('utf-8') for _, row in sorted(rows.items())]
            bounds = []
            for name in ('work-intake', 'long-skill-'):
                index = next(i for i, row in enumerate(ordered) if name in row)
                top = max(i for i in range(index) if '┌' in ordered[i])
                bottom = next(i for i in range(index + 1, len(ordered)) if '└' in ordered[i])
                assert '┐' in ordered[top] and '┘' in ordered[bottom], ordered[top:bottom + 1]
                assert not any('┌' in row for row in ordered[index + 1:bottom]), ordered[top:bottom + 1]
                bounds.append((top, bottom))
            assert bounds[0][1] < bounds[1][0], bounds
            if columns == 68:
                card_text = '\n'.join(ordered[bounds[0][0]:bounds[1][1] + 1])
                compact = _keyboard_chat.unwrapped(card_text.encode()).decode()
                for label in ('alpha TRIGGERED 12 · DELIVERED 12 · ACTIONS 9',
                              'alpha TRIGGERED 4 · DELIVERED 3 · ACTIONS 2',
                              'beta TRIGGERED 3 · DELIVERED 2 · ACTIONS 1'):
                    assert label in compact, (label, compact)
                assert not re.search(r'(alpha|beta)\s+\d+\s+\d+\s+\d+', compact), compact
                assert 'KEEPER' not in compact, compact
            if partial:
                assert 'Partial totals: unavailable ledgers are excluded.' in screen, screen
                assert 'unavailable: 1' in screen, screen
            if mode == 'stale':
                assert 'Previous catalog reading retained' in screen, screen
                assert 'skills catalog load failed:' in screen, screen
        # Complete PTY stream through a finished frame: CI logs can reconstruct
        # every inherited row instead of displaying a hand-made screenshot.
        print('SKILLS_USAGE_SUMMARY_PTY_EVIDENCE ' + json.dumps({
            'mode': mode, 'rows': 48, 'columns': columns,
            'binary_sha256': hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
            'encoding': 'base64', 'pty_size_bytes': len(raw),
            'pty_sha256': hashlib.sha256(raw).hexdigest(),
            'pty': base64.b64encode(raw).decode(),
        }), flush=True)
        os.write(fd, b'q')

    _keyboard_harness.run_terminal_scenario(binary, description=f'Skill summary {columns} columns {mode}',
                            interact=interact, http_fixtures=fixtures)


if __name__ == '__main__':
    executable = os.path.abspath(sys.argv[1])
    for columns, mode in ((68, 'ready'), (80, 'ready'), (120, 'ready'), (80, 'partial'),
                          (120, 'stale'), (80, 'initial-error')):
        run(executable, columns, mode)
    print('Skill usage summary: PASS (6 real PTY scenarios)')
