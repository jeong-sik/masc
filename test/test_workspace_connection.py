"""Fresh native processes resolve workspace ports without starting a server."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

parser = argparse.ArgumentParser()
parser.add_argument('--binary', required=True)
args, remaining = parser.parse_known_args()
BINARY = str(Path(args.binary).resolve())

class WorkspacePort(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / 'workspace'
        self.base.mkdir()
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith('MASC_') and key not in ('HOME', 'XDG_CONFIG_HOME')}
        self.env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / 'user-config'))

    def command(self, *arguments, env=None, success=True):
        result = subprocess.run([BINARY, *arguments], env=env or self.env,
                                capture_output=True, text=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0)
        return result

    def connection(self, *arguments, **kwargs):
        return self.command('workspace-connection', '--base-path', str(self.base), *arguments, **kwargs)

    def test_fresh_process_reload_priority_and_workspace_isolation(self):
        saved = self.connection('--port', '19231', '--save')
        self.assertEqual(saved['readiness'], 'not_checked')
        self.assertEqual(self.connection()['port'], 19231)
        env = dict(self.env, MASC_HTTP_PORT='19232')
        self.assertEqual(self.connection(env=env)['port'], 19232)
        self.assertEqual(self.connection('--port', '19233', env=env)['port'], 19233)
        other = self.root / 'other'
        other.mkdir()
        self.assertNotEqual(self.command('workspace-connection', '--base-path', str(other))['port'], 19231)
        self.assertFalse((other / '.masc').exists())

    def test_save_preserves_unrelated_config_and_invalid_values_do_not_fall_back(self):
        config = self.base / '.masc/config/connection.toml'
        config.parent.mkdir(parents=True)
        config.write_text('# operator comment\n[server]\nhttp_port = 19231\nlabel = "keep"\n[editor]\nmode = "private"\n')
        config.chmod(0o640)
        self.connection('--port', '19234', '--save')
        self.assertIn('# operator comment', config.read_text())
        self.assertIn('label = "keep"\n[editor]\nmode = "private"', config.read_text())
        self.assertEqual(config.stat().st_mode & 0o777, 0o640)
        broken = '[server]\nhttp_port = "bad"\n'
        config.write_text(broken)
        self.connection(success=False)
        self.assertEqual(self.connection('--port', '19235')['port'], 19235)
        self.connection('--port', '19235', '--save', success=False)
        self.assertEqual(config.read_text(), broken)
        self.connection('--port', '0', success=False)
        self.connection(env=dict(self.env, MASC_HTTP_PORT='invalid'), success=False)

    def test_saved_default_workspace_is_resolved_lazily(self):
        self.connection('--port', '19236', '--save')
        record = self.root / 'user-config/masc/default-base-path'
        record.parent.mkdir(parents=True, exist_ok=True)
        record.write_text(str(self.base) + '\n')
        self.assertEqual(self.command('workspace-connection')['port'], 19236)
        version = subprocess.run([BINARY, '--version'], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(version.returncode, 0, version.stderr)

if __name__ == '__main__':
    unittest.main(argv=[__file__] + remaining)
