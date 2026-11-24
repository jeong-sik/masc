#!/usr/bin/env python3
"""Pin the release-freeze wiring in the workflow YAML (#54645, task-4046).

The worker and the sweep only see `MASC_RELEASE_FREEZE` when the workflow step
passes the repository variable into the step's `env:`. The script's fallback
read needs a Variables permission the workflow token does not have, so a
missing line here silently turns the freeze into a no-op — exactly the hole
that produced #54644's P1. Parse the two workflow files as text (no YAML
dependency) and assert the name and the source of the value.
"""
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
VARIABLE = 'MASC_RELEASE_FREEZE'
WIRING = [('.github/workflows/approval-auto-merge.yml',
           'run: python3 scripts/review/approval-auto-merge.py'),
          ('.github/workflows/approval-merge-sweep.yml',
           'run: python3 scripts/review/approval-merge-sweep.py')]


def step_env(text, run_line):
    """The `env:` keys of the step whose command starts with `run_line`."""
    lines = text.splitlines()
    starts = [index for index, line in enumerate(lines)
              if line.strip().startswith(run_line)]
    if len(starts) != 1:
        return None
    start = starts[0]
    run_indent = len(lines[start]) - len(lines[start].lstrip())
    keys = []
    for line in reversed(lines[:start]):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        indent = len(line) - len(line.lstrip())
        if indent < run_indent:
            break
        if line.strip() == 'env:':
            return keys
        if indent > run_indent and ':' in line:
            keys.append(line.strip().split(':', 1)[0])
    return None


class ReleaseFreezeWiringTest(unittest.TestCase):

    def test_each_workflow_step_passes_the_repository_variable(self):
        for path, run_line in WIRING:
            with self.subTest(workflow=path):
                text = (ROOT / path).read_text(encoding='utf-8')
                self.assertIn(f'{VARIABLE}: ${{{{ vars.{VARIABLE} }}}}', text,
                              f'{path} no longer passes {VARIABLE} from vars')
                keys = step_env(text, run_line)
                self.assertIsNotNone(keys, f'{path} has no env: above "{run_line}"')
                self.assertIn(VARIABLE, keys,
                              f'{path}: {VARIABLE} is not in the env of the step '
                              f'that runs the script')

    def test_the_value_comes_from_the_vars_context_not_a_literal(self):
        for path, _ in WIRING:
            with self.subTest(workflow=path):
                text = (ROOT / path).read_text(encoding='utf-8')
                for line in text.splitlines():
                    if line.strip().startswith(f'{VARIABLE}:'):
                        self.assertIn(f'vars.{VARIABLE}', line,
                                      f'{path}: {VARIABLE} is not read from vars')


if __name__ == '__main__':
    unittest.main()
