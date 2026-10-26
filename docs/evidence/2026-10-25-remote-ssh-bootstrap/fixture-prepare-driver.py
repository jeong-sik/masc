import hashlib
import json
from pathlib import Path
import subprocess

out = Path('/tmp/mssh-bootstrap-native-20261025')
name = 'masc-ssh-bootstrap-proof-20261025'
expected_id = '7c0b77a2fd787f9fae757dcdf6a4bd6d18f26922b1ff8530458a9a61de739f72'

def run(argv):
    return subprocess.check_output(argv)

info = json.loads(run(['docker', 'inspect', name]))[0]
assert info['Id'] == expected_id and info['State']['Running']
port = int(info['NetworkSettings']['Ports']['22/tcp'][0]['HostPort'])
config = ('remote_root=/srv/masc/playground\n'
          'env_allowlist=FOO,PATH\n'
          'path=/opt/masc-bootstrap-proof/bin:/usr/local/bin:/usr/bin:/bin\n'
          'env_file=/etc/masc-bootstrap-proof.env\n'
          'scratch_root=/tmp/masc-bootstrap-proof-scratch\n')
prepare = '''from pathlib import Path
import os
p = Path('/usr/local/bin/gh')
if p.exists():
    assert b'auth' in p.read_bytes() and b'/usr/bin/gh' in p.read_bytes()
    p.unlink()
Path('/opt/masc-bootstrap-proof/bin').mkdir(parents=True, exist_ok=True)
tool = Path('/opt/masc-bootstrap-proof/bin/bootstrap-proof-tool')
tool.write_text('#!/bin/sh\\nprintf "%s\\\\n" bootstrap-tool-preserved\\n')
tool.chmod(0o755)
env = Path('/etc/masc-bootstrap-proof.env')
env.write_text('BOOTSTRAP_PROOF_ENV=bootstrap-environment-preserved\\n')
env.chmod(0o644)
Path('/tmp/masc-bootstrap-proof-scratch').mkdir(mode=0o1777, exist_ok=True)
Path('/etc/masc-exec-shim.conf').write_text(CONFIG)
'''.replace('CONFIG', repr(config))
subprocess.run(['docker', 'exec', '--user', 'root', name, 'python3', '-c', prepare], check=True)
(out / 'config-before.conf').write_bytes(run(['docker', 'exec', name, 'cat', '/etc/masc-exec-shim.conf']))
public = run(['docker', 'exec', name, 'cat', '/etc/ssh/ssh_host_ed25519_key.pub'])
(out / 'container-host-key.pub').write_bytes(public)
fingerprint = run(['ssh-keygen', '-E', 'sha256', '-lf', str(out / 'container-host-key.pub')]).decode().split()[1]
pins = out / 'observed-host-keys'
scan = subprocess.run(['ssh-keyscan', '-T', '5', '-p', str(port), '-t', 'ed25519', '127.0.0.1'], capture_output=True, check=True)
pins.write_bytes(scan.stdout)
assert run(['ssh-keygen', '-E', 'sha256', '-lf', str(pins)]).decode().split()[1] == fingerprint
shim = out / 'preexisting-shim-linux-arm64'
subprocess.run(['docker', 'cp', name + ':/usr/local/bin/masc-exec-shim', str(shim)], check=True)
shim.chmod(0o755)
base = out / 'workspace'
template = Path('/tmp/masc-ssh-evidence-stack-v2-20261025/scripts/fixtures/release-evidence/runtime.toml').read_text()
endpoint = {'host': '127.0.0.1', 'port': port, 'user': 'masc',
            'remote_root': '/srv/masc/bootstrap-ready',
            'identity_file': str(base / '.masc/ssh/bootstrap.key'),
            'known_hosts_file': str(base / '.masc/ssh/known_hosts'),
            'env_allowlist': [], 'private_home': False}
template += '\n[exec.ssh.endpoints.bootstrap_proof]\n' + '\n'.join(k + ' = ' + json.dumps(v) for k, v in endpoint.items()) + '\n'
(base / '.masc/config').mkdir(mode=0o700)
(base / '.masc/config/runtime.toml').write_text(template)
receipt = {'container': name, 'container_id': expected_id, 'image': info['Image'],
           'host': '127.0.0.1', 'port': port, 'fingerprint': fingerprint,
           'out_of_band': 'Docker-owned fixture host public key matched against ssh-keyscan',
           'shim_sha256': hashlib.sha256(shim.read_bytes()).hexdigest(),
           'shim_source': 'preexisting separately identified fixture binary; not source rebuilt',
           'remote_root': endpoint['remote_root'], 'base': str(base), 'shim': str(shim)}
(out / 'fixture.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
