"""image/probe.sh keeps a probed program's value apart from its log.

fetch_masc.sh compares `masc build-commit` to the commit the release was built
from. masc writes an MCP startup line to stderr on every run, so while the probe
captured `2>&1` the comparison read that line together with the commit and never
matched: every downloaded release was refused with

    linux-x64 embeds build commit '[...] [INFO] [MCP] Tag registry initialized:
    176 tools registered\ne499b80...', expected e499b80...

and dist/ stayed at whatever it last held. The strings below are from that run
on 2026-09-22, not invented: a fixture that merely resembled the log would pass
while the real one still broke the comparison.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import unittest
from pathlib import Path

PROBE = Path(__file__).resolve().parents[1] / 'image' / 'probe.sh'
BASH = shutil.which('bash') or '/bin/bash'

COMMIT = 'e499b80d59cb2bf37d443bad2ecda434c7645d4c'
MCP_LOG = ('[2026-09-22 11:25:48] [INFO] [MCP] Tag registry initialized: '
           '176 tools registered')


def run(script: str, **env: str) -> subprocess.CompletedProcess:
    # The environment, the way a caller overrides the bound on the command line.
    return subprocess.run(
        [BASH, '-c', f'set -euo pipefail; . "{PROBE}"; {script}'],
        capture_output=True, text=True, env={**os.environ, **env})


@unittest.skipUnless(shutil.which('timeout'), 'run_bounded calls timeout')
class FetchProbeTest(unittest.TestCase):
    def test_a_probes_value_is_its_stdout_alone(self):
        # The regression: with 2>&1 this carried the log line as well.
        r = run(f'run_bounded bash -c \'echo "{MCP_LOG}" >&2; echo {COMMIT}\'; '
                'printf "%s" "$PROBE_OUTPUT"')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, COMMIT)

    def test_a_logged_probe_still_equals_the_commit_it_printed(self):
        # What fetch_masc.sh actually asks. It failed for every release.
        r = run(f'run_bounded bash -c \'echo "{MCP_LOG}" >&2; echo {COMMIT}\'; '
                f'[[ "$PROBE_OUTPUT" == "{COMMIT}" ]] && echo match')
        self.assertEqual(r.stdout.strip(), 'match', r.stderr)

    def test_the_log_is_kept_not_discarded(self):
        r = run(f'run_bounded bash -c \'echo "{MCP_LOG}" >&2; echo {COMMIT}\'; '
                'printf "%s" "$PROBE_STDERR"')
        self.assertEqual(r.stdout, MCP_LOG)

    def test_a_failure_message_carries_both_streams(self):
        # Docker speaks on stderr; the probed CLI can speak on either.
        r = run('run_bounded bash -c \'echo out; echo err >&2; exit 3\'; '
                'echo "status=$PROBE_STATUS"; probe_diagnostic')
        self.assertIn('status=3', r.stdout)
        self.assertIn('out', r.stdout)
        self.assertIn('err', r.stdout)

    def test_a_diagnostic_of_one_stream_carries_no_blank_line(self):
        r = run('run_bounded bash -c \'echo err >&2; exit 1\'; probe_diagnostic')
        self.assertEqual(r.stdout, 'err')

    def test_a_probe_status_survives_a_failure_under_set_e(self):
        r = run('run_bounded false; echo "status=$PROBE_STATUS"; echo alive')
        self.assertIn('alive', r.stdout)
        self.assertIn('status=1', r.stdout)

    def test_a_timeout_is_named_as_one(self):
        r = run('run_bounded sleep 5; probe_timed_out && echo timed-out',
                PROBE_TIMEOUT_SEC='1')
        self.assertEqual(r.stdout.strip(), 'timed-out', r.stderr)

    def test_an_exit_status_is_not_mistaken_for_a_timeout(self):
        r = run('run_bounded false; probe_timed_out && echo timed-out || echo no')
        self.assertEqual(r.stdout.strip(), 'no')

    def test_probe_init_points_the_capture_at_a_given_path(self):
        # fetch_masc.sh puts the file in STAGE_DIR so its EXIT trap covers it.
        r = run('d="$(mktemp -d)"; probe_init "$d/.probe-stderr"; '
                'run_bounded bash -c \'echo noise >&2\'; '
                'cat "$d/.probe-stderr"; rm -rf "$d"')
        self.assertEqual(r.stdout.strip(), 'noise', r.stderr)

    def test_sourcing_probe_runs_nothing(self):
        # Sourcing must not start a probe, or this test would need Docker.
        r = run('echo sourced')
        self.assertEqual(r.stdout.strip(), 'sourced', r.stderr)


if __name__ == '__main__':
    unittest.main()
