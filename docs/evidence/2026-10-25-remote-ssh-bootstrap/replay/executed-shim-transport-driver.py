import argparse
import base64
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile

parser = argparse.ArgumentParser()
for name in ('fixture', 'shim', 'shim-receipt', 'output-dir'):
    parser.add_argument('--' + name, required=True)
args = parser.parse_args()
fixture = json.loads(Path(args.fixture).read_text())
shim = Path(args.shim).resolve(strict=True)
build = json.loads(Path(args.shim_receipt).read_text())
out = Path(args.output_dir).resolve()
out.mkdir(exist_ok=False)
remote_shim = '/tmp/masc-shim-transport-proof-' + build['source_commit']
workspace = fixture['remote_root'].rstrip('/') + '/native-bootstrap-keeper'
receipt = dict(result='FAIL', scope='direct framed OpenSSH config compatibility; not a Keeper or bootstrap run',
               fixture=fixture, source=build['source_commit'], binary_sha256=build['binary_sha256'], phases=[])


def docker(*argv):
    return subprocess.check_output(['docker', *argv])


def state():
    return json.loads(docker('exec', fixture['container'], 'python3', '-c', '''
import hashlib,json,sys
from pathlib import Path
p=Path(sys.argv[1]); b=(p/'retained file.bin').read_bytes()
print(json.dumps(dict(entries=sorted(c.name for c in p.iterdir()),
 retained_sha256=hashlib.sha256(b).hexdigest(),config_sha256=hashlib.sha256(Path('/etc/masc-exec-shim.conf').read_bytes()).hexdigest(),
 installed_shim_sha256=hashlib.sha256(Path('/usr/local/bin/masc-exec-shim').read_bytes()).hexdigest())))
''', workspace))


def invoke(binary, frame, phase):
    prefix = ['ssh', '-F', '/dev/null', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
              '-o', 'UserKnownHostsFile=' + str(Path(fixture['base']) / '.masc/ssh/known_hosts'),
              '-o', 'GlobalKnownHostsFile=none', '-o', 'ControlMaster=no', '-o', 'ControlPath=none',
              '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none', '-o', 'IdentityFile=none',
              '-o', 'ConnectTimeout=10', '-i', str(Path(fixture['base']) / '.masc/ssh/bootstrap.key'),
              '-p', str(fixture['port']), 'masc@' + fixture['host'], binary]
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        with subprocess.Popen(prefix, stdin=subprocess.PIPE, stdout=stdout, stderr=stderr) as process:
            try:
                process.stdin.write(frame)
                process.stdin.flush()
                status = process.wait(timeout=60)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
                process.stdin.close()
        stdout.seek(0)
        stderr.seek(0)
        output, errors = stdout.read(), stderr.read()
    (out / (phase + '-stdout.txt')).write_bytes(output)
    (out / (phase + '-stderr.txt')).write_bytes(errors)
    receipt['phases'].append(dict(phase=phase, argv=prefix, exit_code=status,
                                 stdout_sha256=hashlib.sha256(output).hexdigest(),
                                 stderr_sha256=hashlib.sha256(errors).hexdigest()))
    return status, output, errors


try:
    actual_sha = hashlib.sha256(shim.read_bytes()).hexdigest()
    assert actual_sha == build['binary_sha256']
    info = json.loads(docker('inspect', fixture['container']))[0]
    assert info['Id'] == fixture['container_id'] and info['State']['Running']
    public_key = docker('exec', fixture['container'], 'cat', '/etc/ssh/ssh_host_ed25519_key.pub')
    assert subprocess.check_output(['ssh-keygen', '-lf', '-'], input=public_key).decode().split()[1] == fixture['fingerprint']
    before = state()
    receipt['before'] = before
    assert before['retained_sha256'] == '6a075ec6d845b4e325caa9a407d7f68755df8551aefe5a626cf0019b0a629a21'
    assert before['entries'] == ['retained file.bin']
    assert before['installed_shim_sha256'] == fixture['shim_sha256']
    exists = subprocess.run(['docker', 'exec', fixture['container'], 'test', '-e', remote_shim])
    assert exists.returncode in (0, 1), 'cannot inspect candidate probe binary'
    if exists.returncode == 1:
        subprocess.run(['docker', 'cp', str(shim), fixture['container'] + ':' + remote_shim], check=True)
        subprocess.run(['docker', 'exec', '--user', 'root', fixture['container'], 'chmod', '0755', remote_shim], check=True)
    subprocess.run(['docker', 'exec', fixture['container'], 'python3', '-c',
                    'import stat,sys; from pathlib import Path; assert stat.S_ISREG(Path(sys.argv[1]).lstat().st_mode)',
                    remote_shim], check=True)
    uploaded_sha = docker('exec', fixture['container'], 'sha256sum', remote_shim).decode().split()[0]
    assert uploaded_sha == actual_sha
    payload = ('import hashlib,json,os,subprocess; from pathlib import Path; '
               'print(json.dumps(dict(cwd=os.getcwd(),uid=os.getuid(),'
               'env=os.environ.get("BOOTSTRAP_PROOF_ENV"),'
               'tool=subprocess.check_output(["bootstrap-proof-tool"],text=True).strip(),'
               'retained_sha256=hashlib.sha256(Path("retained file.bin").read_bytes()).hexdigest())))')
    encode = lambda value: base64.b64encode(value.encode()).decode('ascii')
    request = dict(v=3, argv=list(map(encode, ['python3', '-c', payload])), env=[],
                   cwd=encode(workspace), remote_root=encode(workspace), timeout_sec=10.0,
                   stdin_len=0, mode='effect')
    body = json.dumps(request).encode()
    frame = struct.pack('>Q', len(body)) + body
    status, _, errors = invoke('/usr/local/bin/masc-exec-shim', frame, 'old-shim')
    old_parts = errors.split(b'\x1e')
    assert status != 0 and len(old_parts) == 3 and not old_parts[-1], errors
    old_trailer = json.loads(old_parts[1])['masc_exec_result']
    assert old_trailer['exit'] is None and old_trailer['signal'] is None
    assert old_trailer['timed_out'] is False
    assert 'unknown key "env_file"' in old_trailer['shim_error'], old_trailer
    receipt['old_refusal'] = old_trailer
    status, output, errors = invoke(remote_shim, frame, 'exact-shim')
    assert status == 0, errors
    parts = errors.split(b'\x1e')
    assert len(parts) == 3 and not parts[-1], errors
    trailer = json.loads(parts[1])['masc_exec_result']
    assert type(trailer['v']) is int and trailer['v'] == 3
    assert type(trailer['exit']) is int and trailer['exit'] == 0
    assert trailer['signal'] is None and trailer['timed_out'] is False and trailer['shim_error'] is None
    observation = json.loads(output)
    assert observation == dict(cwd=workspace, uid=1000, env='bootstrap-environment-preserved',
                               tool='bootstrap-tool-preserved', retained_sha256=before['retained_sha256']), observation
    after = state()
    assert before == after, 'direct probe changed existing config, installed shim or workspace'
    receipt.update(result='PASS', observation=observation, trailer=trailer, before=before, after=after,
                   uploaded_shim_sha256=uploaded_sha, bootstrap_exercised=False, keeper_exercised=False,
                   real_model=False, production=False)
except (AssertionError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
    receipt['error'] = str(error)
finally:
    receipt['driver_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (out / 'shim-transport-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
raise SystemExit(0 if receipt['result'] == 'PASS' else 1)
