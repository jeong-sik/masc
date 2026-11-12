# /// script
# requires-python = ">=3.12"
# dependencies = ["openai==3.46.0", "tinker==0.39.0", "tinker-cookbook==0.6.1", "tml-renderers==0.4.1", "torch>=2.10"]
# ///
# pyright: strict
"""Tests for the training run of the LoRA candidate (scripts/tinker/librarian/train_sft.py): an
example as the model reads it, the one pass the run sends, the files it leaves, and where it stops.

`main` runs over a teacher folder of `tinker_librarian_teacher_fixtures.py` with the renderer and
the tokenizer the run uses, which read no network, and with a training client that records what it
is asked and sends nothing. The file imports the training packages, so it runs with `uv run`.
"""

from __future__ import annotations

import contextlib
import io
import json
import math
import sys
import tempfile
import unittest
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import ClassVar, NoReturn, Protocol, cast
from unittest import mock

import tinker
from tinker_cookbook import model_info
from tinker_cookbook.tokenizer_utils import get_tokenizer

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tinker" / "librarian"))

import eval_admission as V
import sft_examples as X
import teacher_sample as T
import train_sft as TS
from tinker_librarian_teacher_fixtures import TrainFolder, train_folder

type JsonObject = dict[str, object]

SAMPLER_PATH, STATE_PATH = "tinker://run-of-the-test/sampler_weights/a", "tinker://run-of-the-test/weights/a-state"
DAY_S = 86400


@dataclass(frozen=True, slots=True)
class Done[R]:
    """A call the fake client took: `result` gives what the service would answer."""

    answer: Callable[[], R]

    def result(self) -> R:
        return self.answer()


@dataclass(frozen=True, slots=True)
class Loss:
    loss_fn_outputs: list[dict[str, tinker.TensorData]]


@dataclass(frozen=True, slots=True)
class Saved:
    path: str


def service_failure() -> NoReturn:
    raise RuntimeError("the service failed")


def read_json(path: Path) -> JsonObject:
    return cast(JsonObject, json.loads(path.read_text(encoding="utf-8")))


class Trainer:
    """A training client that records what the run asks of it and sends nothing. Every token of the
    n-th step gets the log-probability -n, so that step's mean loss is n. `fails_at` names the call
    whose result raises: "forward_backward" (the second step's) or "save_state"."""

    def __init__(self, out: Path, fails_at: str | None = None) -> None:
        self.out, self.fails_at = out, fails_at
        self.asked: list[str] = []
        self.batches: list[list[tinker.Datum]] = []
        self.loss_fns: list[str] = []
        self.adam: list[tuple[float, float, float, float]] = []
        self.saved: list[tuple[str, str, int]] = []
        self.summary_at_state: JsonObject | None = None

    def forward_backward(self, data: list[tinker.Datum], loss_fn: str) -> Done[Loss]:
        self.asked.append("forward_backward")
        self.batches.append(list(data))
        self.loss_fns.append(loss_fn)
        if self.fails_at == "forward_backward" and len(self.batches) == 2:
            return Done(service_failure)
        level = -float(len(self.batches))
        sizes = [len(d.loss_fn_inputs["weights"].data) for d in data]
        loss = Loss([{"logprobs": tinker.TensorData(data=[level] * n, dtype="float32", shape=[n])} for n in sizes])
        return Done(lambda: loss)

    def optim_step(self, *, adam_params: tinker.AdamParams) -> Done[None]:
        self.asked.append("optim_step")
        self.adam.append((adam_params.learning_rate, adam_params.beta1, adam_params.beta2, adam_params.eps))
        return Done(lambda: None)

    def save_weights_for_sampler(self, name: str, ttl_seconds: int) -> Done[Saved]:
        self.asked.append("save_weights_for_sampler")
        self.saved.append(("save_weights_for_sampler", name, ttl_seconds))
        return Done(lambda: Saved(SAMPLER_PATH))

    def save_state(self, name: str, ttl_seconds: int) -> Done[Saved]:
        self.asked.append("save_state")
        self.saved.append(("save_state", name, ttl_seconds))
        summary = self.out / "summary.json"
        self.summary_at_state = read_json(summary) if summary.exists() else None
        return Done(service_failure) if self.fails_at == "save_state" else Done(lambda: Saved(STATE_PATH))


class Service:
    """Stands where `tinker.ServiceClient()` does and hands out the one trainer."""

    def __init__(self, trainer: Trainer) -> None:
        self.trainer = trainer
        self.created: list[JsonObject] = []

    def create_lora_training_client(self, **asked: object) -> Done[Trainer]:
        self.created.append(asked)
        return Done(lambda: self.trainer)


def run_main(made: TrainFolder, out: Path, trainer: Trainer, *flags: str, budget: float = 70.0) -> tuple[int, Service]:
    """`train_sft.py` over the folder with the fake client in the service's place: its exit code,
    and the service with what was asked of it."""
    service = Service(trainer)
    argv = ["train_sft.py", "--requests", str(made.requests), "--teacher", str(made.teacher), "--out", str(out),
            "--budget", repr(budget), *flags]
    with (mock.patch.object(sys, "argv", argv), mock.patch.object(tinker, "ServiceClient", lambda: service),
          contextlib.redirect_stdout(io.StringIO())):
        return TS.main(), service


def answer_part(example: X.Example) -> str:
    """The answer as the model is trained to write it: a model message that starts its text at once."""
    return f"<|message_model|><|content_text|>{example.answer}<|end_message|><|content_model_end_sampling|>"


def conversation(example: X.Example, effort: str) -> str:
    """An example as the model reads it: the effort, the request and the schema instruction from
    the user, and the answer."""
    return (f"<|message_system|><|content_text|>Thinking effort level: {effort}<|end_message|>"
            f"<|message_user|><|content_text|>{example.request}<|end_message|>"
            f"<|message_user|><|content_text|>{V.schema_instruction()}<|end_message|>" + answer_part(example))


class Decoder(Protocol):
    """What these tests ask of the run's tokenizer."""

    def decode(self, token_ids: list[int]) -> str | list[str]: ...


def read_back(decoder: Decoder, tokens: list[int]) -> str:
    text = decoder.decode(tokens)
    assert isinstance(text, str)
    return text


def text_of(tokens: list[int]) -> str:
    """The tokens as the run's tokenizer reads them back, special tokens included."""
    return read_back(get_tokenizer(TS.MODEL), tokens)


def tokens_of(datum: tinker.Datum) -> list[int]:
    """Every token of an example: a datum's input holds all but the last, its targets all but the first."""
    return [*datum.model_input.to_ints(), cast(list[int], datum.loss_fn_inputs["target_tokens"].data)[-1]]


def sent(plan: X.Plan, trainer: Trainer) -> Iterator[tuple[X.Example, tinker.Datum]]:
    """Each datum the trainer was sent, with the example the plan puts at its place."""
    for step, batch in zip(plan.steps, trainer.batches, strict=True):
        for position, datum in zip(step, batch, strict=True):
            yield plan.examples[position], datum


class TrainRunTest(unittest.TestCase):
    """One run over the fixture's folder to its end: six examples in two steps."""

    made: ClassVar[TrainFolder]
    out: ClassVar[Path]
    trainer: ClassVar[Trainer]
    service: ClassVar[Service]
    code: ClassVar[int]
    plan: ClassVar[X.Plan]

    @classmethod
    def setUpClass(cls) -> None:
        folder = Path(cls.enterClassContext(tempfile.TemporaryDirectory()))
        cls.made = train_folder(folder)
        cls.out = folder / "train"
        cls.trainer = Trainer(cls.out)
        cls.code, cls.service = run_main(cls.made, cls.out, cls.trainer)
        cls.plan = X.plan(cls.made.requests, cls.made.teacher)

    def test_the_run_trains_a_lora_of_the_rank_on_the_teachers_model(self) -> None:
        self.assertEqual(self.code, 0)
        self.assertEqual(self.service.created, [{"base_model": T.TEACHER, "rank": 8, "seed": X.SEED}])

    def test_an_example_is_the_request_the_instruction_and_the_answer_at_the_teachers_effort(self) -> None:
        for example, datum in sent(self.plan, self.trainer):
            with self.subTest(item=example.item_id):
                self.assertEqual(text_of(tokens_of(datum)), conversation(example, "0.2"))

    def test_the_loss_is_on_the_answer_alone_and_each_example_weighs_the_same(self) -> None:
        for example, datum in sent(self.plan, self.trainer):
            with self.subTest(item=example.item_id):
                weights = cast(list[float], datum.loss_fn_inputs["weights"].data)
                targets = cast(list[int], datum.loss_fn_inputs["target_tokens"].data)
                self.assertEqual(text_of([t for t, w in zip(targets, weights, strict=True) if w > 0]),
                                 answer_part(example))
                self.assertAlmostEqual(sum(weights), 1.0, places=5)

    def test_every_example_is_sent_once_and_each_step_is_followed_by_one_optimizer_step(self) -> None:
        self.assertEqual([len(batch) for batch in self.trainer.batches], [4, 2])
        self.assertEqual(sorted(example.item_id for example, _ in sent(self.plan, self.trainer)),
                         [example.item_id for example in self.plan.examples])
        self.assertEqual(self.trainer.asked, ["forward_backward", "optim_step"] * 2
                         + ["save_weights_for_sampler", "save_state"])
        self.assertEqual((self.trainer.loss_fns, self.trainer.adam),
                         (["cross_entropy"] * 2, [(2e-4, 0.9, 0.95, 1e-8)] * 2))

    def test_the_step_log_holds_each_steps_examples_tokens_loss_and_cost(self) -> None:
        rows = [cast(JsonObject, json.loads(line))
                for line in (self.out / "steps.jsonl").read_text(encoding="utf-8").splitlines()]
        first, second = (sum(d.model_input.length for d in batch) for batch in self.trainer.batches)
        cost = first * 3.0 / 1e6
        self.assertEqual([{name: value for name, value in row.items() if name != "wall_s"} for row in rows], [
            {"step": 0, "examples": 4, "tokens": first, "train_mean_nll": 1.0, "spent_usd": round(cost, 4)},
            {"step": 1, "examples": 2, "tokens": second, "train_mean_nll": 2.0,
             "spent_usd": round(cost + second * 3.0 / 1e6, 4)}])
        self.assertTrue(all(isinstance(row["wall_s"], float) and row["wall_s"] >= 0 for row in rows))

    def test_the_config_records_what_is_trained_on_and_the_code_and_packages_that_train(self) -> None:
        lengths = sorted(d.model_input.length for batch in self.trainer.batches for d in batch)
        here = Path(TS.__file__).resolve().parent
        self.assertEqual(read_json(self.out / "config.json"), {
            "model": T.TEACHER, "candidate": "A", "examples": 6, "effort": 0.2, "rank": 8, "learning_rate": 2e-4,
            "batch": 4, "steps": 2, "seed": X.SEED,
            "tokens": {"total": sum(lengths), "p50": lengths[3], "max": lengths[-1]},
            "estimate_usd": round(sum(lengths) * 3.0 / 1e6, 2), "budget_usd": 70.0,
            "pass_lines_sha256": V.sha256_file(V.PASS_LINES), "teacher": self.plan.teacher,
            "code_sha256": {name: V.sha256_file(here / name)
                            for name in ("train_sft.py", "sft_examples.py", "teacher_sample.py")},
            "packages": {"tinker": "0.39.0", "tinker-cookbook": "0.6.1", "tml-renderers": "0.4.1"}})

    def test_the_summary_ties_the_candidate_to_its_checkpoint_under_the_pass_lines(self) -> None:
        summary = read_json(self.out / "summary.json")
        spent = sum(d.model_input.length for d in self.trainer.batches[0]) * 3.0 / 1e6
        spent += sum(d.model_input.length for d in self.trainer.batches[1]) * 3.0 / 1e6
        self.assertEqual(summary, {**read_json(self.out / "config.json"), "sampler_path": SAMPLER_PATH,
                                   "checkpoint_ttl_s": 30 * DAY_S, "spent_usd": round(spent, 4)})
        targets = {"base": T.TEACHER, "A": SAMPLER_PATH}
        self.assertIsNone(V.binding_problem(targets, targets, "base", T.TEACHER, ["A"], {"A": summary},
                                            V.sha256_file(V.PASS_LINES)))

    def test_the_weights_are_saved_for_sampling_and_then_with_the_optimizer_state(self) -> None:
        self.assertEqual(self.trainer.saved, [
            ("save_weights_for_sampler", "masc-librarian-admission-A", 30 * DAY_S),
            ("save_state", "masc-librarian-admission-A-state", 7 * DAY_S)])
        self.assertEqual(read_json(self.out / "state.json"), {"state_path": STATE_PATH, "ttl_s": 7 * DAY_S})
        # The summary the verdict reads was on disk before the state was asked for.
        self.assertEqual(self.trainer.summary_at_state, read_json(self.out / "summary.json"))


class TrainStopTest(unittest.TestCase):
    """Runs that stop before the end, each with its own --out over one folder of the fixture."""

    made: ClassVar[TrainFolder]

    @classmethod
    def setUpClass(cls) -> None:
        cls.made = train_folder(Path(cls.enterClassContext(tempfile.TemporaryDirectory())))

    def setUp(self) -> None:
        self.out = Path(self.enterContext(tempfile.TemporaryDirectory())) / "train"
        self.trainer = Trainer(self.out)

    def files(self) -> list[str]:
        return sorted(path.name for path in self.out.iterdir())

    def test_a_dry_run_writes_the_config_and_asks_for_no_training_client(self) -> None:
        code, service = run_main(self.made, self.out, self.trainer, "--dry-run")
        self.assertEqual((code, service.created, self.trainer.asked, self.files()), (0, [], [], ["config.json"]))

    def test_an_estimate_above_the_budget_stops_the_run_before_training(self) -> None:
        run_main(self.made, self.out, self.trainer, "--dry-run")
        tokens = cast(JsonObject, read_json(self.out / "config.json")["tokens"])
        estimate = cast(int, tokens["total"]) * 3.0 / 1e6
        code, service = run_main(self.made, self.out, self.trainer, budget=math.nextafter(estimate, 0.0))
        self.assertEqual((code, service.created, self.trainer.asked, self.files()), (2, [], [], ["config.json"]))
        code, service = run_main(self.made, self.out, self.trainer, budget=estimate)
        self.assertEqual((code, len(service.created), len(self.trainer.batches)), (0, 1, 2))

    def test_a_failure_during_the_pass_leaves_no_checkpoint(self) -> None:
        trainer = Trainer(self.out, fails_at="forward_backward")
        with self.assertRaisesRegex(RuntimeError, "the service failed"):
            run_main(self.made, self.out, trainer)
        self.assertEqual((trainer.saved, self.files()), ([], ["config.json", "steps.jsonl"]))
        self.assertEqual(len((self.out / "steps.jsonl").read_text(encoding="utf-8").splitlines()), 1)

    def test_the_summary_outlives_a_failure_to_save_the_optimizer_state(self) -> None:
        trainer = Trainer(self.out, fails_at="save_state")
        with self.assertRaisesRegex(RuntimeError, "the service failed"):
            run_main(self.made, self.out, trainer)
        self.assertEqual(self.files(), ["config.json", "steps.jsonl", "summary.json"])
        self.assertEqual(read_json(self.out / "summary.json")["sampler_path"], SAMPLER_PATH)
        self.assertEqual(trainer.summary_at_state, read_json(self.out / "summary.json"))

    def test_pass_lines_with_other_bytes_than_the_fixed_ones_are_refused(self) -> None:
        other = self.out.parent / "pass_lines.json"
        other.write_bytes(V.PASS_LINES.read_bytes() + b"\n")
        with (mock.patch.object(TS, "PASS_LINES", other),
              self.assertRaisesRegex(SystemExit, "pass_lines.json is not the fixed one")):
            run_main(self.made, self.out, self.trainer)
        self.assertFalse(self.out.exists())

    def test_a_candidate_the_pass_lines_do_not_name_is_not_trained(self) -> None:
        with (mock.patch.object(TS, "CANDIDATE", "B"),
              self.assertRaisesRegex(SystemExit, "choice.order does not name B")):
            run_main(self.made, self.out, self.trainer)
        self.assertFalse(self.out.exists())

    def test_a_model_another_renderer_renders_is_refused(self) -> None:
        with (mock.patch.object(model_info, "get_recommended_renderer_name", return_value="role_colon"),
              self.assertRaisesRegex(SystemExit, "renders with role_colon; only tml_v0 takes the reasoning effort")):
            run_main(self.made, self.out, self.trainer)
        self.assertEqual(self.trainer.asked, [])


class TrainEffortTest(unittest.TestCase):
    def test_the_examples_are_rendered_at_the_effort_the_teachers_calls_are_keyed_with(self) -> None:
        other = {**V.load_pass_lines(), "request": {"reasoning_effort": "medium", "max_tokens": 4096}}
        folder = Path(self.enterContext(tempfile.TemporaryDirectory()))
        # `sample` and the plan read the pass lines' request settings through `eval_admission`.
        with mock.patch.object(V, "load_pass_lines", return_value=other):
            made = train_folder(folder)
            trainer = Trainer(folder / "train")
            run_main(made, folder / "train", trainer)
            plan = X.plan(made.requests, made.teacher)
        example, datum = next(sent(plan, trainer))
        self.assertEqual(text_of(tokens_of(datum)), conversation(example, "0.7"))
        self.assertEqual(read_json(folder / "train" / "config.json")["effort"], 0.7)


if __name__ == "__main__":
    unittest.main()
