#!/usr/bin/env python3
"""Compare existing TUI artifacts in one runner, retaining every observation.

Uses temporary HTTP/workspace fixtures and never builds or starts a live MASC
server. Completion means the requested PTY frame arrived, not physical display
latency. The 0.1ms objective is reported independently of scenario correctness.

Child stdout/stderr go directly to per-run files. SIGINT/SIGTERM asks the
scenario to unwind its own PTY cleanup. SIGKILL or runner loss can interrupt
cleanup and artifact upload; only output already written to disk is retained.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import statistics
import subprocess
import sys
import time


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def positive_int(value):
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError('must be positive')
    return parsed


def commit(value):
    if len(value) != 40 or any(c not in '0123456789abcdef' for c in value):
        raise argparse.ArgumentTypeError('expected a full lowercase commit SHA')
    return value


def verify(root, *, source_commit, run_id, artifact_id):
    manifest = json.loads((root / 'manifest.json').read_text())
    metadata = json.loads((root / 'artifact.json').read_text())
    expected = {'main_eio.exe', 'masc_tui.exe', 'masc_browser_host.exe'}
    if manifest['commit'] != source_commit or manifest['arch'] != 'macos-arm64':
        raise ValueError('source commit or artifact architecture differs')
    if metadata['id'] != artifact_id or metadata['expired'] is not False:
        raise ValueError('artifact identity or expiry differs')
    source_run = metadata['workflow_run']
    if source_run['id'] != run_id or source_run['head_sha'] != source_commit:
        raise ValueError('artifact is not from the expected source run')
    repository_id = int(os.environ['GITHUB_REPOSITORY_ID'])
    if (source_run['repository_id'] != repository_id
            or source_run['head_repository_id'] != repository_id):
        raise ValueError('artifact source is not this repository')
    name = f"runtime-probe-macos-arm64-{source_commit}-attempt-{manifest['run_attempt']}"
    if metadata['name'] != name or set(manifest['sha256']) != expected:
        raise ValueError('artifact name or binary set differs')
    for filename in sorted(expected):
        path = root / filename
        if path.is_symlink() or digest(path) != manifest['sha256'][filename]:
            raise ValueError(f'binary hash differs: {filename}')
    binary = root / 'masc_tui.exe'
    binary.chmod(binary.stat().st_mode | 0o100)
    return {'manifest': manifest, 'artifact': metadata, 'binary': str(binary)}


def cancel(signum, _frame):
    raise SystemExit(128 + signum)


def run_scenario(scenario, binary, *, root, environment, out, name):
    stdout_path = out / (name + '.stdout.txt')
    stderr_path = out / (name + '.stderr.txt')
    # Open before spawning: a cancelled run still has its output files. -u
    # prevents Python's redirected stdout from retaining observations in RAM.
    with stdout_path.open('wb', buffering=0) as stdout, stderr_path.open('wb', buffering=0) as stderr:
        process = subprocess.Popen(
            [sys.executable, '-u', str(scenario), str(binary)],
            cwd=root, env=environment, stdout=stdout, stderr=stderr,
            start_new_session=True)
        try:
            returncode = process.wait()
        finally:
            if process.poll() is None:
                # The scenario owns a separately grouped TUI. Interrupt the
                # Python owner so run_terminal_scenario's finally can reap it;
                # killing only this process group would miss the TUI group.
                previous = {sig: signal.signal(sig, signal.SIG_IGN)
                            for sig in (signal.SIGINT, signal.SIGTERM)}
                try:
                    stderr.write(b'comparison interrupted; requesting scenario cleanup\n')
                    process.send_signal(signal.SIGINT)
                    try:
                        # Allow the helper's 3s HTTP cleanup and 10s TUI reap.
                        # The runner may force-kill the job before this expires.
                        process.wait(timeout=15.0)
                    except subprocess.TimeoutExpired:
                        stderr.write(b'scenario cleanup did not finish; TUI descendant cleanup is unverified\n')
                        process.kill()
                        try:
                            process.wait(timeout=2.0)
                        except subprocess.TimeoutExpired:
                            stderr.write(b'scenario child did not reap after SIGKILL\n')
                finally:
                    for sig, handler in previous.items():
                        signal.signal(sig, handler)
    return returncode, stdout_path.read_text(encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for role in ('baseline', 'candidate'):
        parser.add_argument('--' + role, type=Path, required=True)
        parser.add_argument('--' + role + '-run', type=positive_int, required=True)
        parser.add_argument('--' + role + '-artifact', type=positive_int, required=True)
        parser.add_argument('--' + role + '-commit', type=commit, required=True)
    parser.add_argument('--repetitions', type=positive_int, default=3)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        parser.error('this experiment requires macOS ARM64')
    if args.baseline_commit == args.candidate_commit:
        parser.error('baseline and candidate must name different source commits')
    root = Path(__file__).resolve().parents[3]
    scenario = root / 'test/test_tui_input_frame_pty.py'
    helper = root / 'test/test_tui_keyboard_input.py'
    scenario_hash, helper_hash = digest(scenario), digest(helper)
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=False)
    identities = {}
    for role in ('baseline', 'candidate'):
        identities[role] = verify(
            getattr(args, role).resolve(strict=True),
            source_commit=getattr(args, role + '_commit'),
            run_id=getattr(args, role + '_run'),
            artifact_id=getattr(args, role + '_artifact'))
        (out / (role + '-identity.json')).write_text(
            json.dumps(identities[role], indent=2) + '\n')
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith('MASC_')}
    receipts = []
    expected_inputs = None
    started_at = datetime.now(timezone.utc).isoformat()
    for repeat in range(args.repetitions):
        order = ('baseline', 'candidate') if repeat % 2 == 0 else ('candidate', 'baseline')
        for role in order:
            identity = identities[role]
            binary = Path(identity['binary'])
            binary_hash = identity['manifest']['sha256']['masc_tui.exe']
            if digest(binary) != binary_hash:
                raise ValueError('binary changed before execution')
            name = f'{repeat + 1:02d}-{role}'
            returncode, stdout = run_scenario(
                scenario, binary, root=root, environment=environment, out=out, name=name)
            if returncode != 0 or 'input and scroll frames: PASS' not in stdout.splitlines():
                raise RuntimeError(f'{name} failed: exit {returncode}; see raw logs')
            observations = [json.loads(line) for line in stdout.splitlines()
                            if line.startswith('{')]
            if len(observations) != 1:
                raise ValueError(f'{name}: expected one observation receipt')
            observation = observations[0]
            if (observation['binary_sha256'] != binary_hash
                    or observation['script_sha256'] != scenario_hash
                    or digest(binary) != binary_hash
                    or digest(scenario) != scenario_hash or digest(helper) != helper_hash):
                raise ValueError(f'{name}: observed identity changed')
            samples = observation['samples']
            inputs = [(sample['action'], sample['input_hex']) for sample in samples]
            if len(inputs) != 10 or len(set(inputs)) != len(inputs):
                raise ValueError(f'{name}: expected ten distinct acknowledged transitions')
            if expected_inputs is None:
                expected_inputs = inputs
            elif inputs != expected_inputs:
                raise ValueError(f'{name}: actions differ between runs')
            for sample in samples:
                value = sample['complete_frame_ms']
                if not math.isfinite(value) or value < 0:
                    raise ValueError(f'{name}: invalid timing observation')
            receipt = {'role': role, 'repetition': repeat + 1, **observation}
            receipts.append(receipt)
            (out / (name + '.json')).write_text(json.dumps(receipt, indent=2) + '\n')
            print(json.dumps(receipt), flush=True)
    rows = []
    for action, _input in expected_inputs:
        row = {'action': action}
        for role in ('baseline', 'candidate'):
            values = [sample['complete_frame_ms'] for receipt in receipts
                      if receipt['role'] == role for sample in receipt['samples']
                      if sample['action'] == action]
            row[role] = {'samples_ms': values, 'median_ms': statistics.median(values),
                         'min_ms': min(values), 'max_ms': max(values)}
        rows.append(row)
    goal_ms = 0.1
    summary = {
        'experiment_commit': os.environ.get('GITHUB_SHA'),
        'run_id': os.environ.get('GITHUB_RUN_ID'),
        'run_attempt': os.environ.get('GITHUB_RUN_ATTEMPT'),
        'started_at': started_at, 'finished_at': datetime.now(timezone.utc).isoformat(),
        'platform': platform.platform(), 'python': sys.version,
        'perf_counter': vars(time.get_clock_info('perf_counter')),
        'scenario_sha256': scenario_hash, 'helper_sha256': helper_hash,
        'identities': identities, 'execution_order': [r['role'] for r in receipts],
        'rows': rows, 'goal_ms': goal_ms,
        'all_candidate_observations_below_goal': all(
            row['candidate']['max_ms'] <= goal_ms for row in rows),
        'scope': 'same runner, temporary fixtures, input to acknowledged PTY frame; '
                 'includes observer and OS scheduling; no physical display or live server proof',
    }
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary), flush=True)
    print('artifact comparison: scenarios passed; inspect goal and timing observations')


if __name__ == '__main__':
    signal.signal(signal.SIGINT, cancel)
    signal.signal(signal.SIGTERM, cancel)
    main()
