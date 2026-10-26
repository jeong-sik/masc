import argparse
import hashlib
import json
from pathlib import Path
import subprocess


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


parser = argparse.ArgumentParser()
for name in ('runtime-dir', 'artifact-dir', 'expected-commit', 'expected-shim-commit', 'fixture', 'shim',
             'shim-receipt', 'output-dir'):
    parser.add_argument('--' + name, required=True)
args = parser.parse_args()
runtime = Path(args.runtime_dir).resolve(strict=True)
artifact = Path(args.artifact_dir).resolve(strict=True)
fixture_path = Path(args.fixture).resolve(strict=True)
fixture = json.loads(fixture_path.read_text())
shim = Path(args.shim).resolve(strict=True)
shim_receipt_path = Path(args.shim_receipt).resolve(strict=True)
shim_receipt = json.loads(shim_receipt_path.read_text())
out = Path(args.output_dir).resolve()
out.mkdir(exist_ok=False)
helper = runtime / 'masc-exec-ssh-bootstrap'
keeper = 'native-bootstrap-keeper'
workspace = fixture['remote_root'].rstrip('/') + '/' + keeper
expected_file_sha = '6a075ec6d845b4e325caa9a407d7f68755df8551aefe5a626cf0019b0a629a21'
receipt = dict(result='FAIL', source=args.expected_commit, helper_sha256=sha(helper),
               shim_source=shim_receipt['source_commit'], shim_sha256=sha(shim),
               fixture=fixture, keeper=keeper, phases=[],
               not_claimed=['password first key copying', 'GitHub login', 'Keeper tool execution',
                            'real-model sustained use', 'release installation', 'production deployment'])


def docker(*argv):
    return subprocess.check_output(['docker', *argv])


def remote(program, *argv):
    return docker('exec', '--user', 'root', fixture['container'], 'python3', '-c', program, *argv)


def verify_container():
    info = json.loads(docker('inspect', fixture['container']))[0]
    assert info['Id'] == fixture['container_id'] and info['State']['Running']
    assert any(row['HostIp'] == fixture['host'] and row['HostPort'] == str(fixture['port'])
               for row in info['NetworkSettings']['Ports']['22/tcp'])


def snapshot():
    return json.loads(remote('''import hashlib,json,stat,sys
from pathlib import Path
p=Path(sys.argv[1]); s=p.lstat(); f=p/'retained file.bin'; fs=f.lstat()
assert stat.S_ISDIR(s.st_mode) and stat.S_ISREG(fs.st_mode)
b=f.read_bytes()
print(json.dumps(dict(owner=s.st_uid,group=s.st_gid,mode=stat.S_IMODE(s.st_mode),
 entries=sorted(child.name for child in p.iterdir()),length=len(b),sha256=hashlib.sha256(b).hexdigest(),
 file_owner=fs.st_uid,file_group=fs.st_gid,file_mode=stat.S_IMODE(fs.st_mode),
 github_hosts_exists=(p/'.config/gh/hosts.yml').exists())))
''', workspace))


def config_snapshot(phase):
    raw = docker('exec', fixture['container'], 'cat', '/etc/masc-exec-shim.conf')
    (out / ('config-' + phase + '.conf')).write_bytes(raw)
    pairs = [line.split('=', 1) for line in raw.decode().splitlines()
             if line.strip() and not line.lstrip().startswith('#')]
    assert all(len(pair) == 2 for pair in pairs) and len(dict(pairs)) == len(pairs)
    return dict(pairs)


def run_bootstrap(phase, binary, selected_keeper, expected_error=None):
    verify_container()
    command = [str(helper), '--base-path', fixture['base'], '--endpoint', 'bootstrap_proof',
               '--shim', str(binary), '--keeper', selected_keeper]
    result = subprocess.run(command, input=fixture['fingerprint'] + '\n', text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out / ('bootstrap-' + phase + '.txt')).write_text(result.stdout)
    receipt['phases'].append(dict(phase=phase, exit_code=result.returncode, argv=command,
                                  output_sha256=hashlib.sha256(result.stdout.encode()).hexdigest()))
    if expected_error is None:
        assert result.returncode == 0 and 'SSH endpoint bootstrap_proof provisioned.' in result.stdout, result.stdout
    else:
        assert result.returncode != 0 and expected_error in result.stdout, result.stdout
        assert 'provisioned.' not in result.stdout and 'remote_ssh_root_missing:' not in result.stdout, result.stdout
    assert config_snapshot(phase) == original_config
    after = snapshot()
    (out / ('workspace-' + phase + '.json')).write_text(json.dumps(after, indent=2) + '\n')
    assert after == original_workspace, 'bootstrap changed retained workspace bytes or ownership'
    return result.stdout


try:
    assert json.loads((artifact / 'probe.json').read_text())['source_commit'] == args.expected_commit
    assert subprocess.check_output([str(runtime / 'masc'), 'build-commit'], text=True).strip() == args.expected_commit
    for line in (artifact / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split(maxsplit=1)
        path = artifact / name.lstrip('*')
        assert path.parent.resolve() == artifact and sha(path) == digest
    assert sha(helper) == sha(artifact / 'masc-exec-ssh-bootstrap-macos-arm64')
    assert shim_receipt['source_commit'] == args.expected_shim_commit
    assert shim_receipt['binary_sha256'] == sha(shim)
    framed = shim_receipt['framed_config_execution']
    assert type(framed['exit']) is int and framed['exit'] == 0 and framed['stdout'] == 'config-loaded'
    verify_container()
    public_key = docker('exec', fixture['container'], 'cat', '/etc/ssh/ssh_host_ed25519_key.pub')
    fingerprint = subprocess.check_output(['ssh-keygen', '-lf', '-'], input=public_key).decode().split()[1]
    assert fingerprint == fixture['fingerprint']
    original_workspace = snapshot()
    assert original_workspace['sha256'] == expected_file_sha and original_workspace['length'] == 39
    assert original_workspace['entries'] == ['retained file.bin']
    assert original_workspace['owner'] == 1000 and original_workspace['mode'] == 0o700
    assert not original_workspace['github_hosts_exists']
    original_config = config_snapshot('before')
    assert all(key in original_config for key in ('path', 'env_file', 'scratch_root'))
    assert original_config['remote_root'] == fixture['remote_root']
    old_shim = Path(fixture['shim']).resolve(strict=True)
    assert sha(old_shim) == fixture['shim_sha256']
    refusal = run_bootstrap('old-shim-refusal', old_shim, keeper, 'remote_ssh_preflight_unavailable:')
    assert 'unknown key "env_file"' in ' '.join(refusal.split())
    run_bootstrap('exact-shim-first', shim, keeper)
    run_bootstrap('exact-shim-repeat', shim, keeper)
    installed_sha = remote('''import hashlib; from pathlib import Path
print(hashlib.sha256(Path('/usr/local/bin/masc-exec-shim').read_bytes()).hexdigest())
''').decode().strip()
    assert installed_sha == sha(shim)
    probe = json.loads(docker('exec', fixture['container'], '/usr/local/bin/masc-exec-shim', '--probe'))
    receipt.update(result='PASS', retained_workspace=original_workspace, config=original_config,
                   installed_shim_sha256=installed_sha, probe=probe,
                   github_tokens_supplied=False, artifact_checksums='PASS')
except (AssertionError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
    receipt['error'] = str(error)
finally:
    receipt['driver_sha256'] = sha(Path(__file__))
    (out / 'bootstrap-readiness-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
raise SystemExit(0 if receipt['result'] == 'PASS' else 1)
