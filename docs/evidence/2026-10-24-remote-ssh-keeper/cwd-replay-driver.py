import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path

root = Path('/tmp/masc-ssh-evidence-stack-v2-20261025')
harness = root / 'scripts/remote-ssh-keeper-proof.py'
spec = importlib.util.spec_from_file_location('ssh_proof', harness)
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)
keeper = 'ssh-proof-20261025-e'
output = Path('/tmp/mssh-keeper-cwd-replay-ready-a317')


class CwdReplayFixture(proof.FilesFixture):
    def __init__(self, marker, output, **kwargs):
        super().__init__(marker, output, **kwargs)
        self.steps.insert(1, ('Execute', {}))

    def validate(self, name, content):
        if self.phase == 0 and self.step == 1:
            payload = json.loads(content)
            if (payload.get('ok') is not True
                    or payload.get('status') != {'kind': 'exit', 'code': 0}):
                raise proof.smoke.SmokeError('cwd replay did not run successfully')
            observations = [obj for obj in proof.smoke.objects(content)
                            if obj.get('marker') == self.marker and 'reported_read_errno' in obj]
            if len(observations) != 1:
                raise proof.smoke.SmokeError('cwd replay lacks one observation')
            observation = observations[0]
            actual_cwd = base64.b64decode(observation['actual_cwd_base64'], validate=True).decode()
            if (observation['reported_cwd'] != self.proof['cwd']
                    or observation['reported_read_errno'] != 2
                    or observation['relative_read_marker'] != self.marker
                    or actual_cwd != '/srv/masc/playground/' + keeper):
                raise proof.smoke.SmokeError('cwd mismatch was not reproduced exactly')
            (self.output / 'cwd-replay.json').write_text(json.dumps(observation, indent=2) + '\n')
            return
        super().validate(name, content)
        if self.phase == 0 and self.step == 0:
            reported_cwd = self.proof['cwd']
            program = (
                'import base64,json,os; from pathlib import Path; '
                'reported=' + repr(reported_cwd) + '; '
                'relative=json.loads(Path("ssh-proof.json").read_bytes()); '
                'error=None\n'
                'try:\n Path(reported,"ssh-proof.json").read_bytes()\n'
                'except OSError as exc:\n error=exc.errno\n'
                'print(json.dumps({"marker":' + repr(self.marker) + ','
                '"reported_cwd":reported,"reported_read_errno":error,'
                '"relative_read_marker":relative["marker"],'
                '"actual_cwd_base64":base64.b64encode(os.getcwd().encode()).decode()}))')
            self.steps[1] = ('Execute', {'argv': ['python3', '-c', program]})


proof.FilesFixture = CwdReplayFixture
args = argparse.Namespace(
    binary='/tmp/mssh-candidate-runtime-a317/masc',
    expected_commit='a3173b973ab93a6b64fd301bca105a67a7529d00',
    output_dir=str(output), keeper=keeper, host='127.0.0.1', port=56243,
    user='masc', remote_root='/srv/masc/playground',
    identity='/tmp/mssh-keeper-ready-20261024/identity',
    known_hosts='/tmp/mssh-keeper-ready-20261024/known_hosts',
    exercise_pin_rotation=False, exercise_shell_io=False)
result = proof.run(args)
if result == 0:
    receipt = {
        'result': 'REPRODUCED', 'issue': 38593,
        'scope': 'actual a317 Keeper reuses its previous tool output cwd inside a literal Python script',
        'observation': json.loads((output / 'cwd-replay.json').read_text()),
        'driver_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'harness_sha256': hashlib.sha256(harness.read_bytes()).hexdigest(),
        'runtime_source': args.expected_commit,
        'binary_sha256': hashlib.sha256(Path(args.binary).read_bytes()).hexdigest(),
        'proof_receipt': json.loads((output / 'receipt.json').read_text()),
        'not_claimed': ['repair', 'execution of current main', 'real-model autonomous discovery', 'production installation'],
    }
    (output / 'cwd-replay-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
raise SystemExit(result)
