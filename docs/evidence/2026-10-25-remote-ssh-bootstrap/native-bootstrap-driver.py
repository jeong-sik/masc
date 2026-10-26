import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--helper', required=True)
parser.add_argument('--source', required=True)
parser.add_argument('--fixture', required=True)
args = parser.parse_args()
fixture_path = Path(args.fixture).resolve(strict=True)
out = fixture_path.parent
fixture = json.loads(fixture_path.read_text())
helper = Path(args.helper).resolve(strict=True)
name, container_id = fixture['container'], fixture['container_id']
receipt_path = out / 'bootstrap-receipt.json'
assert not receipt_path.exists(), 'proof has already run; preserve it'

def docker(*argv):
    return subprocess.check_output(['docker', *argv])

def remote(program, *argv):
    return docker('exec', '--user', 'root', name, 'python3', '-c', program, *argv)

def config(content):
    pairs = [line.split('=', 1) for line in content.decode().splitlines()
             if line.strip() and not line.lstrip().startswith('#')]
    assert all(len(pair) == 2 for pair in pairs)
    result = dict(pairs)
    assert len(result) == len(pairs), 'duplicate shim configuration key'
    return result

before = (out / 'config-before.conf').read_bytes()
expected_config = config(before)
expected_config.update(remote_root=fixture['remote_root'], env_allowlist='')
keeper = 'native-bootstrap-keeper'
root = fixture['remote_root'] + '/' + keeper
marker = b'bootstrap retained bytes\x00\r\nwith spaces\n'
receipt = {'result': 'FAIL', 'runtime_source': args.source,
           'helper_sha256': hashlib.sha256(helper.read_bytes()).hexdigest(),
           'fixture': fixture, 'keeper': keeper, 'steps': [],
           'not_claimed': ['source-rebuilt shim', 'released distribution', 'production installation',
                           'GitHub login or cancellation', 'real-model sustained use']}

def check_config(phase):
    actual = docker('exec', name, 'cat', '/etc/masc-exec-shim.conf')
    (out / ('config-' + phase + '.conf')).write_bytes(actual)
    assert config(actual) == expected_config, 'bootstrap did not preserve endpoint-owned configuration'

def run_bootstrap(phase, selected_keeper, expected_ok):
    info = json.loads(docker('inspect', name))[0]
    assert info['Id'] == container_id and info['State']['Running']
    command = [str(helper), '--base-path', fixture['base'], '--endpoint', 'bootstrap_proof',
               '--shim', fixture['shim'], '--keeper', selected_keeper]
    result = subprocess.run(command, input=fixture['fingerprint'] + '\n',
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / ('bootstrap-' + phase + '.log')).write_text(result.stdout)
    record = {'phase': phase, 'argv': command, 'exit_code': result.returncode,
              'stdout_sha256': hashlib.sha256(result.stdout.encode()).hexdigest()}
    receipt['steps'].append(record)
    assert (result.returncode == 0) == expected_ok, result.stdout
    if expected_ok:
        assert 'SSH endpoint bootstrap_proof provisioned.' in result.stdout, result.stdout
    else:
        assert 'remote_ssh_directory_prepare_failed' in result.stdout, result.stdout
    check_config(phase)

def readback():
    return json.loads(remote('''import hashlib,json,os,stat,sys
from pathlib import Path
p=Path(sys.argv[1]); b=(p/'retained file.bin').read_bytes()
s=p.stat()
print(json.dumps({'sha256':hashlib.sha256(b).hexdigest(),'length':len(b),
 'owner':s.st_uid,'mode':stat.S_IMODE(s.st_mode),
 'github_hosts_exists':(p/'.config/gh/hosts.yml').exists()}))
''', root))

try:
    assert json.loads(remote('''import json,sys
from pathlib import Path
print(json.dumps({'workspace_exists':Path(sys.argv[1]).exists(),
 'fake_gh_exists':Path('/usr/local/bin/gh').exists()}))
''', root)) == {'workspace_exists': False, 'fake_gh_exists': False}
    run_bootstrap('first', keeper, True)
    remote('''import os,sys
from pathlib import Path
p=Path(sys.argv[1])/'retained file.bin'; p.write_bytes(bytes.fromhex(sys.argv[2])); os.chown(p,1000,1000)
''', root, marker.hex())
    original = readback()
    assert original == {'sha256': hashlib.sha256(marker).hexdigest(), 'length': len(marker),
                        'owner': 1000, 'mode': 0o700, 'github_hosts_exists': False}
    (out / 'workspace-after-first.json').write_text(json.dumps(original, indent=2) + '\n')
    run_bootstrap('repeat', keeper, True)
    assert readback() == original, 'repeat bootstrap changed existing workspace bytes or owner'
    outside = fixture['remote_root'] + '-outside'
    hostile = fixture['remote_root'] + '/hostile-keeper'
    def outside_state():
        return json.loads(remote('''import hashlib,json,stat,sys
from pathlib import Path
p=Path(sys.argv[1]); s=p.stat()
print(json.dumps({'owner':s.st_uid,'mode':stat.S_IMODE(s.st_mode),
 'sha256':hashlib.sha256((p/'outside-marker').read_bytes()).hexdigest()}))
''', outside))
    remote('''import os,sys
from pathlib import Path
outside=Path(sys.argv[1]); outside.mkdir(mode=0o755)
(outside/'outside-marker').write_bytes(b'outside must remain unchanged')
os.symlink(str(outside),sys.argv[2])
''', outside, hostile)
    outside_before = outside_state()
    run_bootstrap('symlink-refusal', 'hostile-keeper', False)
    assert outside_state() == outside_before, 'refused workspace changed its external target'
    assert readback() == original
    run_bootstrap('after-refusal', keeper, True)
    assert readback() == original
    receipt.update(result='PASS', workspace=original,
                   outside_before=outside_before, outside_after=outside_state(),
                   config=expected_config, github_tokens_supplied=False,
                   successful_bootstraps=3, expected_workspace_refusals=1)
except (AssertionError, OSError, subprocess.SubprocessError, ValueError) as error:
    receipt['error'] = str(error)
finally:
    receipt['driver_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
raise SystemExit(0 if receipt['result'] == 'PASS' else 1)
