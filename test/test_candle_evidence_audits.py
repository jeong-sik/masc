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
        return {}

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

    def test_survey_binary_is_bound_to_independent_artifact_record(self):
        bundle = self.root/'survey'
        hydrate(SURVEY, bundle)
        script = SURVEY/'audit-provenance.py'
        self.run_audit(script, bundle, bundle)
        metadata = json.loads((bundle/'metadata.json').read_text())
        metadata['build']['executable_sha256'] = '0'*64
        write_json(bundle/'metadata.json', metadata)
        for filename in ('freeze.json', 'frozen-audit.json'):
            record = json.loads((bundle/filename).read_text())
            record['executable_sha256'] = '0'*64
            write_json(bundle/filename, record)
        self.run_audit(script, bundle, bundle, error='executable hash disagrees with CI artifact')
        # Restore the measured hash, then make all bundle-local source
        # declarations agree on a different commit. The CI record still owns
        # the source identity, independently of those declarations.
        artifact = json.loads((bundle/'artifact-verification.json').read_text())
        executable = next(entry for entry in artifact['files']
                          if entry['file'] == 'candle_appraiser_eval_cli.exe')
        plan = json.loads((bundle/'plan.json').read_text())
        plan['source_commit'] = '0'*40
        write_json(bundle/'plan.json', plan)
        metadata['plan'] = plan
        metadata['build'].update(commit='0'*40, binary_commit='0'*40,
                                 executable_sha256=executable['sha256'])
        write_json(bundle/'metadata.json', metadata)
        for filename, source_key in [('freeze.json', 'binary_commit'),
                                     ('frozen-audit.json', 'source_commit')]:
            record = json.loads((bundle/filename).read_text())
            record[source_key] = '0'*40
            record.update(executable_sha256=executable['sha256'],
                          plan_sha256=hashlib.sha256((bundle/'plan.json').read_bytes()).hexdigest())
            write_json(bundle/filename, record)
        self.run_audit(script, bundle, bundle, error='CI artifact source commit mismatch')

    def test_runtime_provider_and_model_match_declared_measurement(self):
        for name, source, script_name in [('candidate', CANDIDATE, 'audit-candidate.py'),
                                           ('survey', SURVEY, 'audit-provenance.py')]:
            with self.subTest(bundle=name):
                bundle = self.root/name
                hydrate(source, bundle)
                runtime_path = bundle/'.masc/config/runtime.toml'
                self.run_audit(source/script_name, bundle, bundle)
                original = runtime_path.read_text()
                for before, after, error in [
                    ('"api-name" = "glm-5.3-flash"', '"api-name" = "another-model"',
                     'prepared API model disagrees with declared runtime'),
                    ('"endpoint" = "https://api.z.ai/api/coding/paas/v4"',
                     '"endpoint" = "https://unrelated.example/v1"',
                     'prepared provider destination disagrees with frozen measurement'),
                    ('"protocol" = "openai-compatible-http"', '"protocol" = "messages-http"',
                     'prepared provider destination disagrees with frozen measurement'),
                    *((('"api-name" = "glm-5.3-flash"',
                         '"api-name" = "glm-5.3-flash"\n' + setting,
                         'prepared model settings disagree with frozen measurement')
                        for setting in ('"temperature" = 0.0', '"top-p" = 0.5',
                                        '"top-k" = 10', '"min-p" = 0.1',
                                        '"reasoning-effort" = "low"',
                                        '"reasoning-uncontrolled" = true'))),
                    ('"thinking-support" = true', '"thinking-support" = false',
                     'prepared model settings disagree with frozen measurement'),
                ]:
                    with self.subTest(field=before):
                        raw = original.replace(before, after)
                        runtime_path.write_text(raw)
                        plan = json.loads((bundle/'plan.json').read_text())
                        plan['runtime_config_sha256'] = hashlib.sha256(raw.encode()).hexdigest()
                        write_json(bundle/'plan.json', plan)
                        metadata = json.loads((bundle/'metadata.json').read_text())
                        metadata['plan'] = plan
                        write_json(bundle/'metadata.json', metadata)
                        if source == SURVEY:
                            for filename in ('freeze.json', 'frozen-audit.json'):
                                record = json.loads((bundle/filename).read_text())
                                record.update(plan_sha256=hashlib.sha256((bundle/'plan.json').read_bytes()).hexdigest(),
                                              runtime_config_sha256=plan['runtime_config_sha256'])
                                write_json(bundle/filename, record)
                        self.run_audit(source/script_name, bundle, bundle, error=error)

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
        candidate_plan = json.loads((candidate/'plan.json').read_text())
        candidate_metadata = json.loads((candidate/'metadata.json').read_text())
        changed_plan = copy.deepcopy(candidate_plan)
        changed_plan['planned_calls'] = float(changed_plan['planned_calls'])
        write_json(candidate/'plan.json', changed_plan)
        changed_metadata = copy.deepcopy(candidate_metadata)
        changed_metadata['plan'] = changed_plan
        write_json(candidate/'metadata.json', changed_metadata)
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources,
                       error='baseline and candidate plans differ outside prompt hashes')
        write_json(candidate/'plan.json', candidate_plan)
        write_json(candidate/'metadata.json', candidate_metadata)
        write_rows(baseline/'results.jsonl', list(reversed(rows)))
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources,
                       error='trial order disagrees with registry')
        rewrite_fixture_registry(baseline, list(reversed(rows)))
        self.run_audit(script, baseline, candidate, '--baseline-resources', resources,
                       error='baseline and candidate trial order differs')
        write_rows(baseline/'results.jsonl', rows)
        rewrite_fixture_registry(baseline, rows)
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

    def test_survey_actor_matches_frozen_fixture(self):
        bundle = self.root/'survey'
        hydrate(SURVEY, bundle)
        script = SURVEY/'audit-provenance.py'
        self.run_audit(script, bundle, bundle)
        rows = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
        for row in rows:
            row['receipt']['actor'] = '/live/production'
        write_rows(bundle/'results.jsonl', rows)
        rewrite_fixture_registry(bundle, rows)
        self.run_audit(script, bundle, bundle,
                       error='receipt actors disagree with frozen container fixture')

    def test_survey_binary_hash_matches_frozen_provenance(self):
        bundle = self.root/'survey'
        hydrate(SURVEY, bundle)
        script = SURVEY/'audit-provenance.py'
        self.run_audit(script, bundle, bundle)
        metadata = json.loads((bundle/'metadata.json').read_text())
        metadata['build']['executable_sha256'] = '0'*64
        write_json(bundle/'metadata.json', metadata)
        self.run_audit(script, bundle, bundle, error='executable hash disagrees with frozen provenance')

    def test_candidate_preserves_json_types_and_output_schema(self):
        bundle = self.root/'candidate'
        hydrate(CANDIDATE, bundle)
        script = CANDIDATE/'audit-candidate.py'
        original = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
        rows = copy.deepcopy(original)
        case_id = next(row['case_id'] for row in rows if row['stage'] == 'weights')
        for row in rows:
            if row['case_id'] == case_id:
                payload = row['receipt']['input']['payload']
                payload['actual_input']['weight_max'] = float(payload['actual_input']['weight_max'])
                encoded = json.dumps(payload['actual_input'], ensure_ascii=False, separators=(',', ':'))
                payload['prompt']['rendered'] = payload['prompt']['effective_template'].replace('{{appraisal_input}}', encoded)
        write_rows(bundle/'results.jsonl', rows)
        rewrite_fixture_registry(bundle, rows)
        self.run_audit(script, bundle, bundle, error='same_json(payload')
        for stage in ('grade', 'relation', 'weights'):
            with self.subTest(stage=stage):
                rows = copy.deepcopy(original)
                row = next(row for row in rows if row['stage'] == stage)
                row['receipt']['input']['payload']['output_schema'] = {'type': 'object'}
                write_rows(bundle/'results.jsonl', rows)
                rewrite_fixture_registry(bundle, rows)
                self.run_audit(script, bundle, bundle, error='output schema disagrees')

    def test_survey_joins_all_frozen_input_declarations(self):
        bundle = self.root/'survey'
        hydrate(SURVEY, bundle)
        script = SURVEY/'audit-provenance.py'
        for filename in ('freeze.json', 'frozen-audit.json'):
            original = json.loads((bundle/filename).read_text())
            for field in ('cases_sha256', 'runtime_config_sha256', 'prompt_sha256',
                          'case_count', 'trials_each', 'planned_calls', 'runtime_id'):
                with self.subTest(filename=filename, field=field):
                    modified = copy.deepcopy(original)
                    modified[field] = 'contradiction'
                    write_json(bundle/filename, modified)
                    self.run_audit(script, bundle, bundle, error=f'frozen {field} disagrees')
            write_json(bundle/filename, original)

    def test_survey_raw_case_count_and_duplicate_identity(self):
        bundle = self.root/'survey'
        hydrate(SURVEY, bundle)
        script = SURVEY/'audit-provenance.py'
        cases = json.loads((bundle/'cases.json').read_text())
        cases.append(copy.deepcopy(cases[0]))
        write_json(bundle/'cases.json', cases)
        plan = json.loads((bundle/'plan.json').read_text())
        plan['cases_sha256'] = hashlib.sha256((bundle/'cases.json').read_bytes()).hexdigest()
        for declare_duplicate in (False, True):
            if declare_duplicate:
                plan['case_count'] = len(cases)
            write_json(bundle/'plan.json', plan)
            metadata = json.loads((bundle/'metadata.json').read_text())
            metadata['plan'] = plan
            write_json(bundle/'metadata.json', metadata)
            for filename in ('freeze.json', 'frozen-audit.json'):
                record = json.loads((bundle/filename).read_text())
                record.update(plan_sha256=hashlib.sha256((bundle/'plan.json').read_bytes()).hexdigest(),
                              cases_sha256=plan['cases_sha256'], case_count=plan['case_count'])
                write_json(bundle/filename, record)
            self.run_audit(script, bundle, bundle,
                           error='duplicate case IDs' if declare_duplicate else 'raw corpus count disagrees')

    def test_survey_refuses_nonzero_retained_exit(self):
        bundle = self.root/'survey'
        hydrate(SURVEY, bundle)
        path = bundle/'exit.json'
        outcome = json.loads(path.read_text())
        outcome['exit_code'] = 73
        write_json(path, outcome)
        self.run_audit(SURVEY/'audit-provenance.py', bundle, bundle, error='retained evaluation exit is not zero')

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


    def test_candidate_failed_attempts_match_terminal_receipt(self):
        bundle = self.root/'candidate'
        hydrate(CANDIDATE, bundle)
        original = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
        for mutation, error in [
            ('response', 'response or unsupported'),
            ('missing_terminal', 'terminal failure attempt'),
            ('terminal_detail', 'terminal failure attempt'),
            ('missing_http', 'HTTP failure observation count'),
            ('http_detail', 'HTTP failure detail'),
            ('short_http_detail', 'HTTP failure detail'),
            ('blank_http_detail', 'HTTP failure detail'),
            ('http_slot', 'HTTP failure observations'),
            ('http_classification', 'HTTP failure observations'),
            ('raw_response', 'absent raw response consistently'),
            ('missing_raw_response', 'absent raw response consistently'),
            ('raw_detail', 'absent raw response consistently'),
        ]:
            with self.subTest(mutation=mutation):
                rows = copy.deepcopy(original)
                row = next(row for row in rows if row['status'] == 'transport_unavailable')
                output = row['receipt']['output']
                attempts = output['attempts']
                if mutation in ('raw_response', 'missing_raw_response', 'raw_detail'):
                    observation = next(a for a in attempts if a['kind'] == 'http_failure')
                    if mutation == 'raw_response':
                        observation['raw_response'] = 'contradictory received bytes'
                    elif mutation == 'missing_raw_response':
                        del observation['raw_response']
                    else:
                        observation['detail'] = observation['detail'].replace('raw_response=none', 'raw_response=body')
                        detail = row['receipt']['detail'].replace('raw_response=none', 'raw_response=body')
                        row['answer'] = row['receipt']['detail'] = detail
                        output['result'] = {'error':detail}
                        next(a for a in attempts if a['kind'] == 'failure')['detail'] = detail
                elif mutation == 'response':
                    attempts.append({'kind':'response', 'slot':row['receipt']['selected_slot'],
                                     'output':{'grade':'small'}})
                elif mutation.startswith('missing_'):
                    kind = 'failure' if mutation == 'missing_terminal' else 'http_failure'
                    output['attempts'] = [a for a in attempts if a['kind'] != kind]
                elif mutation == 'terminal_detail':
                    next(a for a in attempts if a['kind'] == 'failure')['detail'] = 'contradiction'
                else:
                    attempt = next(a for a in attempts if a['kind'] == 'http_failure')
                    if mutation == 'http_detail': attempt['detail'] = 'contradiction'
                    elif mutation == 'short_http_detail': attempt['detail'] = 'call_id='
                    elif mutation == 'blank_http_detail': attempt['detail'] = ' '
                    elif mutation == 'http_slot': attempt['slot'] = 'other.model'
                    else: attempt['invalid_output'] = True
                write_rows(bundle/'results.jsonl', rows)
                rewrite_fixture_registry(bundle, rows)
                self.run_audit(CANDIDATE/'audit-candidate.py', bundle, bundle, error=error)

    def test_candidate_rejects_zero_sum_weights(self):
        bundle = self.root/'candidate'
        hydrate(CANDIDATE, bundle)
        rows = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
        row = next(row for row in rows if row['stage'] == 'weights' and row['status'] == 'ok')
        answer = {'weights': dict.fromkeys(row['answer']['weights'], 0)}
        row['answer'] = row['receipt']['output']['result'] = answer
        for attempt in row['receipt']['output']['attempts']:
            if attempt['kind'] == 'response': attempt['output'] = answer
        write_rows(bundle/'results.jsonl', rows)
        rewrite_fixture_registry(bundle, rows)
        self.run_audit(CANDIDATE/'audit-candidate.py', bundle, bundle, error='positive sum')

    def test_candidate_exit_and_runtime_declarations(self):
        bundle = self.root/'candidate'
        hydrate(CANDIDATE, bundle)
        script = CANDIDATE/'audit-candidate.py'
        for exit_code in (73, False):
            write_json(bundle/'exit.json', {'exit_code': exit_code})
            self.run_audit(script, bundle, bundle, error='retained evaluation exit is not zero')
        shutil.copyfile(CANDIDATE/'exit.json', bundle/'exit.json')
        runtime = bundle/'.masc/config/runtime.toml'
        original = runtime.read_text()
        original_plan = json.loads((bundle/'plan.json').read_text())
        for before, after, error in [
            ('"slots" = ["glm-coding.glm-5.3-flash"]', '"slots" = ["other.model"]', 'runtime slots'),
            ('"cli_slots" = []', '"cli_slots" = ["other.model"]', 'runtime slots'),
            ('"max_output_tokens" = 4096', '"max_output_tokens" = 3', 'output limit'),
            ('"max_output_tokens" = 4096', '"max_output_tokens" = 4096.0', 'output limit'),
            ('"exact-body-timeout-s" = 1200.0', '"exact-body-timeout-s" = 1.0', 'timeout'),
            ('"exact-body-timeout-s" = 1200.0', '"exact-body-timeout-s" = 1200', 'timeout'),
            ('"key" = "ZAI_API_KEY_SB"', '"key" = "OTHER_KEY"', 'credential reference'),
        ]:
            with self.subTest(error=error, after=after):
                runtime.write_text(original.replace(before, after))
                plan = copy.deepcopy(original_plan)
                plan['runtime_config_sha256'] = hashlib.sha256(runtime.read_bytes()).hexdigest()
                write_json(bundle/'plan.json', plan)
                metadata = json.loads((bundle/'metadata.json').read_text())
                metadata['plan'] = plan
                write_json(bundle/'metadata.json', metadata)
                self.run_audit(script, bundle, bundle, error=error)

    def test_candidate_validates_answers_responses_and_failed_slot(self):
        bundle = self.root/'candidate'
        hydrate(CANDIDATE, bundle)
        script = CANDIDATE/'audit-candidate.py'
        original = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
        for stage, answer in [('grade', {'grade':'banana'}), ('relation', {'relation':'banana'}),
                              ('weights', {'weights': {}})]:
            with self.subTest(stage=stage):
                rows = copy.deepcopy(original)
                row = next(row for row in rows if row['stage'] == stage and row['status'] == 'ok')
                row['answer'] = row['receipt']['output']['result'] = answer
                for attempt in row['receipt']['output']['attempts']:
                    if attempt['kind'] == 'response':
                        attempt['output'] = answer
                write_rows(bundle/'results.jsonl', rows)
                rewrite_fixture_registry(bundle, rows)
                self.run_audit(script, bundle, bundle, error='answer violates stage schema')
        for missing in (False, True):
            rows = copy.deepcopy(original)
            row = next(row for row in rows if row['stage'] == 'grade' and row['status'] == 'ok')
            attempts = row['receipt']['output']['attempts']
            if missing:
                row['receipt']['output']['attempts'] = [a for a in attempts if a['kind'] != 'response']
            else:
                next(a for a in attempts if a['kind'] == 'response')['output'] = {'grade':'epic'}
            write_rows(bundle/'results.jsonl', rows)
            rewrite_fixture_registry(bundle, rows)
            self.run_audit(script, bundle, bundle, error='attempt trace' if missing else 'response observations disagree')
        rows = copy.deepcopy(original)
        row = next(row for row in rows if row['status'] != 'ok')
        row['receipt']['selected_slot'] = 'other.model'
        write_rows(bundle/'results.jsonl', rows)
        rewrite_fixture_registry(bundle, rows)
        self.run_audit(script, bundle, bundle, error='failed selected slot disagrees')

    def test_survey_failure_completion_and_unverified_prompt_commit(self):
        bundle = self.root/'survey'
        hydrate(SURVEY, bundle)
        script = SURVEY/'audit-provenance.py'
        for filename in ('freeze.json', 'frozen-audit.json'):
            record = json.loads((bundle/filename).read_text())
            record['prompt_commit'] = '0'*40
            write_json(bundle/filename, record)
        result = self.run_audit(script, bundle, bundle)
        self.assertEqual(result['prompt_source_verification'],
                         'retained_bytes_verified_source_commit_unverified')
        self.assertNotIn('prompt_commit', result)
        rows = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
        for status, code in [('invalid_response', 'candle_appraisal_rejected'),
                             ('transport_unavailable', 'candle_appraisal_unavailable')]:
            row = rows[0]
            slot = row['receipt']['selected_slot']
            http_detail = 'call_id=fixture cause=invalid JSON output raw_response=none'
            detail = f'execution_failed: slot={slot} {http_detail}; flow=[slot={slot} call_id=fixture]'
            if status == 'transport_unavailable':
                http_detail = 'call_id=fixture cause=connection closed raw_response=none'
                detail = f'execution_failed: slot={slot} {http_detail}; flow=[slot={slot} call_id=fixture]'
            row.update(status=status, answer=detail)
            row['receipt'].update(status='failed', code=code, detail=detail)
            row['receipt']['output']['result'] = {'error':detail}
            row['receipt']['output']['attempts'] = [
                {'kind':'dispatch', 'slot':slot},
                {'kind':'http_failure', 'slot':slot, 'detail':http_detail,
                 'invalid_output':status == 'invalid_response', 'raw_response':None},
                {'kind':'failure', 'transport':'http', 'detail':detail},
            ]
            write_rows(bundle/'results.jsonl', rows)
            rewrite_fixture_registry(bundle, rows)
            self.run_audit(script, bundle, bundle)
            row['receipt']['output']['attempts'].append(
                {'kind':'response', 'slot':slot, 'output':{'grade':'small'}})
            write_rows(bundle/'results.jsonl', rows)
            rewrite_fixture_registry(bundle, rows)
            self.run_audit(script, bundle, bundle, error='response or unsupported')
            row['receipt']['output']['attempts'].pop()
            write_rows(bundle/'results.jsonl', rows)
            rewrite_fixture_registry(bundle, rows)
            original = [json.loads(line) for line in (bundle/'exact-lane-runs-v6.jsonl').read_text().splitlines()]
            for field in ('code', 'detail'):
                with self.subTest(status=status, field=field):
                    events = copy.deepcopy(original)
                    events[1]['completion'][field] = 'contradiction'
                    write_rows(bundle/'exact-lane-runs-v6.jsonl', events)
                    self.run_audit(script, bundle, bundle, error='registry failure code or detail disagrees')

    def test_successful_receipts_reject_contradictory_or_reordered_attempts(self):
        for source, script_name in [(CANDIDATE, 'audit-candidate.py'), (SURVEY, 'audit-provenance.py')]:
            bundle = self.root/source.name
            hydrate(source, bundle)
            original = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
            for kind in ('failure', 'http_failure', 'rejected', 'reordered'):
                with self.subTest(bundle=source.name, kind=kind):
                    rows = copy.deepcopy(original)
                    row = next(row for row in rows if row['status'] == 'ok')
                    attempts = row['receipt']['output']['attempts']
                    if kind == 'reordered':
                        attempts.reverse()
                    else:
                        attempts.append({'kind':kind})
                    write_rows(bundle/'results.jsonl', rows)
                    rewrite_fixture_registry(bundle, rows)
                    self.run_audit(source/script_name, bundle, bundle, error='attempt trace')

    def test_unbound_template_variable_is_rejected_before_certifying_receipts(self):
        for source, script_name in [(CANDIDATE, 'audit-candidate.py'), (SURVEY, 'audit-provenance.py')]:
            bundle = self.root/source.name
            hydrate(source, bundle)
            prompt_file = bundle/'prompts/candle_appraiser_grade.md'
            prompt_file.write_text(prompt_file.read_text() + '\n{{ unbound }}\n')
            body = prompt_file.read_text().split('\n---\n', 1)[1]
            plan = json.loads((bundle/'plan.json').read_text())
            plan['prompt_sha256'][prompt_file.name] = hashlib.sha256(prompt_file.read_bytes()).hexdigest()
            write_json(bundle/'plan.json', plan)
            metadata = json.loads((bundle/'metadata.json').read_text())
            metadata['plan'] = plan
            write_json(bundle/'metadata.json', metadata)
            if source == SURVEY:
                for name in ('freeze.json', 'frozen-audit.json'):
                    record = json.loads((bundle/name).read_text())
                    record.update(prompt_sha256=plan['prompt_sha256'],
                                  plan_sha256=hashlib.sha256((bundle/'plan.json').read_bytes()).hexdigest())
                    write_json(bundle/name, record)
            rows = [json.loads(line) for line in (bundle/'results.jsonl').read_text().splitlines()]
            for row in rows:
                if row['stage'] == 'grade':
                    payload = row['receipt']['input']['payload']
                    payload['prompt']['effective_template'] = body
                    encoded = json.dumps(payload['actual_input'], ensure_ascii=False, separators=(',', ':'))
                    payload['prompt']['rendered'] = body.replace('{{appraisal_input}}', encoded)
            write_rows(bundle/'results.jsonl', rows)
            rewrite_fixture_registry(bundle, rows)
            self.run_audit(source/script_name, bundle, bundle, error='must bind only appraisal_input')
            if source == CANDIDATE:
                self.run_audit(source/'compare-evaluations.py', bundle, bundle,
                               error='must bind only appraisal_input')


if __name__ == '__main__':
    unittest.main()
