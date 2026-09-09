"""Non-mutating synthetic memory evaluation against an explicit Ollama model."""
import argparse
import datetime
import hashlib
import json
import ipaddress
import math
import random
import time
import urllib.request
import urllib.parse
from pathlib import Path


def fixture():
    cases = [
        {'id': 'artifact', 'records': [
            {'id': 'a1', 'keeper': 'writer', 'text': 'I generated report.pdf; it is ready.'},
            {'id': 'a2', 'keeper': 'verifier', 'text': 'Read report.pdf: bytes begin with plain markdown, not PDF. PDF rendering failed.'}],
         'question': 'Does the supplied evidence establish a valid rendered PDF?'},
        {'id': 'revision', 'records': [
            {'id': 'r1', 'keeper': 'analyst', 'text': 'Measurement run M1: 12 seconds.'},
            {'id': 'r2', 'keeper': 'analyst', 'text': 'Correction of M1 after checking the original log: 21 seconds. Retract the 12-second claim.'}],
         'question': 'What is the corrected measurement, preserving attribution?'},
        {'id': 'revision_heldout', 'records': [
            {'id': 'h1', 'keeper': 'researcher', 'text': 'Measurement run M2: 43 milliseconds.'},
            {'id': 'h2', 'keeper': 'researcher', 'text': 'Correction of M2 from the source log: 37 milliseconds. Retract the 43-millisecond claim.'}],
         'question': 'What is the corrected measurement, preserving attribution?'},
        {'id': 'conflict', 'records': [
            {'id': 'c1', 'keeper': 'alpha', 'text': 'Dataset D contains 10 samples. No underlying file supplied.'},
            {'id': 'c2', 'keeper': 'beta', 'text': 'Dataset D contains 15 samples. No underlying file supplied.'}],
         'question': 'Can a single verified sample count be consolidated?'}]
    rng = random.Random(20260910)
    for case in cases:
        rng.shuffle(case['records'])
    rng.shuffle(cases)
    return cases


def score(parsed):
    # Expected answers are private to the scorer, never placed in the prompt/schema.
    expected = {'artifact': ('not_proven', None, None, {'a1', 'a2'}),
                'revision': ('corrected', 21, 'seconds', {'r1', 'r2'}),
                'revision_heldout': ('corrected', 37, 'milliseconds', {'h1', 'h2'}),
                'conflict': ('unresolved_conflict', None, None, {'c1', 'c2'})}
    checks = dict.fromkeys(expected, False)
    if not isinstance(parsed, dict) or set(parsed) != {'decisions'}:
        return checks, False
    rows = parsed['decisions']
    if not isinstance(rows, list):
        return checks, False
    ids = [row.get('id') if isinstance(row, dict) else None for row in rows]
    coverage = (all(isinstance(item, str) for item in ids)
                and len(ids) == len(expected) and set(ids) == set(expected))
    for case_id, (verdict, value, unit, sources) in expected.items():
        matching = [row for row in rows if isinstance(row, dict) and row.get('id') == case_id]
        if len(matching) != 1:
            continue
        row = matching[0]
        if set(row) != {'id', 'verdict', 'value', 'unit', 'source_ids', 'explanation'}:
            continue
        observed = row['value']
        numeric = (type(observed) in (int, float) and math.isfinite(observed))
        observed_sources = row['source_ids']
        checks[case_id] = (row['verdict'] == verdict and row['unit'] == unit
            and ((observed is None) if value is None else (numeric and observed == value))
            and isinstance(observed_sources, list)
            and all(isinstance(item, str) for item in observed_sources)
            and len(observed_sources) == len(sources) and set(observed_sources) == sources
            and isinstance(row['explanation'], str) and bool(row['explanation'].strip()))
    return checks, coverage


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--endpoint', required=True)
    parser.add_argument('--model', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    endpoint = urllib.parse.urlsplit(args.endpoint)
    try:
        local = endpoint.hostname == 'localhost' or ipaddress.ip_address(endpoint.hostname).is_loopback
    except ValueError:
        local = False
    if (endpoint.scheme not in ('http', 'https') or not local or endpoint.username
            or endpoint.password or endpoint.query or endpoint.fragment):
        parser.error('--endpoint must be a local HTTP(S) URL without credentials, query, or fragment')
    schema = {'type': 'object', 'properties': {'decisions': {'type': 'array', 'items': {
        'type': 'object', 'properties': {
            'id': {'type': 'string'},
            'verdict': {'type': 'string', 'enum': ['not_proven', 'corrected', 'unresolved_conflict']},
            'value': {'type': ['number', 'null']}, 'unit': {'type': ['string', 'null']},
            'source_ids': {'type': 'array', 'items': {'type': 'string'}},
            'explanation': {'type': 'string'}},
        'required': ['id', 'verdict', 'value', 'unit', 'source_ids', 'explanation'],
        'additionalProperties': False}}}, 'required': ['decisions'], 'additionalProperties': False}
    payload = {'model': args.model, 'stream': False, 'format': schema, 'messages': [
        {'role': 'system', 'content': 'Evaluate synthetic shared-memory evidence. Do not invent facts or resolve unsupported conflicts by voting. Return exactly one decision per case with every relevant source ID. Verdicts: not_proven, corrected, unresolved_conflict. For corrected measurements return the numerical value and the unit as written in the source; otherwise value and unit must be null. Explanations must preserve provenance. Evidence order does not establish chronology. This is evaluation only; no memory is stored.'},
        {'role': 'user', 'content': json.dumps(fixture(), ensure_ascii=False)}]}
    # A fresh directory prevents overwriting either completed or in-flight evidence.
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / 'request.json').write_text(json.dumps(payload, indent=2))
    started_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    script_sha256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    request_sha256 = hashlib.sha256((args.output / 'request.json').read_bytes()).hexdigest()
    identity = {}
    for resource in ('version', 'tags'):
        try:
            with urllib.request.urlopen(args.endpoint.rstrip('/') + '/api/' + resource) as response:
                raw_identity = response.read()
            (args.output / (resource + '.raw')).write_bytes(raw_identity)
            identity[resource] = json.loads(raw_identity)
        except Exception as exc:
            identity[resource] = {'error': f'{type(exc).__name__}: {exc}'}
    start = time.monotonic()
    result = {}
    checks, coverage = score(None)
    error = None
    try:
        request = urllib.request.Request(args.endpoint.rstrip('/') + '/api/chat',
            data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(request) as response:
            raw = response.read()
        (args.output / 'response.raw').write_bytes(raw)
        result = json.loads(raw)
        (args.output / 'response.json').write_text(json.dumps(result, ensure_ascii=False, indent=2))
        if not isinstance(result, dict):
            raise ValueError('Response must be a JSON object')
        parsed = json.loads(result['message']['content'])
        checks, coverage = score(parsed)
    except Exception as exc:
        error = f'{type(exc).__name__}: {exc}'
    metadata = result if isinstance(result, dict) else {}
    passed = error is None and metadata.get('done') is True and coverage and all(checks.values())
    receipt = {'started_at': started_at, 'script_sha256': script_sha256,
        'request_sha256': request_sha256, 'model_requested': args.model, 'model_reported': metadata.get('model'),
        'wall_seconds': time.monotonic() - start, 'checks': checks,
        'unique_case_coverage': coverage, 'passed': passed, 'error': error,
        'done': metadata.get('done'), 'endpoint': args.endpoint, 'server_identity': identity,
        'explanation_semantics_scored': False,
        'prompt_eval_count': metadata.get('prompt_eval_count'), 'eval_count': metadata.get('eval_count'),
        'runtime_integrated': False, 'synthetic_cases_only': True}
    (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
