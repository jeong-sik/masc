"""Run the real harness preflight in an isolated root, without a server/model."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LivePlan(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='masc-quality-plan-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        files = [
            'scripts/harness_tool_call_quality.sh',
            'scripts/harness/jsonrpc_sse.sh',
            'scripts/harness/lib/test_framework.sh',
            'scripts/harness/lib/server_bootstrap.sh',
            'scripts/harness/lib/mcp_call.sh',
            'scripts/harness/lib/mcp_jsonrpc.sh',
            'benchmarks/data/tool_call_quality_cases.json',
        ] + [f'config/prompts/harness.tool_quality.{name}.txt'
             for name in ('analyst', 'executor', 'verifier')]
        for name in files:
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        self.marker = self.root / 'unexpected-effect'
        for name in ('run-local.sh', 'dune-local.sh'):
            script = self.root / 'scripts' / name
            script.write_text('#!/bin/sh\ntouch "$EFFECT_MARKER"\nexit 91\n')
            script.chmod(0o755)
        self.catalog = self.root / 'benchmarks/data/tool_call_quality_cases.json'
        self.out = self.root / 'output'

    def run_plan(self, *args, live=False):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith('TOOL_CALL_QUALITY_')}
        env['EFFECT_MARKER'] = str(self.marker)
        mode = ['--live', '--models', 'fixture:model', '--port', '1'] if live else ['--check-live-plan']
        result = subprocess.run(
            ['bash', str(self.root / 'scripts/harness_tool_call_quality.sh'),
             '--artifact-dir', str(self.out), *mode, *args],
            env=env, text=True, capture_output=True, check=False)
        self.assertFalse(self.marker.exists(), result.stderr)
        self.assertEqual(list(self.out.glob('live-*')), [], result.stderr)
        return result

    def test_default_plan_covers_catalog(self):
        result = self.run_plan()
        self.assertEqual(result.returncode, 0, result.stderr)
        plan = [json.loads(row) for row in result.stdout.splitlines()]
        catalog = json.loads(self.catalog.read_text())['cases']
        self.assertEqual(plan, [{'case_id': c['id'], 'keeper_profiles': c['keeper_profiles']}
                                for c in catalog])

    def test_profile_filter_does_not_admit_other_profiles(self):
        result = self.run_plan('--keepers', 'bench-analyst')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([json.loads(row) for row in result.stdout.splitlines()], [
            {'case_id': 'read_search_prompt_fingerprint', 'keeper_profiles': ['bench-analyst']},
            {'case_id': 'text_only_triage', 'keeper_profiles': ['bench-analyst']},
        ])

    def test_case_and_profile_intersection(self):
        result = self.run_plan('--keepers', 'bench-executor', '--case-ids', 'multi_step_board_update')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            'case_id': 'multi_step_board_update', 'keeper_profiles': ['bench-executor']})

    def test_unknown_requested_profile_fails_before_live_setup(self):
        result = self.run_plan('--keepers', 'bench-delta', live=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unknown benchmark keeper profile: bench-delta', result.stderr)

    def test_unknown_catalog_profile_cannot_be_silently_filtered(self):
        catalog = json.loads(self.catalog.read_text())
        catalog['cases'][0]['keeper_profiles'] = ['unknown-profile']
        self.catalog.write_text(json.dumps(catalog))
        result = self.run_plan('--keepers', 'bench-verifier', live=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('unknown benchmark keeper profile: unknown-profile', result.stderr)

    def test_missing_prompt_fails_before_live_setup(self):
        (self.root / 'config/prompts/harness.tool_quality.analyst.txt').unlink()
        result = self.run_plan(live=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('missing required harness prompt asset:', result.stderr)

    def test_no_matching_case_fails_before_live_setup(self):
        result = self.run_plan('--case-ids', 'unknown-case', live=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no benchmark cases match', result.stderr)

    def test_invalid_catalog_cannot_be_hidden_by_process_substitution(self):
        self.catalog.write_text('{')
        result = self.run_plan(live=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('parse error', result.stderr)


if __name__ == '__main__':
    unittest.main()
