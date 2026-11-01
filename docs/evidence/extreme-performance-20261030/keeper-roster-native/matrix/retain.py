import hashlib
import json
from pathlib import Path
import shutil
import time

repo = Path.cwd()
source = repo / 'artifacts/extreme-perf-20261030'
destination = repo / 'docs/evidence/extreme-performance-20261030/keeper-roster-native'
destination.mkdir(parents=True, exist_ok=False)
selected = []
missing = []


def select(path, address):
    selected.append((source / path, destination / address))


for filename in ['config.json', 'preflight-v1.json', 'analyze-executed-v1.py', 'analyze.py',
                 'analysis-v1.json', 'analysis-v2.json', 'retain.py', 'measured-v1/execution.json']:
    select('keeper-roster-matched-v1/' + filename, 'matrix/' + filename)
for filename in ['run.py', 'qualify.py', 'probe/keeper_scale_session.py',
                 'probe/keeper_scale_trace.py', 'probe/tui_observer.py']:
    select('keeper-list-matched-v2/' + filename, 'support/' + filename)
for filename in ['verified-v1.json', 'run-41041914326-metadata.json', 'run-41041918389-metadata.json',
                 'native/receipt.json', 'native/test-results.tsv', 'native/test-invocations.jsonl',
                 'control-suite/ci-run-tests.log']:
    select('keeper-roster-native-v1/' + filename, 'build/' + filename)
select('keeper-list-frame-native-v1/receipt.json', 'build/control-native-receipt.json')
for filename in ['keeper-roster-prepared-ci-dispatch-v1.json', 'keeper-roster-prepared-ci-status-v2.json']:
    select(filename, 'build/' + filename)
config = json.loads((source / 'keeper-roster-matched-v1/config.json').read_text())
secrets = set()


def collect_tokens(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == 'token' and isinstance(child, str) and child:
                secrets.add(child.encode())
            else:
                collect_tokens(child)
    elif isinstance(value, list):
        for child in value:
            collect_tokens(child)
    elif isinstance(value, str) and value.startswith(('{', '[')):
        try:
            decoded = json.loads(value)
        except ValueError:
            return
        collect_tokens(decoded)


for population, variant in config['plan']:
    name = f'owners-{population}-{variant}'
    prefix = 'keeper-roster-matched-v1/measured-v1/runs/' + name
    select(prefix + '.execution.json', 'matrix/measured-v1/runs/' + name + '.execution.json')
    select(prefix + '.qualification.json', 'matrix/measured-v1/runs/' + name + '.qualification.json')
    directory = source / prefix
    for token_name in ['admin.token', 'dashboard.token', 'masc-tui.token']:
        value = (directory / 'owned-base/.masc/auth' / token_name).read_bytes().strip()
        if not value:
            raise ValueError('Owned credential is empty')
        secrets.add(value)
    for line in (directory / 'requests.jsonl').read_text().splitlines():
        collect_tokens(json.loads(line))
    filenames = ['cleanup.json', 'identity.json', 'owned-process.json', 'operations-admitted.json',
                 'terminal.json', 'durable-operations.json', 'health-model-held.json', 'workload-phases.json',
                 'keeper_scale_session.py', 'keeper_scale_trace.py', 'tui_observer.py',
                 'tui-observer/observation.json', 'tui-observer/frame-timing.txt',
                 'summary.json', 'model-coverage.json', 'model-coverage-before-shutdown.json',
                 'failure.json', 'fallback-cleanup.json', 'operation-observation-failures.jsonl', 'rate-limit-waits.jsonl']
    for filename in filenames:
        if (directory / filename).exists():
            select(prefix + '/' + filename, 'matrix/measured-v1/runs/' + name + '/' + filename)
        else:
            missing.append({'arm': name, 'unselected_absent_file': filename})
if len(secrets) < len(config['plan']):
    raise ValueError('Owned credential scan found fewer values than owned arms')
for path, _ in selected:
    data = path.read_bytes()
    if any(secret in data for secret in secrets):
        raise ValueError('Selected file contains an inspected credential: ' + str(path))
pairs = []
for original, retained in selected:
    retained.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(original, retained)
    data = retained.read_bytes()
    if data != original.read_bytes():
        raise ValueError('Retention bytes differ')
    pairs.append({'source': str(original.relative_to(repo)), 'retained': str(retained.relative_to(repo)),
                  'sha256': hashlib.sha256(data).hexdigest(), 'bytes': len(data)})
value = {'read_at_unix': time.time(),
         'scope': 'Selected exact source/capture copies read after execution. Native binary hashes are separately read back; binaries remain in the Actions artifact. Outer controller/qualifier source copies are read-after identities, not independent capture-time byte pins.',
         'credential_scan': {'inspected_token_values': len(secrets), 'matches': 0,
                             'scope': 'Owned admin/dashboard/TUI token files and named token values from available HTTP bodies read privately; not a proof of absence of every possible secret. Raw HTTP/provider logs, auth configuration, native binaries and full runtime are excluded.'},
         'absent_optional_capture_files': missing, 'pairs': pairs}
with (destination / 'provenance.json').open('x') as stream:
    json.dump(value, stream, indent=2)
    stream.write('\n')
print(json.dumps({'selected_pairs': len(pairs), 'selected_bytes': sum(p['bytes'] for p in pairs),
                  'inspected_token_values': len(secrets), 'matches': 0}))
