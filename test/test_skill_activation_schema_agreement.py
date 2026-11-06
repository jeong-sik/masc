"""The Skill activation schema names that OCaml writes and Python reads agree.

Keeper_skill_activation_ledger_encode names the ledger generation (``schema``)
and Keeper_skill_activation_ledger_events names the event log generation
(``events_schema``). The harness reader and the test fixture write the same
names down again in Python. A generation raised in one place only makes the
OCaml reader refuse a log the Python side still writes (Unsupported_schema), or
lets the harness fold a log the server would refuse.
"""

import importlib.util
from pathlib import Path
import re
import sys
import unittest

import skill_activation_event_log_fixture as log_fixture

REPO_ROOT = Path(__file__).resolve().parents[1]
LEDGER_SCHEMA_SOURCE = REPO_ROOT / "lib" / "keeper" / "keeper_skill_activation_ledger_encode.ml"
EVENTS_SCHEMA_SOURCE = REPO_ROOT / "lib" / "keeper" / "keeper_skill_activation_ledger_events.ml"
HARNESS = REPO_ROOT / "scripts" / "harness" / "workload" / "skill_activation_events.py"
# A definition inside a comment is not the one the compiler reads.
OCAML_COMMENT = re.compile(r"\(\*.*?\*\)", re.DOTALL)


def ocaml_string_constant(source_path, name):
    source = OCAML_COMMENT.sub("", source_path.read_text(encoding="utf-8"))
    found = re.findall(rf'^let {name} = "([^"]+)"$', source, re.MULTILINE)
    if len(found) != 1:
        raise AssertionError(
            f"{source_path.name} must hold exactly one top-level string 'let {name}', found {found}"
        )
    return found[0]


def load_harness():
    spec = importlib.util.spec_from_file_location("skill_activation_events", HARNESS)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {HARNESS}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SkillActivationSchemaAgreement(unittest.TestCase):
    def test_the_event_log_generation_is_the_one_ocaml_writes(self):
        expected = ocaml_string_constant(EVENTS_SCHEMA_SOURCE, "events_schema")
        self.assertEqual(load_harness().EVENTS_SCHEMA, expected)
        self.assertEqual(log_fixture.EVENTS_SCHEMA, expected)

    def test_the_ledger_generation_is_the_one_ocaml_serves(self):
        self.assertEqual(
            load_harness().LEDGER_SCHEMA,
            ocaml_string_constant(LEDGER_SCHEMA_SOURCE, "schema"),
        )


if __name__ == "__main__":
    unittest.main()
