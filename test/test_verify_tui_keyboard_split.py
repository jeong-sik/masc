"""The source proof must notice module state without running a terminal."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "verify_keyboard_split", Path(__file__).resolve().parents[1] / "scripts/verify-tui-keyboard-split.py")
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


class ModuleStateProof(unittest.TestCase):
    def test_changed_constant_cannot_hide_behind_identical_definitions(self):
        before = b"TIMEOUT = 3\ndef run():\n    return TIMEOUT\n"
        after = b"TIMEOUT = 30\ndef run():\n    return TIMEOUT\n"
        self.assertEqual(verifier.definitions(before), verifier.definitions(after))
        self.assertNotEqual(verifier.module_statements(before), verifier.module_statements(after))

    def test_dropped_executable_statement_is_detected(self):
        self.assertNotEqual(verifier.module_statements(b"register_fixture()\n"),
                            verifier.module_statements(b""))

    def test_duplicate_assignment_is_not_collapsed(self):
        self.assertNotEqual(verifier.module_statements(b"PATH = 'fixture'\n"),
                            verifier.module_statements(b"PATH = 'fixture'\nPATH = 'fixture'\n"))

    def test_entrypoint_and_annotation_values_are_inventoried(self):
        self.assertNotEqual(verifier.module_statements(b"LIMIT: int = 3\n"),
                            verifier.module_statements(b"LIMIT: int = 4\n"))
        self.assertNotEqual(verifier.module_statements(b"if __name__ == '__main__':\n    main()\n"),
                            verifier.module_statements(b"if __name__ == '__main__':\n    other()\n"))


if __name__ == "__main__":
    unittest.main()
