# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0"]
# ///
# pyright: strict
"""Tests for scripts/tinker/librarian/prompt_lines.py: what prompt_lines.json fixes for a prompt
comparison, and which files it refuses.

The lines are invented (`tinker_librarian_prompt_fixtures.py`), but for the committed
prompt_lines.json that `PinnedLinesTest` reads, as it is and with a baseline pinned for every model.
`eval_admission` imports the Tinker caller, which imports openai, so this file runs with `uv run`.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import cast
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import eval_admission as V
import prompt_counts as C
import prompt_lines as L
from tinker_librarian_prompt_fixtures import BASE_T, FILES, OTHER_T, PIN, sha

type Raw = dict[str, object]

GONE = object()
INKLING = ("models", "inkling", "baseline")
GLM = ("models", "glm", "baseline")
RECORD: Raw = {"agree": 1, "candidates": 2, "dropped_not_in_live": 0}


def raw_baseline(*runs: str, provider: str = "tinker", model: str = "inkling-model") -> Raw:
    return {"provider": provider, "model": model,
            "pass_lines_sha256": PIN, "template_sha256": BASE_T, "prompt_counts_sha256": FILES[L.COUNTS],
            "counts": {m.value: [3 * len(runs), 10 * len(runs)] for m in C.Metric},
            "real_record": [dict(RECORD) for _ in runs],
            "synth_rows_sha256": [sha(f"{r} synth") for r in runs],
            "real_rows_sha256": [sha(f"{r} real") for r in runs]}


def raw_lines() -> Raw:
    """A prompt_lines.json that pins both models' baselines."""
    return {"schema": "masc.tinker.librarian.prompt_lines.v2", "pass_lines_sha256": PIN,
            "baseline_template_sha256": BASE_T, "worse_sigmas": 2.5, "better_sigmas": 2.0, "better_from": ["inkling"],
            "models": {"inkling": {"provider": "tinker", "model": "inkling-model", "runs": 2,
                                   "baseline": raw_baseline("i1", "i2")},
                       "glm": {"provider": "glm", "model": "glm-model", "runs": 1,
                               "baseline": raw_baseline("g1", provider="glm", model="glm-model")}},
            "files_sha256": dict(FILES)}


def changed(path: tuple[str, ...], value: object) -> Raw:
    """`raw_lines()` with `value` at `path`, or without that key when `value` is GONE."""
    raw = raw_lines()
    at = raw
    for key in path[:-1]:
        at = cast(Raw, at[key])
    if value is GONE:
        del at[path[-1]]
    else:
        at[path[-1]] = value
    return raw


def with_baselines(raw: Raw) -> Raw:
    """`raw` with an invented baseline pinned for every model whose baseline is null, counted for that
    model under what `raw` pins."""
    counted_with = cast(dict[str, str], raw["files_sha256"])[L.COUNTS]
    models: Raw = {}
    for name, held in cast(dict[str, Raw], raw["models"]).items():
        runs = [f"{name} {n}" for n in range(cast(int, held["runs"]))]
        invented = raw_baseline(*runs, provider=cast(str, held["provider"]), model=cast(str, held["model"])) | {
            "pass_lines_sha256": raw["pass_lines_sha256"], "template_sha256": raw["baseline_template_sha256"],
            "prompt_counts_sha256": counted_with}
        models[name] = held | {"baseline": invented if held["baseline"] is None else held["baseline"]}
    return raw | {"models": models}


def counted_under(raw: Raw, under: Raw) -> Raw:
    """`raw` with every pinned baseline naming `under` as what it was counted under."""
    models = {name: held | {"baseline": None if held["baseline"] is None else cast(Raw, held["baseline"]) | under}
              for name, held in cast(dict[str, Raw], raw["models"]).items()}
    return raw | {"models": models}


class LinesTest(unittest.TestCase):
    def test_a_pinned_file_reads_as_its_numbers(self) -> None:
        lines = L.lines_of(raw_lines())
        self.assertEqual((lines.pass_lines_sha256, lines.baseline_template_sha256, lines.files_sha256),
                         (PIN, BASE_T, FILES))
        self.assertEqual((lines.worse_sigmas, lines.better_sigmas, lines.better_from), (2.5, 2.0, frozenset({"inkling"})))
        inkling, glm = lines.models["inkling"], lines.models["glm"]
        self.assertEqual((inkling.provider, inkling.model, inkling.runs), ("tinker", "inkling-model", 2))
        self.assertEqual((glm.provider, glm.model, glm.runs), ("glm", "glm-model", 1))
        self.assertEqual(inkling.baseline,
                         L.Baseline("tinker", "inkling-model", PIN, BASE_T, FILES[L.COUNTS],
                                    {m: C.Count(6, 20) for m in C.Metric},
                                    (C.RealRecord(1, 2, 0), C.RealRecord(1, 2, 0)),
                                    (sha("i1 synth"), sha("i2 synth")), (sha("i1 real"), sha("i2 real"))))
        assert glm.baseline is not None
        self.assertEqual((glm.baseline.provider, glm.baseline.model), ("glm", "glm-model"))

    def test_a_model_whose_baseline_is_null_has_none(self) -> None:
        lines = L.lines_of(changed(GLM, None))
        self.assertIsNone(lines.models["glm"].baseline)
        self.assertIsNotNone(lines.models["inkling"].baseline)

    def test_a_width_of_zero_or_a_whole_number_is_read(self) -> None:
        lines = L.lines_of(changed(("worse_sigmas",), 0) | {"better_sigmas": 3})
        self.assertEqual((lines.worse_sigmas, lines.better_sigmas), (0.0, 3.0))

    def test_a_baseline_written_out_reads_back_the_same(self) -> None:
        raw = raw_baseline("i1", "i2")
        raw["counts"] = {m.value: [n, n + 20] for n, m in enumerate(C.Metric)}
        raw["real_record"] = [{"agree": 3, "candidates": 4, "dropped_not_in_live": 5},
                              {"agree": 0, "candidates": 7, "dropped_not_in_live": 1}]
        baseline = L.baseline_from("inkling", 2, raw)
        self.assertEqual(baseline.real_record, (C.RealRecord(3, 4, 5), C.RealRecord(0, 7, 1)))
        self.assertEqual(baseline.counts[C.Metric.STALE_RECALL], C.Count(3, 23))
        written = cast(Raw, json.loads(json.dumps(L.baseline_json(baseline))))
        self.assertEqual(written, raw)
        self.assertEqual(L.baseline_from("inkling", 2, written), baseline)

    def test_each_refusal(self) -> None:
        other = sha("another file")
        record_cases: list[object] = [dict(RECORD), 7, [dict(RECORD)], [dict(RECORD)] * 3,
                                      [dict(RECORD), dict(RECORD), 7],
                                      [dict(RECORD), RECORD | {"note": 1}], [dict(RECORD), {"agree": 1, "candidates": 2}],
                                      [dict(RECORD), RECORD | {"agree": -1}], [dict(RECORD), RECORD | {"agree": 3}],
                                      [dict(RECORD), RECORD | {"candidates": True}], [dict(RECORD), 7]]
        rows_cases: list[object] = [[sha("i1 synth")], [sha("i1 synth"), sha("i2 synth"), sha("i3 synth")], 7,
                                    {sha("i1 synth"): 1, sha("i2 synth"): 2},
                                    [sha("i1 synth"), sha("i2 synth").upper()], [sha("i1 synth"), sha("i2 synth")[:12]],
                                    [sha("i1 synth"), sha("i2 synth") + "0"], [sha("i1 synth"), 7]]
        no_names: list[object] = [None, 7, "", ["tinker"]]
        no_models: list[object] = [{}, [], 7, GONE]
        no_objects: list[object] = [[], 7, None]
        cases: dict[str, list[tuple[tuple[str, ...], object]]] = {
            "is not of schema": [(("schema",), "masc.tinker.librarian.prompt_lines.v1"), (("schema",), GONE)],
            "prompt_lines.json holds a key the comparison does not read: note": [(("note",), "x")],
            "the pass lines and the template of the baseline": [
                (("pass_lines_sha256",), PIN.upper()), (("baseline_template_sha256",), BASE_T[:12]),
                (("pass_lines_sha256",), GONE), (("baseline_template_sha256",), 7)],
            "does not pin by sha256 exactly": [
                (("files_sha256", L.COUNTS), GONE), (("files_sha256", "another.py"), other),
                (("files_sha256", "prompt_lines.py"), "abc"), (("files_sha256",), [other] * 3), (("files_sha256",), GONE)],
            "worse_sigmas is not a finite number": [
                (("worse_sigmas",), -2.5), (("worse_sigmas",), True), (("worse_sigmas",), "2.5"),
                (("worse_sigmas",), float("nan")), (("worse_sigmas",), float("inf")), (("worse_sigmas",), 10 ** 400),
                (("worse_sigmas",), GONE)],
            "better_sigmas is not a finite number": [(("better_sigmas",), -2)],
            "prompt_lines.json holds no model": [(("models",), value) for value in no_models],
            "inkling is not an object of a model's lines": [(("models", "inkling"), value) for value in no_objects],
            "inkling holds a key the comparison does not read: note": [(("models", "inkling", "note"), "x")],
            "inkling names no provider or no model": [
                (("models", "inkling", key), value) for key in ("provider", "model") for value in (*no_names, GONE)],
            "inkling takes no run": [(("models", "inkling", "runs"), value) for value in (0, -1, True, "2", 2.0, GONE)],
            "inkling holds no baseline": [(INKLING, GONE)],
            "the inkling baseline does not hold exactly": [
                (INKLING, []), ((*INKLING, "note"), "x"), ((*INKLING, "counts"), GONE), ((*INKLING, "model"), GONE)],
            "the inkling baseline does not name the provider and the model it was counted for": [
                ((*INKLING, key), value) for key in ("provider", "model") for value in no_names],
            "the pass lines, the template and the prompt_counts.py it was counted under": [
                ((*INKLING, "template_sha256"), BASE_T.upper()), ((*INKLING, "prompt_counts_sha256"), 12),
                ((*INKLING, "pass_lines_sha256"), PIN[:12])],
            "does not hold one count for each metric": [
                ((*INKLING, "counts", "drop_precision"), GONE), ((*INKLING, "counts", "another_rate"), [1, 2]),
                ((*INKLING, "counts"), [[1, 2]] * 7)],
            "does not count stale_drop_recall as hits within chances": [
                ((*INKLING, "counts", "stale_drop_recall"), value)
                for value in ([3], [1, 2, 3], [5, 4], [-1, 4], [True, 4], [1.0, 4], "1/4", 7, {"hits": 1, "chances": 4})],
            "an E-real record and the sha256 of each set's rows for each of its 2 runs": [
                *(((*INKLING, "real_record"), value) for value in record_cases),
                *(((*INKLING, "synth_rows_sha256"), value) for value in rows_cases),
                *(((*INKLING, "real_rows_sha256"), value) for value in rows_cases)],
            "the inkling baseline names the rows of one run twice": [
                ((*INKLING, "synth_rows_sha256"), [sha("i1 synth")] * 2),
                ((*INKLING, "real_rows_sha256"), [sha("i1 real"), sha("i2 synth")])],
            "the inkling baseline was counted under other pass lines": [
                ((*INKLING, "pass_lines_sha256"), other), ((*INKLING, "template_sha256"), OTHER_T),
                ((*INKLING, "prompt_counts_sha256"), other)],
            "the glm baseline was counted under other pass lines": [((*GLM, "template_sha256"), OTHER_T)],
            "better_from does not list, each once, models the file holds": [
                (("better_from",), value) for value in (["inkling", "another"], "inkling", {"inkling": False}, [],
                                                        ["inkling", "inkling"], [7], ["inkling", ""], GONE)],
        }
        for want, changes in cases.items():
            for path, value in changes:
                with self.subTest(want=want, path=path, value=value):
                    with self.assertRaises(SystemExit) as caught:
                        L.lines_of(changed(path, value))
                    self.assertIn(want, str(caught.exception))

    def test_a_file_that_is_no_object_is_refused(self) -> None:
        no_objects: list[object] = [[], "lines", 7, None]
        for raw in no_objects:
            with self.subTest(raw=raw):
                with self.assertRaises(SystemExit) as caught:
                    L.lines_of(raw)
                self.assertIn("is not of schema", str(caught.exception))

    def test_a_baseline_counted_for_another_provider_or_model_is_refused(self) -> None:
        # The baseline names the model its numbers are of: changing the model's entry after the pin,
        # or pasting one model's baseline under another, leaves the two apart.
        cases: dict[str, list[tuple[tuple[str, ...], object]]] = {
            "the inkling baseline was counted for another provider or model than inkling names": [
                (("models", "inkling", "model"), "a-later-model"), (("models", "inkling", "provider"), "glm"),
                ((*INKLING, "model"), "another-model"), ((*INKLING, "provider"), "glm")],
            "the glm baseline was counted for another provider or model than glm names": [
                (("models", "glm", "model"), "a-later-model"), (GLM, raw_baseline("g1"))],
        }
        for want, changes in cases.items():
            for path, value in changes:
                with self.subTest(want=want, path=path, value=value):
                    with self.assertRaises(SystemExit) as caught:
                        L.lines_of(changed(path, value))
                    self.assertIn(want, str(caught.exception))
        later = changed(("models", "glm", "model"), "a-later-model")
        cast(Raw, cast(Raw, later["models"])["glm"])["baseline"] = None
        self.assertEqual(L.lines_of(later).models["glm"], L.ModelLines("glm", "a-later-model", 1, None))

    def test_a_run_that_sent_two_models_stands_in_both_baselines(self) -> None:
        # `prompt_counts.measure` picks a model's rows from a folder that holds another target's too,
        # so the rows of one run may be named under two models, never twice under one.
        lines = L.lines_of(changed((*GLM, "synth_rows_sha256"), [sha("i1 synth")]))
        glm = lines.models["glm"].baseline
        assert glm is not None
        self.assertEqual(glm.synth_rows_sha256, (sha("i1 synth"),))

    def test_a_stale_baseline_is_refused_when_the_file_pins_something_else(self) -> None:
        for path in (("pass_lines_sha256",), ("baseline_template_sha256",), ("files_sha256", L.COUNTS)):
            with self.subTest(path=path):
                with self.assertRaises(SystemExit) as caught:
                    L.lines_of(changed(path, sha("a later pin")))
                self.assertIn("baseline was counted under other pass lines, another template or another "
                              "prompt_counts.py", str(caught.exception))
        for name in ("prompt_lines.py", "prompt_compare.py"):
            self.assertIsNotNone(L.lines_of(changed(("files_sha256", name), sha("a later pin"))).models["inkling"].baseline)

    def test_a_key_written_twice_in_one_object_is_refused(self) -> None:
        text = json.dumps(raw_lines())
        self.assertEqual(json.loads(text, object_pairs_hook=L.once), raw_lines())
        for once, twice in (('"better_sigmas": 2.0', '"better_sigmas": 2.0, "better_sigmas": 0.0'),
                            ('"runs": 1', '"runs": 1, "runs": 2'),
                            ('"dropped_not_in_live": 0}]', '"dropped_not_in_live": 0, "agree": 0}]')):
            with self.subTest(twice=twice):
                self.assertIn(once, text)
                with self.assertRaises(SystemExit) as caught:
                    json.loads(text.replace(once, twice), object_pairs_hook=L.once)
                self.assertIn("writes a key twice in one object", str(caught.exception))

    def test_a_model_the_file_does_not_hold_is_refused(self) -> None:
        lines = L.lines_of(raw_lines())
        self.assertIs(L.model_of(lines, "glm"), lines.models["glm"])
        with self.assertRaises(SystemExit) as caught:
            L.model_of(lines, "another")
        self.assertIn("names no model another", str(caught.exception))


class PinnedLinesTest(unittest.TestCase):
    """`pinned_lines` over the committed prompt_lines.json, as it is and with a baseline pinned for
    every model, and over copies of both changed in one place."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.committed = cast(Raw, json.loads(L.PROMPT_LINES.read_text(encoding="utf-8")))
        self.states = {"as committed": self.committed, "every baseline pinned": with_baselines(self.committed)}

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def read(self, text: str) -> L.Lines:
        """`pinned_lines` over a prompt_lines.json that holds `text`."""
        path = Path(self.tmp.name) / "prompt_lines.json"
        path.write_text(text, encoding="utf-8")
        with mock.patch.object(L, "PROMPT_LINES", path):
            return L.pinned_lines()

    def refusal_of(self, raw: Raw) -> str:
        with self.assertRaises(SystemExit) as caught:
            self.read(json.dumps(raw))
        return str(caught.exception)

    def test_the_committed_lines_pin_the_present_files_the_pass_lines_and_their_template(self) -> None:
        lines = L.pinned_lines()
        self.assertEqual(lines.files_sha256, {name: C.sha256_file(L.HERE / name) for name in L.PINNED_FILES})
        self.assertEqual(lines.pass_lines_sha256, C.sha256_file(V.PASS_LINES))
        self.assertEqual(lines.baseline_template_sha256,
                         cast(dict[str, str], V.load_pass_lines()["files_sha256"])["../../../config/prompts/librarian.md"])

    def test_the_lines_read_with_every_baseline_pinned(self) -> None:
        lines = self.read(json.dumps(self.states["every baseline pinned"]))
        self.assertEqual(set(lines.models), set(cast(Raw, self.committed["models"])))
        for name, model in lines.models.items():
            with self.subTest(name=name):
                assert model.baseline is not None
                self.assertEqual((model.baseline.provider, model.baseline.model, len(model.baseline.real_record)),
                                 (model.provider, model.model, model.runs))

    def test_a_file_changed_after_the_pin_is_refused_by_name(self) -> None:
        # The pin of a file stands for an earlier version of it. A baseline names the prompt_counts.py
        # it was counted with, so a pinned one moves with that file's pin and the two stay together.
        earlier = sha("an earlier version")
        for state, raw in self.states.items():
            for name in L.PINNED_FILES:
                with self.subTest(state=state, name=name):
                    files = cast(dict[str, str], raw["files_sha256"]) | {name: earlier}
                    under: Raw = {"prompt_counts_sha256": earlier} if name == L.COUNTS else {}
                    self.assertEqual(self.refusal_of(counted_under(raw | {"files_sha256": files}, under)),
                                     f"prompt_lines.json pins another version of {name}")

    def test_lines_fixed_under_other_pass_lines_are_refused(self) -> None:
        other = sha("other pass lines")
        for state, raw in self.states.items():
            with self.subTest(state=state):
                lines = counted_under(raw | {"pass_lines_sha256": other}, {"pass_lines_sha256": other})
                self.assertEqual(self.refusal_of(lines), "prompt_lines.json was fixed under other pass lines")

    def test_a_key_written_twice_is_refused(self) -> None:
        text = L.PROMPT_LINES.read_text(encoding="utf-8")
        once = '"worse_sigmas": 2.5,'
        self.assertEqual(text.count(once), 1)
        with self.assertRaises(SystemExit) as caught:
            self.read(text.replace(once, once + ' "worse_sigmas": 99,'))
        self.assertEqual(str(caught.exception), "prompt_lines.json writes a key twice in one object")


if __name__ == "__main__":
    unittest.main()
