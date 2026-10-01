"""Offline adversarial checks of the real audit CLIs using retained evidence.

Temporary mutations are fixture data. They are never published measurements.
"""
import copy
import gzip
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

SOURCE_MODULES = (
    "docs/evidence/2026-09-30-candle-grade-explicit-outcome/audit-candidate.py",
    "docs/evidence/2026-09-30-candle-grade-explicit-outcome/compare-evaluations.py",
    "docs/evidence/2026-09-30-candle-grade-scope-survey/audit-provenance.py",
)
ROOT = Path(__file__).resolve().parents[1]
CANDIDATE = ROOT/'docs/evidence/2026-09-30-candle-grade-explicit-outcome'
SURVEY = ROOT/'docs/evidence/2026-09-30-candle-grade-scope-survey'


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False))


def write_rows(path, rows):
    path.write_text(''.join(json.dumps(row, ensure_ascii=False)+'\n' for row in rows))


def rewrite_fixture_registry(bundle, rows):
    """Build internally consistent synthetic receipts, never measured evidence."""
    events = []
    for row in rows:
        receipt = row['receipt']
        references = {}
        for side, payload in [('input', receipt['input']['payload']), ('output', receipt['output'])]:
            raw = json.dumps(payload, ensure_ascii=False, separators=(',', ':')).encode()
            digest = hashlib.sha256(raw).hexdigest()
            path = bundle/'exact-lane-run-payloads'/receipt['run_id']/f'{side}-{digest}.json'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
            references[side] = {'kind':'file', 'bytes':len(raw), 'sha256':digest}
        events.append({'event':'register', 'id':receipt['run_id'], 'started_at':receipt['started_at'],
                       'registration':{'lane':receipt['lane'], 'actor':receipt['actor'], 'input':references['input']}})
        completion = {'outcome':receipt['status'], 'selected_slot':receipt['selected_slot'],
                      'elapsed_s':receipt['elapsed_s'], 'output':references['output']}
        if receipt['status'] == 'failed':
            completion.update(code=receipt['code'], detail=receipt['detail'])
        events.append({'event':'complete', 'id':receipt['run_id'], 'completion':completion})
    write_rows(bundle/'exact-lane-runs-v6.jsonl', events)


def hydrate(source, target):
    shutil.copytree(source, target)
    for compressed in target.glob('*.jsonl.gz'):
        compressed.with_suffix('').write_bytes(gzip.decompress(compressed.read_bytes()))
    for archive in target.glob('*.tar.gz'):
        with tarfile.open(archive) as bundle:
            bundle.extractall(target, filter='data')
    runtime = target/'.masc/config/runtime.toml'
    runtime.parent.mkdir(parents=True)
    runtime.write_bytes((SURVEY/'runtime.toml').read_bytes())


class CandleEvidenceAudits(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='candle-audit-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_audit(self, script, *args, error=None):
        result = subprocess.run([sys.executable, '-O', str(script), *map(str, args)],
                                capture_output=True, text=True, timeout=30)
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '', 'refused evidence must not emit a successful report')
        self.assertIn(error, result.stderr)

    def test_candidate_binary_is_bound_to_independent_artifact_record(self):
        bundle = self.root/'candidate'
        hydrate(CANDIDATE, bundle)
        script = CANDIDATE/'audit-candidate.py'
        result = self.run_audit(script, bundle, bundle)
        metadata = json.loads((bundle/'metadata.json').read_text())
        self.assertEqual(result['executable_sha256'], metadata['build']['executable_sha256'])
        metadata['build']['executable_sha256'] = '0'*64
        write_json(bundle/'metadata.json', metadata)
        self.run_audit(script, bundle, bundle, error='executable hash disagrees')

    def test_comparison_binds_each_plan_to_frozen_and_effective_prompt(self):
        candidate = self.root/'candidate'
        baseline = self.root/'baseline'
        hydrate(CANDIDATE, candidate)
        shutil.copytree(candidate, baseline)
        prompt_file = baseline/'prompts/candle_appraiser_grade.md'
        frozen = prompt_file.read_text() + '\nFixture baseline template.\n'
        prompt_file.write_text(frozen)
        body = frozen.split('\n---\n', 1)[1]
        plan = json.loads((baseline/'plan.json').read_text())
        plan['prompt_sha256']['candle_appraiser_grade.md'] = hashlib.sha256(prompt_file.read_bytes()).hexdigest()
        write_json(baseline/'plan.json', plan)
        metadata = json.loads((baseline/'metadata.json').read_text())
        metadata['plan'] = plan
        write_json(baseline/'metadata.json', metadata)
        rows = [json.loads(line) for line in (baseline/'results.jsonl').read_text().splitlines()]
        # Separate temporary IDs and prompt declaration describe this synthetic
        # comparison fixture only, not independent measured executions.
        for row in rows:
            row['receipt']['run_id'] = 'fixture-baseline-' + row['receipt']['run_id']
            if row['stage'] == 'grade':
                payload = row['receipt']['input']['payload']
                payload['prompt']['effective_template'] = body
                encoded = json.dumps(payload['actual_input'], ensure_ascii=False, separators=(',', ':'))
                payload['prompt']['rendered'] = body.replace('{{appraisal_input}}', encoded)
        write_rows(baseline/'results.jsonl', rows)
        rewrite_fixture_registry(baseline, rows)
        # Public comparison requires no private runtime file. Model the original
        # baseline's explicit sibling resource layout without inferred fallback.
        shutil.rmtree(baseline/'.masc')
        shutil.rmtree(candidate/'.masc')
        resources = self.root/'baseline-resources'
        resources.mkdir()
        shutil.move(str(baseline/'prompts'), resources/'prompts')
        prompt_file = resources/'prompts/candle_appraiser_grade.md'
        shutil.move(str(baseline/'artifact-verification.json'), resources/'artifact-verification.json')
        source_path = candidate/'prompt-source.json'
        prompt_source = json.loads(source_path.read_text())
        prompt_source['baseline_prompt_sha256'] = plan['prompt_sha256']
        write_json(source_path, prompt_source)
        script = CANDIDATE/'compare-evaluations.py'
        valid = self.run_audit(script, baseline, candidate, '--baseline-resources', resources)
        self.assertEqual(valid['changed_prompt_files'], ['candle_appraiser_grade.md'])
        events = [json.loads(line) for line in (baseline/'exact-lane-runs-v6.jsonl').read_text().splitlines()]
        registration = events[0]
        reference = registration['registration']['input']
        payload_path = baseline/'exact-lane-run-payloads'/registration['id']/f"input-{reference['sha256']}.json"
        original_payload = payload_path.read_bytes()
        payload_path.write_bytes(b'x'*len(original_payload))
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources, error="sha(payload_bytes) == reference['sha256']")
        payload_path.write_bytes(original_payload)
        answer_rows = copy.deepcopy(rows)
        grade = next(row for row in answer_rows if row['stage'] == 'grade' and row['status'] == 'ok')
        grade['answer']['grade'] = 'fixture-unreported-answer'
        write_rows(baseline/'results.jsonl', answer_rows)
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources, error='successful answer mismatch')
        shared_rows = copy.deepcopy(rows)
        for row in shared_rows:
            row['receipt']['run_id'] = row['receipt']['run_id'].removeprefix('fixture-baseline-')
        write_rows(baseline/'results.jsonl', shared_rows)
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources, error='registry run ID is absent')
        rewrite_fixture_registry(baseline, shared_rows)
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources, error='reuse run IDs')
        rewrite_fixture_registry(baseline, rows)
        write_rows(baseline/'results.jsonl', rows)
        prompt_source['baseline_prompt_sha256'] = json.loads((candidate/'plan.json').read_text())['prompt_sha256']
        write_json(source_path, prompt_source)
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources, error='baseline prompt hashes disagree')
        prompt_source['baseline_prompt_sha256'] = plan['prompt_sha256']
        write_json(source_path, prompt_source)
        for directory in (baseline, candidate):
            metadata = json.loads((directory/'metadata.json').read_text())
            metadata['build']['executable_sha256'] = '0'*64
            write_json(directory/'metadata.json', metadata)
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources, error='executable hash disagrees')
        for directory in (baseline, candidate):
            metadata = json.loads((directory/'metadata.json').read_text())
            metadata['build']['executable_sha256'] = next(entry['sha256'] for entry in json.loads(((resources if directory == baseline else directory)/'artifact-verification.json').read_text())['files'] if entry['file'] == 'candle_appraiser_eval_cli.exe')
            write_json(directory/'metadata.json', metadata)
        changed_rows = copy.deepcopy(rows)
        payload = changed_rows[0]['receipt']['input']['payload']
        payload['actual_input']['goal']['title'] = 'Different unmeasured goal'
        encoded = json.dumps(payload['actual_input'], ensure_ascii=False, separators=(',', ':'))
        payload['prompt']['rendered'] = payload['prompt']['effective_template'].replace('{{appraisal_input}}', encoded)
        write_rows(baseline/'results.jsonl', changed_rows)
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources, error='actual input disagrees with frozen case')
        shutil.copyfile(candidate/'results.jsonl', baseline/'results.jsonl')
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources, error='effective template disagrees')
        write_rows(baseline/'results.jsonl', rows)
        prompt_file.write_text(frozen + 'tampered')
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources, error='frozen prompt hash mismatch')

    def test_candidate_raw_corpus_count_and_identity(self):
        bundle = self.root/'candidate'
        hydrate(CANDIDATE, bundle)
        script = CANDIDATE/'audit-candidate.py'
        original_plan = json.loads((bundle/'plan.json').read_text())
        original_cases = json.loads((bundle/'cases.json').read_text())
        for duplicate in (False, True):
            with self.subTest(duplicate=duplicate):
                plan = copy.deepcopy(original_plan)
                cases = copy.deepcopy(original_cases)
                if duplicate:
                    cases.append(copy.deepcopy(cases[0]))
                    write_json(bundle/'cases.json', cases)
                    plan['cases_sha256'] = hashlib.sha256((bundle/'cases.json').read_bytes()).hexdigest()
                    plan['case_count'] = len(cases)
                else:
                    plan['case_count'] = 999
                write_json(bundle/'plan.json', plan)
                metadata = json.loads((bundle/'metadata.json').read_text())
                metadata['plan'] = plan
                write_json(bundle/'metadata.json', metadata)
                expected = 'duplicate case IDs' if duplicate else 'raw corpus count disagrees'
                self.run_audit(script, bundle, bundle, error=expected)

    def test_survey_binary_hash_matches_frozen_provenance(self):
        bundle = self.root/'survey'
        hydrate(SURVEY, bundle)
        script = SURVEY/'audit-provenance.py'
        self.run_audit(script, bundle, bundle)
        metadata = json.loads((bundle/'metadata.json').read_text())
        metadata['build']['executable_sha256'] = '0'*64
        write_json(bundle/'metadata.json', metadata)
        self.run_audit(script, bundle, bundle, error='executable hash disagrees with frozen provenance')

    def test_candidate_registry_failure_fields_match_receipt(self):
        bundle = self.root/'candidate'
        hydrate(CANDIDATE, bundle)
        script = CANDIDATE/'audit-candidate.py'
        self.run_audit(script, bundle, bundle)
        rows = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
        failed_ids = {row['receipt']['run_id'] for row in rows if row['status'] != 'ok'}
        self.assertTrue(failed_ids, 'retained candidate has an actual transport failure')
        original = [json.loads(line) for line in (bundle/'exact-lane-runs-v6.jsonl').read_text().splitlines()]
        for field in ('code', 'detail'):
            with self.subTest(field=field):
                events = copy.deepcopy(original)
                event = next(event for event in events if event['id'] in failed_ids and event['event'] == 'complete')
                event['completion'][field] = 'fixture-contradiction'
                write_rows(bundle/'exact-lane-runs-v6.jsonl', events)
                self.run_audit(script, bundle, bundle, error='registry failure code or detail disagrees')

    def test_survey_closed_failures_match_receipt_code_detail_and_result(self):
        bundle = self.root/'survey'
        hydrate(SURVEY, bundle)
        script = SURVEY/'audit-provenance.py'
        valid = self.run_audit(script, bundle, bundle)
        self.assertEqual(valid['complete_pairs'], 400)
        original = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
        for status, code, detail, output, expected in [
            ('banana', 'candle_appraisal_rejected', 'failure', {'error':'failure'}, 'unknown result status'),
            ('invalid_response', 'wrong_code', 'failure', {'error':'failure'}, 'classification mismatch'),
            ('invalid_response', 'candle_appraisal_rejected', 'different', {'error':'failure'}, 'failed answer mismatch'),
            ('transport_unavailable', 'candle_appraisal_unavailable', 'failure', {'error':'wrong'}, 'failed answer mismatch'),
        ]:
            with self.subTest(status=status, code=code, detail=detail, output=output):
                rows = copy.deepcopy(original)
                row = rows[0]
                row['status'], row['answer'] = status, 'failure'
                row['receipt'].update(status='failed', code=code, detail=detail)
                row['receipt']['output']['result'] = output
                write_rows(bundle/'results.jsonl', rows)
                # Require the new classification guard, not a later registry
                # mismatch caused by the intentionally changed receipt.
                self.run_audit(script, bundle, bundle, error=expected)


if __name__ == '__main__':
    unittest.main()
