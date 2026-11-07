# tinker-trainer (experimental)

This revision `0.1.0` package and its external post-training path are **experimental**. See the [integration guide](../../docs/guides/tinker-integration.md) for opt-in requirements, failure symptoms, examples and removal.

Derives post-training datasets (SFT `cross_entropy` and RLVR `importance_sampling` / `ppo` / `cispo` / `dro` / `gspo`), observes Tinker training runs, and gates sampler checkpoint promotion (`tinker://<run-id>:train:0/sampler_weights/<step>`) from MASC's verifiable domain signals.

## Ownership boundary

- **Worker (`addons/tinker-trainer/`)**: Runs network-isolated (`--network none`) without host API credentials. Joins supplied Keeper receipts (`keeper_receipt`), Task/Goal Verifier verdicts (`verifier_verdict`), Board Karma signals (`karma_event`), and host training receipts (`tinker_run`) into deterministic dataset bundles and checkpoint readiness projections.
- **Host runner (`scripts/tinker/tinker_runner.py`)**: Executes on the host where `TINKER_API_KEY` is configured (or in `--mode dry-run` offline), performs `forward_backward` + `optim_step` + `save_weights_for_sampler` against the Tinker API, and writes snapshot files consumed by this package.

## Observed records

- `keeper_receipt`: Keeper trajectory turn (`trajectory_id`, `keeper_id`, `prompt`, `completion`, `turn_role` in `exact_gate | keeper_turn | verifier_judge`, optional `reasoning`, `logprobs`, `effort` in `[0.0, 1.0)`).
- `verifier_verdict`: Task/Goal Verifier proof outcome (`Done`, `Record_proof_proven` -> `+1.0`; `Producer_must_act`, `Record_proof_refuted` -> `-1.0`; `Pending` -> `0.0`). A negative Verifier verdict is never overridden by positive Karma.
- `karma_event`: Board Karma signal (`trajectory_id`, integer `karma_delta`).
- `tinker_run`: Tinker training step receipt (`run_id`, `base_model`, `loss_fn`, `step`, `mean_loss`, `status`, optional `sampler_path`, `eval_pass_rate`, `baseline_pass_rate`).

## Published output ports and lanes

- `datasets` -> `["tinker/datasets"]`
- `runs` -> `["tinker/runs"]`
- `checkpoints` -> `["tinker/checkpoints", "tinker/readiness"]`
- `training` -> `["tinker/checkpoints", "tinker/datasets", "tinker/readiness", "tinker/runs"]`

## Actions (`lane_act`)

- `{"kind": "prepare_sft", "dataset_id": "<id>"}`: Filters verified positive trajectories (`reward > 0.0`) and formats Inkling `<thinking effort=XX>` SFT datums.
- `{"kind": "prepare_rlvr", "dataset_id": "<id>", "loss_fn": "cispo" | "ppo" | "importance_sampling" | "dro" | "gspo"}`: Builds RLVR datums with verifiable rewards (`+1.0` / `-1.0`) and centered advantages.
- `{"kind": "register_checkpoint", "checkpoint_id": "<id>", "run_id": "<run>", "sampler_path": "tinker://...", "step": 10, "eval_pass_rate": 0.85, "baseline_pass_rate": 0.75}`: Registers a sampler checkpoint and computes `promote_ready` / `insufficient_gain` / `regressed` / `unverified` readiness against `binding.min_eval_gain`.
- `{"kind": "export_bundle", "dataset_id": "<id>"}`: Exports a prepared dataset as a retained `application/x-ndjson` artifact with SHA-256 digest.
