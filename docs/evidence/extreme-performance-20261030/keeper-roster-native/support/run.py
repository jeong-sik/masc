"""Prospective runner. This file did not execute the retained v1 matrix."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from qualify import qualify_arm, valid_pins


def write_new(path, value):
    with path.open('x') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    config = json.loads(args.config.read_text())
    args.output.mkdir(parents=True, exist_ok=False)
    runs = args.output / 'runs'
    runs.mkdir()
    records = []
    for population, variant in config['plan']:
        spec = config['variants'][variant]
        if not valid_pins(spec):
            raise ValueError('invalid source/digest pins')
        # Before creating a child, reject changed binaries and probe inputs.
        pins = [(spec['server'], spec['server_sha256']), (spec['tui'], spec['tui_sha256'])]
        runner = Path(config['probe']['runner'])
        pins += [(runner, spec['runner_sha256']),
                 (runner.parent / 'tui_observer.py', spec['observer_sha256']),
                 (runner.parent / 'keeper_scale_trace.py', spec['trace_sha256']),
                 (Path(config['repo']) / 'scripts/fixtures/release-evidence/runtime.toml',
                  spec['runtime_fixture_sha256'])]
        for filename, expected in pins:
            if hashlib.sha256(Path(filename).read_bytes()).hexdigest() != expected:
                raise ValueError('input digest mismatch: ' + filename)
        target = runs / f'owners-{population}-{variant}'
        cmd = [sys.executable, config['probe']['runner'], '--binary', spec['server'],
               '--tui-binary', spec['tui'], '--repo', config['repo'], '--output', str(target),
               '--keepers', str(population), '--messages-per-keeper', '2']
        result = {'population': population, 'variant': variant, 'source_expected': spec['source'],
                  'command': cmd, 'started_unix': time.time(),
                  'loadavg_before': os.getloadavg(), 'cpu_count': os.cpu_count()}
        process = subprocess.run(cmd, capture_output=True, text=True)
        try:
            identity = json.loads((target / 'identity.json').read_text())
        except (OSError, ValueError):
            identity = {}
        result.update(source_actual=identity.get('source'), ended_unix=time.time(),
                      returncode=process.returncode, stdout=process.stdout, stderr=process.stderr,
                      loadavg_after=os.getloadavg())
        write_new(runs / (target.name + '.execution.json'), result)
        qualification = qualify_arm(target, result, spec)
        write_new(runs / (target.name + '.qualification.json'), qualification)
        records.append({'execution': result, 'qualification': qualification})
        # Hard boundary before the next child: unknown cleanup or identity stops the plan.
        if not qualification['next_arm_safe'] or (population == 2 and not qualification['eligible']):
            break
    passed = len(records) == len(config['plan']) and all(r['qualification']['eligible'] for r in records)
    write_new(args.output / 'execution.json', {'config': config, 'records': records, 'passed': passed})
    return 0 if passed else 1


if __name__ == '__main__':
    sys.exit(main())
