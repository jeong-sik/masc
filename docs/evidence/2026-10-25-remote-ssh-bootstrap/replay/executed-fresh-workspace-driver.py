import datetime
import hashlib
import json
from pathlib import Path
import subprocess

fixture = json.loads(Path('/tmp/mssh-bootstrap-native-20261025/fixture.json').read_text())
runtime = Path('/tmp/mssh-candidate-runtime-a768556')
helper = runtime / 'masc-exec-ssh-bootstrap'
shim = Path('/tmp/mssh-static-shim-327fd90/masc-exec-shim-linux-arm64')
keeper = 'native-fresh-20261026'
root = fixture['remote_root'] + '/' + keeper
out = Path('/tmp/mssh-fresh-workspace-a768556-20261026')
out.mkdir(exist_ok=False)
receipt = dict(result='FAIL', helper_source='a7685562be55678229ce29668c624d222cd76d67',
               helper_sha256=hashlib.sha256(helper.read_bytes()).hexdigest(),
               shim_source='327fd90f7fec1a07f4ca7e5836d5cad3e8e39c15',
               shim_sha256=hashlib.sha256(shim.read_bytes()).hexdigest(), keeper=keeper, phases=[],
               key_authentication='preauthorized identity; password first copy not covered')


def docker(*argv):
    return subprocess.check_output(['docker', *argv])


def remote(program, *argv):
    return docker('exec', '--user', 'root', fixture['container'], 'python3', '-c', program, *argv)


def snapshot():
    return json.loads(remote('''import hashlib,json,stat,sys
from pathlib import Path
p=Path(sys.argv[1]); s=p.lstat(); assert stat.S_ISDIR(s.st_mode)
f=p/'fresh retained.bin'
print(json.dumps(dict(owner=s.st_uid,mode=stat.S_IMODE(s.st_mode),entries=sorted(c.name for c in p.iterdir()),
 sha256=hashlib.sha256(f.read_bytes()).hexdigest() if f.exists() else None,
 github_hosts_exists=(p/'.config/gh/hosts.yml').exists())))
''', root))


def bootstrap(phase):
    argv = [str(helper), '--base-path', fixture['base'], '--endpoint', 'bootstrap_proof',
            '--shim', str(shim), '--keeper', keeper]
    result = subprocess.run(argv, input=fixture['fingerprint']+'\n', text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (out/(phase+'.txt')).write_text(result.stdout)
    receipt['phases'].append(dict(phase=phase,exit_code=result.returncode,argv=argv,
                                  output_sha256=hashlib.sha256(result.stdout.encode()).hexdigest()))
    assert result.returncode == 0 and 'provisioned.' in result.stdout, result.stdout


try:
    info = json.loads(docker('inspect', fixture['container']))[0]
    assert info['Id'] == fixture['container_id'] and info['State']['Running']
    assert subprocess.check_output([str(runtime/'masc'),'build-commit'],text=True).strip()==receipt['helper_source']
    public = docker('exec', fixture['container'],'cat','/etc/ssh/ssh_host_ed25519_key.pub')
    assert subprocess.check_output(['ssh-keygen','-lf','-'],input=public).decode().split()[1]==fixture['fingerprint']
    exists = remote('from pathlib import Path; import sys; print(Path(sys.argv[1]).exists())',root).decode().strip()
    assert exists == 'False', 'fresh workspace already exists; preserve it'
    config_before = docker('exec',fixture['container'],'cat','/etc/masc-exec-shim.conf')
    bootstrap('first-create')
    created = snapshot()
    assert created == dict(owner=1000,mode=0o700,entries=[],sha256=None,github_hosts_exists=False),created
    marker = b'fresh-bootstrap\x00\r\npreserved\n'
    remote('''import os,sys; from pathlib import Path
p=Path(sys.argv[1])/'fresh retained.bin'; p.write_bytes(bytes.fromhex(sys.argv[2])); os.chown(p,1000,1000)
''',root,marker.hex())
    before_repeat = snapshot()
    bootstrap('repeat')
    after_repeat = snapshot()
    assert before_repeat == after_repeat
    assert after_repeat['sha256'] == hashlib.sha256(marker).hexdigest()
    assert docker('exec',fixture['container'],'cat','/etc/masc-exec-shim.conf')==config_before
    receipt.update(result='PASS',created=created,before_repeat=before_repeat,after_repeat=after_repeat,
                   config_sha256=hashlib.sha256(config_before).hexdigest(),github_tokens_supplied=False)
except (AssertionError,OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
    receipt['error']=str(error)
finally:
    receipt['driver_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    receipt['recorded_at']=datetime.datetime.now(datetime.timezone.utc).isoformat()
    (out/'fresh-workspace-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
raise SystemExit(0 if receipt['result']=='PASS' else 1)
