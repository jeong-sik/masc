"""Native catalog preparation through a symlinked temporary directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
args, remaining = parser.parse_known_args()
BINARY = str(Path(args.binary).resolve())

class CatalogTemp(unittest.TestCase):
    def test_symlink_tmp_prepares_private_home_preserves_source_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            actual = root / 'actual-tmp'
            actual.mkdir(mode=0o700)
            linked = root / 'linked-tmp'
            linked.symlink_to(actual, target_is_directory=True)
            home = root / 'home'
            home.mkdir(mode=0o700)
            credential = root / 'account'
            credential.write_text('fixture-opaque-credential')
            credential.chmod(0o600)
            before = hashlib.sha256(credential.read_bytes()).hexdigest()
            cli = root / 'fixture-cli'
            cli.write_text('#!' + sys.executable + '\n' + '''import json, os, pathlib, sys
assert sys.argv[1:] == ['--output-format', 'json', 'models']
home = pathlib.Path(os.environ['HOME'])
assert home == home.resolve()
assert (home.stat().st_mode & 0o077) == 0
print(json.dumps({'status':'SUCCESS','num_turns':0,'usage':{'total_tokens':0},
 'command':{'name':'models','data':{'models':[{'id':'fixture-model','label':'Fixture model'}]}}}))
''')
            cli.chmod(0o700)
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(('MASC_', 'AGENT_CORE_'))}
            env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / '.config'), TMPDIR=str(linked))
            command = [BINARY, 'runtime-antigravity-models', '--cli-path', str(cli),
                       '--credential-file', str(credential)]
            result = subprocess.run(command, env=env, cwd=root, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            response = json.loads(result.stdout)
            self.assertEqual(response['models'][0]['id'], 'fixture-model')
            self.assertIs(response['account_availability_verified'], False)
            self.assertEqual(hashlib.sha256(credential.read_bytes()).hexdigest(), before)
            self.assertEqual(credential.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(actual.iterdir()), [])
            credential.chmod(0o644)
            rejected = subprocess.run(command, env=env, cwd=root, capture_output=True, text=True, timeout=60)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertEqual(list(actual.iterdir()), [])

if __name__ == '__main__':
    unittest.main(argv=[__file__] + remaining)
