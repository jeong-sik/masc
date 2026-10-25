import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--harness', required=True)
for name in ('binary', 'expected-commit', 'output-dir', 'keeper', 'host', 'user',
             'remote-root', 'identity', 'known-hosts'):
    parser.add_argument('--' + name, required=True)
parser.add_argument('--port', type=int, default=22)
args = parser.parse_args()
args.exercise_pin_rotation = False
args.exercise_shell_io = False
harness = Path(args.harness).resolve(strict=True)
spec = importlib.util.spec_from_file_location('ssh_proof', harness)
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)


class CwdReuseFixture(proof.FilesFixture):
    def __init__(self, marker, output, **kwargs):
        super().__init__(marker, output, **kwargs)
        self.steps.insert(1, ('Execute', {}))

    def validate(self, name, content):
        super().validate(name, content)
        if name == 'Execute':
            expected_root = args.remote_root.rstrip('/') + '/' + args.keeper
            responses = [obj for obj in proof.smoke.objects(content)
                         if obj.get('ok') is True and 'execution_location' in obj]
            if not responses or any(
                    obj.get('cwd') != expected_root
                    or obj['execution_location'].get('cwd') != expected_root
                    or obj['execution_location'].get('playground_root') != expected_root
                    for obj in responses):
                raise proof.smoke.SmokeError('Execute metadata does not name the endpoint workspace')
        if self.phase == 0 and self.step == 0:
            reported = self.proof['cwd']
            program = (
                'import base64,json,os; from pathlib import Path; '
                'reported=' + repr(reported) + '; '
                'p=json.loads(Path(reported,"ssh-proof.json").read_bytes()); '
                'p.update(reused_marker=p["marker"],copied_cwd=reported,'
                'actual_cwd_base64=base64.b64encode(os.getcwd().encode()).decode()); '
                'print(json.dumps(p))')
            self.steps[1] = ('Execute', {'argv': ['python3', '-c', program], 'cwd': reported})
            for index in (2, 3, 4):
                self.steps[index][1]['file_path'] = str(Path(reported) / 'notes.txt')
            self.steps[5][1]['path'] = str(Path(reported) / 'notes.txt')
        elif self.phase == 0 and self.step == 1:
            observation = self.proof
            actual = base64.b64decode(observation['actual_cwd_base64'], validate=True).decode()
            expected = args.remote_root.rstrip('/') + '/' + args.keeper
            if (observation.get('reused_marker') != self.marker
                    or observation.get('copied_cwd') != expected or actual != expected
                    or observation.get('cwd') != expected):
                raise proof.smoke.SmokeError('reported cwd does not match the actual process namespace')
            (self.output / 'cwd-reuse.json').write_text(json.dumps(observation, indent=2) + '\n')


proof.FilesFixture = CwdReuseFixture
result = proof.run(args)
output = Path(args.output_dir).resolve()
receipt = {
    'result': 'PASS' if result == 0 else 'FAIL',
    'scope': 'reported cwd reused in literal Python, Execute cwd, and absolute Write/Read/Edit/Grep inputs',
    'driver_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'harness_sha256': hashlib.sha256(harness.read_bytes()).hexdigest(),
    'runtime_source': args.expected_commit,
    'proof_receipt': json.loads((output / 'receipt.json').read_text()),
    'not_claimed': ['real-model autonomy', 'production installation', 'whole-turn configuration freeze'],
}
if result == 0:
    receipt['observation'] = json.loads((output / 'cwd-reuse.json').read_text())
(output / 'cwd-reuse-receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
raise SystemExit(result)
