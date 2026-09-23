"""scripts/tui-decoded-field-census.py over small source trees.

Each case writes a lib/tui_decode.ml and a few bin/ files and checks which
fields the census reports as decoded and read by nothing.
"""

import importlib.util
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).resolve().parents[1] / "scripts" / "tui-decoded-field-census.py"


def load_census_module():
    spec = importlib.util.spec_from_file_location("tui_decoded_field_census", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


census = load_census_module()

LIB_DECODER = """\
type status = {
  st_shown : string;
  st_compared : int;
  st_only_named_in_prose : string;
  st_patterned : int;
}

let decode json =
  let* st_shown = required_string_field json "shown" in
  let* st_compared = required_int_field json "compared" in
  let* st_only_named_in_prose = required_string_field json "st_only_named_in_prose" in
  let* st_patterned = required_int_field json "patterned" in
  if st_compared = 0 then Error "zero" else
  Ok { st_shown; st_compared; st_only_named_in_prose; st_patterned }

(* st_only_named_in_prose is mentioned here, which reads nothing. *)
"""

BIN_TYPES = """\
type pull = {
  pl_number : int;
  pl_title : string;
}

type screen = {
  sc_unused_state : int;
}
"""

BIN_DECODER = """\
let decode_pull json =
  let* pl_number = required_int_field json "number" in
  let* pl_title = required_string_field json "title" in
  Ok { pl_number; pl_title }
"""

BIN_RENDER = """\
let draw status pull =
  let { st_patterned; _ } = status in
  Printf.sprintf "%s %d #%d" status.st_shown st_patterned pull.pl_number
"""


class TuiDecodedFieldCensusTest(unittest.TestCase):
    def census_of(self, bin_files):
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            (root_path / "lib").mkdir()
            (root_path / "bin").mkdir()
            (root_path / "lib" / "tui_decode.ml").write_text(LIB_DECODER, encoding="utf-8")
            for name, text in bin_files.items():
                (root_path / "bin" / name).write_text(textwrap.dedent(text), encoding="utf-8")
            return {
                finding.field: str(finding.decoder) for finding in census.census(root_path)
            }

    def default_tree(self):
        return self.census_of(
            {
                "masc_tui_types.ml": BIN_TYPES,
                "masc_tui_pulls.ml": BIN_DECODER,
                "masc_tui_render.ml": BIN_RENDER,
            }
        )

    def test_a_bin_decoder_field_nothing_reads_is_reported(self):
        found = self.default_tree()
        self.assertEqual(found.get("pl_title"), "bin/masc_tui_pulls.ml")

    def test_a_bin_decoder_field_a_renderer_reads_is_not_reported(self):
        self.assertNotIn("pl_number", self.default_tree())

    def test_a_lib_decoder_field_nothing_reads_is_reported(self):
        found = self.default_tree()
        self.assertEqual(found.get("st_only_named_in_prose"), "lib/tui_decode.ml")

    def test_a_comparison_inside_the_decoder_is_a_read(self):
        self.assertNotIn("st_compared", self.default_tree())

    def test_a_field_read_through_a_pattern_pun_is_not_reported(self):
        self.assertNotIn("st_patterned", self.default_tree())

    def test_an_accessor_read_is_not_reported(self):
        self.assertNotIn("st_shown", self.default_tree())

    def test_a_record_no_decoder_fills_is_outside_the_census(self):
        self.assertNotIn("sc_unused_state", self.default_tree())

    def test_a_bin_file_without_decode_calls_is_not_a_decoder(self):
        found = self.census_of(
            {
                "masc_tui_types.ml": BIN_TYPES,
                "masc_tui_state.ml": "let make () = { pl_number = 1; pl_title = \"t\" }\n",
                "masc_tui_render.ml": BIN_RENDER,
            }
        )
        self.assertNotIn("pl_title", found)


if __name__ == "__main__":
    unittest.main()
