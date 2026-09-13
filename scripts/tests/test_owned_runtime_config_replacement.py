"""Configuration replacement failure boundaries; no live server is stopped."""
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / 'fusion-decision-live.py'
spec = importlib.util.spec_from_file_location('owned_operator', SCRIPT)
operator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operator)
OLD = b'[runtime]\ndefault = "existing"\n'
NEW = b'[runtime]\ndefault = "existing"\n[providers.local]\nprotocol = "ollama-http"\n'


class RuntimeConfigurationReplacementTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='masc-owned-config-test-')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.live = self.root / 'runtime.toml'
        self.live.write_bytes(OLD)
        self.candidate = self.root / 'candidate.toml'
        self.candidate.write_bytes(NEW)
        self.old_hash = hashlib.sha256(OLD).hexdigest()

    def prepare(self):
        return operator.prepare_runtime_config(self.live, self.candidate, self.old_hash)

    def test_preparation_parses_new_config_without_changing_live(self):
        parsed, replacement = self.prepare()
        self.assertEqual(parsed['providers']['local']['protocol'], 'ollama-http')
        self.assertEqual(replacement, (OLD, NEW))
        self.assertEqual(self.live.read_bytes(), OLD)

    def test_existing_restart_without_replacement_is_preserved(self):
        parsed, replacement = operator.prepare_runtime_config(self.live)
        self.assertEqual(parsed['runtime']['default'], 'existing')
        self.assertIsNone(replacement)
        self.assertEqual(self.live.read_bytes(), OLD)

    def test_incomplete_replacement_arguments_are_rejected(self):
        for candidate, digest in [(self.candidate, None), (None, self.old_hash)]:
            with self.subTest(candidate=candidate):
                with self.assertRaises(ValueError):
                    operator.prepare_runtime_config(self.live, candidate, digest)
                self.assertEqual(self.live.read_bytes(), OLD)

    def test_changed_original_is_not_overwritten(self):
        self.live.write_bytes(b'# another operator change\n')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.live.read_bytes(), b'# another operator change\n')

    def test_invalid_candidate_does_not_modify_original(self):
        self.candidate.write_bytes(b'[invalid')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.live.read_bytes(), OLD)

    def test_change_during_stop_is_not_overwritten(self):
        _, replacement = self.prepare()
        self.live.write_bytes(b'# edited while stopping\n')
        with self.assertRaises(ValueError):
            operator.replace_stopped_runtime_config(self.live, *replacement)
        self.assertEqual(self.live.read_bytes(), b'# edited while stopping\n')

    def test_replacement_commits_exact_private_bytes(self):
        _, replacement = self.prepare()
        operator.replace_stopped_runtime_config(self.live, *replacement)
        self.assertEqual(self.live.read_bytes(), NEW)
        self.assertEqual(self.live.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.root.glob('.runtime-replacement-*')), [])

    def test_failure_before_rename_preserves_original(self):
        with patch.object(operator.os, 'replace', side_effect=OSError('rename unavailable')):
            with self.assertRaises(OSError):
                operator.replace_stopped_runtime_config(self.live, OLD, NEW)
        self.assertEqual(self.live.read_bytes(), OLD)
        self.assertEqual(list(self.root.glob('.runtime-replacement-*')), [])

    def test_failure_after_rename_preserves_new_bytes_for_reconciliation(self):
        with patch.object(operator.os, 'fsync', side_effect=[None, OSError('directory sync failed')]):
            with self.assertRaises(OSError):
                operator.replace_stopped_runtime_config(self.live, OLD, NEW)
        self.assertEqual(self.live.read_bytes(), NEW)
        self.assertEqual(list(self.root.glob('.runtime-replacement-*')), [])

    def test_symlink_configuration_is_not_followed(self):
        self.live.unlink()
        self.live.symlink_to(self.candidate)
        with self.assertRaises(OSError):
            self.prepare()
        self.assertEqual(self.candidate.read_bytes(), NEW)

    def intent(self):
        return {'runtime_config_update': {'status': 'intent', 'before_sha256': self.old_hash,
                'after_sha256': hashlib.sha256(NEW).hexdigest()}}

    def test_unqualified_retry_does_not_ignore_unresolved_intent(self):
        with self.assertRaises(ValueError):
            operator.validate_runtime_config_intent(self.intent(), None)

    def test_retry_accepts_explicit_matching_before_or_after_bytes(self):
        for actual in (OLD, NEW):
            with self.subTest(actual=actual):
                state = self.intent()
                expected = dict(state['runtime_config_update'])
                operator.validate_runtime_config_intent(state, (actual, NEW))
                self.assertEqual(state['runtime_config_update'], expected)

    def test_conflicting_retry_preserves_unresolved_intent(self):
        for replacement in ((b'# unknown current', NEW), (OLD, b'# different replacement')):
            with self.subTest(replacement=replacement):
                state = self.intent()
                expected = dict(state['runtime_config_update'])
                with self.assertRaises(ValueError):
                    operator.validate_runtime_config_intent(state, replacement)
                self.assertEqual(state['runtime_config_update'], expected)


if __name__ == '__main__':
    unittest.main()
