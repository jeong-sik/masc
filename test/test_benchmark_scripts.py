"""benchmarks/quick-bench.sh and benchmark.sh call only tools that exist, and only where told to.

Both scripts called `masc_agents`, a tool no registry has any more, so the first
read lane ended the run before it produced a number. Both also defaulted to the
production port (8935) while writing a real broadcast and sending a real chat
completion to every endpoint through `masc_runtime_verify`.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = (ROOT / 'benchmarks' / 'quick-bench.sh', ROOT / 'benchmarks' / 'benchmark.sh')
TOOL_DEFINITIONS = ROOT / 'config' / 'tools'
BASH = shutil.which('bash') or '/bin/bash'
# A tool name as the scripts spell it: a quoted masc_ identifier.
TOOL_NAME = re.compile(r'"(masc_[a-z0-9_]+)"')


class BenchmarkScripts(unittest.TestCase):
    def test_a_script_given_no_url_stops_before_it_touches_a_server(self):
        with tempfile.TemporaryDirectory() as scratch:
            bin_dir = Path(scratch) / 'bin'
            bin_dir.mkdir()
            curl_calls = Path(scratch) / 'curl-calls'
            # Stands in for curl. A script that gets past the URL check lands here and
            # the test fails, so a regression sends nothing to the real server.
            stand_in = bin_dir / 'curl'
            stand_in.write_text(f'#!/bin/sh\necho "$@" >> "{curl_calls}"\nexit 7\n')
            stand_in.chmod(0o755)
            env = {name: value for name, value in os.environ.items() if not name.startswith('MASC_')}
            env['PATH'] = os.pathsep.join([str(bin_dir), os.environ['PATH']])
            for script in SCRIPTS:
                with self.subTest(script=script.name):
                    curl_calls.unlink(missing_ok=True)
                    done = subprocess.run([BASH, str(script)], env=env, capture_output=True,
                                          text=True, timeout=60)
                    self.assertFalse(curl_calls.exists(),
                                     f'{script.name} called curl without MASC_URL: '
                                     f'{curl_calls.read_text() if curl_calls.exists() else ""}')
                    self.assertNotEqual(done.returncode, 0)
                    self.assertIn('MASC_URL', done.stderr)
                    self.assertIn('9400', done.stderr)

    def test_every_tool_a_script_calls_has_a_definition(self):
        registered = {path.stem for path in TOOL_DEFINITIONS.glob('masc_*.toml')}
        self.assertTrue(registered, 'config/tools has no masc_ definitions; the lookup is broken')
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                called = set(TOOL_NAME.findall(script.read_text()))
                self.assertTrue(called, f'{script.name} names no tool; the pattern is broken')
                self.assertEqual(sorted(called - registered), [])


if __name__ == '__main__':
    unittest.main()
