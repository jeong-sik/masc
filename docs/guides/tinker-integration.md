# Thinking Machines Tinker & Inkling Integration Guide (experimental)

This integration is **experimental**. The provider template and the `tinker-trainer` add-on at revision `0.1.0` are opt-in. Live inference and training depend on an external service, and `--mode train` creates remote training state and can incur charges. Offline tests and dry-runs do not establish live-service compatibility or checkpoint quality.

MASC integrates with **Thinking Machines Lab's Tinker API** (`https://tinker-docs.thinkingmachines.ai/tinker/`) and the **Inkling** model family (`thinkingmachines/Inkling-2-Small`, `thinkingmachines/Inkling`, `Qwen/Qwen3.8-27B`, `zai-org/GLM-5.3-Flash:peft:262144`) using **loose coupling**:

1. **Inference (`packages/agent_core/models.toml` + `config/runtime.toml`)**: The AGENT_CORE catalog has the `tinker` provider row and the `thinkingmachines/Inkling-2-Small` model row. `runtime.toml` binds them over the existing `openai-compatible-http` protocol. No OCaml code changes.
2. **Dataset Derivation & Checkpoint Gate (`addons/tinker-trainer/`)**: Runs as a network-isolated MASC Lane Add-on (`--network none`) that joins Keeper execution receipts, Task/Goal Verifier verdicts, and Board Karma into SFT/RLVR datasets and gates checkpoint promotion.
3. **Host-side Post-Training Runner (`scripts/tinker/tinker_runner.py`)**: Executes shifted-token `forward_backward`, `optim_step`, `save_weights_for_sampler`, and optional `save_state` calls on the host when `TINKER_API_KEY` is present, or runs in `--mode dry-run` offline.

---

## 1. Enabling Tinker & Inkling Inference in `runtime.toml`

The catalog row is the only place the model's facts are written: its window, its reasoning ladder, and what the endpoint does with `response_format`, tool choice and images. `config/runtime.toml` includes a ready-to-uncomment binding for `[providers.tinker]` and `[models.tinker-inkling-2-small]` that states none of those facts. `test_tinker_template_binds_the_catalog_row` in `test/test_runtime_config_validity.ml` checks that the binding resolves to the catalog row.

### Step 1: Set `TINKER_API_KEY`

Set the key in the environment of the MASC server process, through its service manager or the shell that starts it. Exporting it in another terminal does not update an already running server. The TOML stores only the variable name; do not paste the key into configuration or commit it.

```bash
export TINKER_API_KEY="tml-..."
```

### Step 2: Enable `[providers.tinker]` and the Inkling binding in `<resolved-config-root>/runtime.toml`

```toml
[providers.tinker]
display-name = "Thinking Machines Tinker"
protocol = "openai-compatible-http"
endpoint = "https://tinker.thinkingmachines.dev/services/tinker-prod/oai/api/v1"
connect-timeout-s = 1200.0
exact-body-timeout-s = 1200.0

[providers.tinker.credentials]
type = "env"
key = "TINKER_API_KEY"

[providers.tinker.healthcheck]
path = "/models"

[models.tinker-inkling-2-small]
api-name = "thinkingmachines/Inkling-2-Small"
tools-support = true
thinking-support = true
streaming = true
reasoning-effort = "high"

[tinker.tinker-inkling-2-small]
max-concurrent = 4
```

Do not add a `[models.tinker-inkling-2-small.capabilities]` block that copies the row. A runtime `accepted-reasoning-efforts` replaces the catalog ladder, so a copied ladder that lists `none` brings back the value the row leaves out.

The row declares the following. The behaviour was measured on 2026-11-07 (`docs/research/2026-11-07-tinker-inkling-exact-lane-feasibility.md`).

| Fact | Row | What a request sees |
| --- | --- | --- |
| Window | 65,536 tokens, prompt plus `max_tokens` | MASC sends an exact-output request to this row without counting its tokens. The pre-dispatch window check runs only for a row with a `serving_constraint`, and this row has none. The endpoint answers an overflow with HTTP 400 and `{"detail": ...}`, and the exact walk moves to the next slot. The 256K window belongs to the separate ID `thinkingmachines/Inkling-2-Small:peft:262144`, which has no catalog row. |
| Reasoning ladder | `minimal`, `low`, `medium`, `high`, `xhigh` | `none` is refused before dispatch. The endpoint accepts it, but the model still reasoned on long prompts. An omitted effort means 0.9. Reasoning arrives on `reasoning_content` and is billed as completion tokens. |
| `response_format` | Neither JSON mode nor native schema | The endpoint answers 200 to `json_schema` and `json_object` and applies neither. A provider-schema request is refused before dispatch. |
| Tool choice | Tool calls, `required`, parallel calls | A named `tool_choice` is refused before dispatch, because it is neither documented nor measured. |
| Image input | Not declared | An image is replaced by a text block naming what was dropped. The model page lists vision, but the OpenAI-compatible page documents no image input. |

### Step 3: Select the slot and restart MASC

The example creates the slot ID `tinker.tinker-inkling-2-small`. Select it in the target Keeper or lane configuration; adding the tables does not replace existing selections. The runtime catalog is loaded at process startup, so restart the MASC server after editing `runtime.toml`. A running server does not hot-reload the new provider, model or checkpoint row.

### Using Inkling-2-Small on an exact-output lane

An exact-output slot binds to a catalog provider row, and to the model's catalog row or, for a model the catalog has no row for, the capabilities its binding declares. `tinker.tinker-inkling-2-small` binds to its row. A `tinker://` checkpoint is a slot when its model table carries a capabilities block (next section); without one it is left out as `Target_not_in_catalog`. Every exact-output lane MASC ships asks for JSON syntax: the schema travels in the prompt, and MASC parses and validates the reply before accepting it. The missing structured output does not keep the row off these lanes.

Append `"tinker.tinker-inkling-2-small"` to the lane's `slots` list, such as `[runtime.exact_output_lanes.<lane>]` or `[runtime.addon_exact_lanes.<addon>.<output>]`, and restart. An exact lane sends the binding's `reasoning-effort`. In the 2026-11-07 replays at `low`, 17 of 17 librarian replies were valid both with `json_schema` on the request and with the schema carried in the prompt, which is what MASC sends to this row. Reasoning counts against the output budget: the largest of those replies used 3,172 output tokens. A lane without `max_output_tokens` sends no `max_tokens`, so the binding `max-tokens` never reaches an exact request and Tinker applies its own default of 4,096 (seen in a live 400 on 2026-11-08). The 3,172-token reply fits under that default too. Board agreement stayed below its pass line at every effort tried.

### Hot-Swapping a Fine-Tuned Checkpoint (`tinker://...`)

When `save_weights_for_sampler` produces a checkpoint URI, bind it as a new model row without deploying a separate inference server. A `tinker://` URI has no catalog row, so only the `openai_chat` preset of the `tinker` provider row answers for it, and that preset claims structured output and no reasoning. The model table's `max-context`, `tools-support`, `streaming` and `thinking-support` and every key of its capabilities block override the preset; an unwritten `tools-support` or `streaming` still overrides it, as `false` and `true`. An unstated capabilities key keeps the preset's value, except media input, which stays off. The same block makes the checkpoint an exact-output slot. The block below copies what the `thinkingmachines/Inkling-2-Small` row declares; a checkpoint's own behaviour was not measured. Declare the window of the base the run trained on: 65,536 for `thinkingmachines/Inkling-2-Small`, 262,144 for `thinkingmachines/Inkling-2-Small:peft:262144`. Restart MASC to load the row:

```toml
[models.tinker-inkling-ckpt]
api-name = "tinker://<run-id>:train:0/sampler_weights/<step>"
max-context = 65536
tools-support = true
thinking-support = true
streaming = true
reasoning-effort = "high"

[models.tinker-inkling-ckpt.capabilities]
thinking-control-format = "reasoning-effort-default-on"
accepted-reasoning-efforts = ["minimal", "low", "medium", "high", "xhigh"]
reasoning-streaming-format = "delta:reasoning_content"
supports-tool-choice = true
supports-required-tool-choice = true
supports-parallel-tool-calls = true
supports-named-tool-choice = false
supports-response-format-json = false
supports-structured-output = false
supports-image-input = false
supports-multimodal-inputs = false

[tinker.tinker-inkling-ckpt]
max-concurrent = 4
```

A `tinker://` model still uses `[providers.tinker]`, its credential and an account with access to that checkpoint. Detaching the dataset add-on does not remove or disable this model row.

### Activation requirements and failure symptoms

- Inference requires the complete provider, credential, model and `[tinker.<model>]` tables, a selected slot, a restarted server, network access and a non-empty valid key in the server environment. `[providers.tinker.healthcheck] path = "/models"` is retained for install/setup probes; server startup does **not** call it for admission.
- An unset or blank `TINKER_API_KEY` is refused before request dispatch with `Required provider credential is unavailable`. A rejected key or an account without model/checkpoint access fails on the actual inference call, or on an explicitly run `/models` setup probe, with the upstream authentication response (normally HTTP 401 or 403). Do not interpret successful TOML loading or server startup as live authentication proof.
- `python3 scripts/tinker/tinker_runner.py --mode preflight` reports only local `tinker_api_key_present` and `tinker_sdk_installed` booleans; it does not contact Tinker or validate the key. `--mode train` stops with `TinkerRunnerError: TINKER_API_KEY environment variable is required for --mode train` when the key is absent, and `TinkerRunnerError: The 'tinker' Python SDK is not installed. Run: pip install tinker` when the SDK is absent.

---

## 2. Installing the `tinker-trainer` Lane Add-on

1. Build the worker container image from the repository root:
   ```bash
   docker build -f addons/tinker-trainer/Dockerfile -t masc-lane-tinker-trainer:0.1.0 addons
   ```
2. Copy `docs/examples/lane-addons/tinker-trainer.toml` into `<resolved-config-root>/lane-addons/tinker-trainer.toml`. Keep `enabled = true` while installing it. Adjust `manifest_path` and `binding.sources[].path` for the actual checkout and config root: both relative paths resolve from the **declaration directory**, not the repository or server working directory. The example values assume the checkout is `<base-path>` and the default `<base-path>/.masc/config` root.
3. Create the input snapshot with the offline dry-run in §4, or provide a real runner snapshot at the configured path. Its `source_id` must be `tinker-snapshot`, matching the declaration.
4. After the next configuration reconciliation and observation, inspect the projected lanes in TUI (`/addons`) or the Dashboard:
   - `tinker/datasets`: Observed corpus and prepared SFT (`cross_entropy`) / RLVR (`cispo`, `ppo`, `importance_sampling`, `dro`, `gspo`, `stable_reinforce`) bundles.
   - `tinker/runs`: Step-by-step training loss, optimizer (`adamw` | `dimuon`), and status (`dry_run`, `running`, `completed`, `failed`).
   - `tinker/checkpoints`: Saved `tinker://.../sampler_weights/<step>` URIs and evaluation scores.
   - `tinker/readiness`: Promotion gate comparing `eval_pass_rate - baseline_pass_rate` against `binding.min_eval_gain`.

### Activation requirements and failure symptoms

The exact image `masc-lane-tinker-trainer:0.1.0` must already be available to the server's Docker runtime; saving a declaration never builds or pulls it. The declaration and binding must validate, the snapshot must be readable, and a worker must complete an observation before the lanes contain current results. The network-isolated worker does not need `TINKER_API_KEY`; only the host runner does.

- A missing or unreadable image leaves the instance in `phase.kind = "failed"` with an `Add-on Docker image inspect failed: ...` message. Build the exact tag, then read the instance again.
- A bad `manifest_path`, unknown field or invalid binding appears in `configuration.issues` with the declaration source path and reason. `desired_revision`, `applied_revision` and worker `phase` remain distinct; an invalid edit does not silently disable or replace the last valid installation.
- A missing, unreadable or malformed snapshot, or a snapshot whose `source_id` differs from the binding, fails the observation with the read/identity error. Inspect the worker's Installation detail and Links/Source coverage. A declaration alone is not evidence of a completed observation or fresh lane rows.

### `lane_act` example and expected readiness

First read `masc_lane_inspect` and copy the active instance's exact `instance_id`, `incarnation` and advertised `action_schema`. With the example binding (`min_eval_gain = 0.05`), submit this object through the generic `masc_lane_act` tool. In the TUI Add-on screen, open `A` and enter the same object after `act`:

```json
{
  "instance_id": "<ID>",
  "expected_incarnation": "<ID>",
  "request_id": "tinker-ckpt-run-01-000020",
  "action": {
    "kind": "register_checkpoint",
    "checkpoint_id": "ckpt-run-01-000020",
    "run_id": "run-01",
    "sampler_path": "tinker://run-01:train:0/sampler_weights/000020",
    "step": 20,
    "eval_pass_rate": 0.88,
    "baseline_pass_rate": 0.78
  }
}
```

The initial durable receipt normally has `state = "queued"`. Read it with `masc_lane_action_status` using the same `instance_id` and `request_id`; do not create a new request ID to retry an unknown outcome. Once the package confirms, the essential receipt fields are:

```json
{
  "state": "confirmed",
  "result": {
    "request_id": "tinker-ckpt-run-01-000020",
    "action": "register_checkpoint",
    "checkpoint_id": "ckpt-run-01-000020",
    "sampler_path": "tinker://run-01:train:0/sampler_weights/000020",
    "verdict": "promote_ready",
    "eval_gain": 0.1
  }
}
```

The committed output also projects a `tinker/readiness` row with `verdict = "promote_ready"`, `eval_gain = 0.1`, `min_eval_gain = 0.05` and `runtime_api_name` equal to the sampler URI. `promote_ready` requires both rates, `eval_pass_rate >= baseline_pass_rate`, and `eval_pass_rate - baseline_pass_rate >= binding.min_eval_gain`. A lower evaluation is `regressed`, a smaller non-negative gain is `insufficient_gain`, and a missing rate is `unverified`. Registration computes this local gate; it does not independently verify the URI or evaluation.

The scores above are illustrative. In particular, the runner's dry-run defaults are synthetic values, not a measured evaluation or evidence that a checkpoint should be promoted.

---

## 3. Tinker Architecture & Post-Training Best Practices

### 3.1 Shifted Datum & Exact `loss_fn_inputs` Tensor Keys

Every `Datum` submitted to `forward_backward` uses next-token prediction shifted by 1 (`N = P + C - 1`):
- `model_input`: `full_sequence[:-1]`
- `target_tokens` (`int64[N]`): `full_sequence[1:]`

Tinker enforces exact `loss_fn_inputs` keys per loss function (extra keys are rejected by the server):

| Loss Function | Required `loss_fn_inputs` Keys | Notes & Use Case |
| --- | --- | --- |
| `cross_entropy` | `target_tokens`, `weights` | Supervised Fine-Tuning (SFT). `weights = [0.0]*(P-1) + [1.0]*C` masks prompt tokens. |
| `cispo` | `target_tokens`, `logprobs`, `advantages` | Clipped Importance Sampling Policy Optimization. Clips importance ratio as a detached weight (`clip_low_threshold=0.0`, `clip_high_threshold=4.0`), never zeroing token gradients. Default for MASC async RLVR. |
| `ppo` | `target_tokens`, `logprobs`, `advantages` | Standard clipped surrogate objective (`clip_low_threshold=0.8`, `clip_high_threshold=1.2`). |
| `importance_sampling` | `target_tokens`, `logprobs`, `advantages` | Unclipped importance-weighted REINFORCE. |
| `dro` | `target_tokens`, `logprobs`, `advantages` | Direct Reward Optimization with quadratic log-ratio penalty (`beta=0.05`). |
| `gspo` | `target_tokens`, `logprobs`, `advantages`, `sequence_ratio_mask` | Group Sequence Policy Optimization. Uses geometric mean of token ratios across `sequence_ratio_mask` (`1.0` on completion tokens). Recommended for long multi-turn trajectories. |
| `stable_reinforce` | `target_tokens`, `logprobs`, `advantages` | Provenance-verified bit-deterministic REINFORCE (requires sampling from `SamplingClient` with matching provenance). |

### 3.2 Optimizers (`AdamW` vs `Dimuon`) & Learning Rate Scaling

- **`adamw`** (`types.AdamOptimizerConfig()`, `types.AdamParams(learning_rate=1e-4)`): Standard default optimizer.
- **`dimuon`** (`types.DimuonOptimizerConfig()`, `types.DimuonParams(learning_rate=1e-3)`): Thinking Machines Lab's LoRA optimizer. Recommended for SFT and RL-after-SFT; requires **10–100× larger LR** than AdamW (~15× for SFT, ~60× for RL) and exhibits stronger LoRA rank invariance.
- **Scaling & Schedule**: Scale LR as `sqrt(batch_size)` in SFT (`sqrt(num_problems)` in RL) and decay linearly to `0.0` at the end of training (~1.3× step efficiency).

### 3.3 1-Clock-Cycle Pipelining & Anti-Timeout Rule

- Tinker executes queued operations in worker-pool clock cycles (~5–10s per cycle). Always submit `forward_backward` and `optim_step` **before** awaiting `.result()` on either so both execute in **1 clock cycle** instead of 3.
- **Never** wrap Tinker API calls in client-side timeouts (`asyncio.wait_for`) or manual retry loops; Tinker is throughput-optimized (`connect-timeout-s = 1200.0`) and the SDK handles retries internally.

### 3.4 Checkpoint Types & Inflight Sampling

- **`save_weights_for_sampler(name)`** (`SAMPLER_WEIGHTS`): Fast export of LoRA weights for inference (`tinker://.../sampler_weights/<step>`). Cannot be used to resume training (returns HTTP 400).
- **`save_state(name)`** (`WEIGHTS`): Saves both weights and optimizer state (`tinker://.../weights/<step>`). Resume with `create_training_client_from_state` or switch optimizers (e.g., SFT -> RL) with `create_training_client_from_state_with_optimizer`.
- **`save_weights_external(name)` + `RestClient().get_external_weights_urls()`**: Exports downloadable PEFT LoRA archives for open-weight models (`Qwen/Qwen3.8-27B`, `zai-org/GLM-5.3-Flash:peft:262144`).
- **`save_weights_and_get_sampling_client(kind="inflight")`**: Updates multi-turn agentic rollouts in-place to the latest weights without invalidating the KV cache.

### 3.5 Dr. GRPO Advantage Computation & Inkling `<thinking effort=...>`

- **Dr. GRPO (`compute_dr_grpo_advantages`)**: Mean-center rollout rewards within each problem group (`advantage_i = reward_i - mean(rewards)`) **without** dividing by `std(rewards)` to eliminate difficulty bias and completion length bias, and drop constant-reward groups.
- **Inkling Effort Control**: Inkling models use `<thinking effort=X.XX>` (`0.00` to `0.99`) inside assistant completions. Never strip `<thinking>` tags across multi-turn rollouts so prefix KV caching remains 100% intact.

---

## 4. Running Host-Side Post-Training (`scripts/tinker/tinker_runner.py`)

### Offline Preflight & Dry-Run (No API Key or Credits Required)

```bash
# Check environment and SDK status
python3 scripts/tinker/tinker_runner.py --mode preflight

# Run offline dry-run and write snapshot for addons/tinker-trainer
python3 scripts/tinker/tinker_runner.py \
  --mode dry-run \
  --base-model thinkingmachines/Inkling-2-Small \
  --loss-fn cispo \
  --optimizer adamw \
  --run-id masc-rlvr-01 \
  --step 10 \
  --snapshot-out .masc/tinker/latest_snapshot.json
```

### Live SFT / RLVR Training (With `TINKER_API_KEY`)

```bash
pip install tinker
export TINKER_API_KEY="tml-..."

python3 scripts/tinker/tinker_runner.py \
  --mode train \
  --base-model thinkingmachines/Inkling-2-Small \
  --loss-fn cispo \
  --optimizer adamw \
  --bundle .masc/tinker/rlvr-latest.jsonl \
  --run-id masc-rlvr-01 \
  --step 50 \
  --lora-rank 32 \
  --learning-rate 1e-4 \
  --snapshot-out .masc/tinker/latest_snapshot.json
```

---

## 5. Disabling or Removing the Integration

### Turn off only the add-on

To keep the declaration and its settings while stopping the worker, set the declaration's root `enabled = false` and save it. Reconciliation cleans up the owned worker; the declaration, named persistent state volume, retained observations and evidence remain. Set `enabled = true` to attach a new worker after that cleanup is confirmed.

To remove the installation instead, call `masc_lane_detach` with `{"instance_id": "<ID>"}`, enter `detach <ID>` through the TUI Add-on command, or use Dashboard **Remove TOML + worker**. After worker cleanup is confirmed, this also removes `<resolved-config-root>/lane-addons/tinker-trainer.toml` so reconciliation cannot reinstall it. Removing the declaration file directly has the same ownership effect after the next complete configuration read. Past observations, retained evidence and the named persistent state volume are not deletion substitutes and are preserved.

### Stop inference and host training

First move every Keeper and lane selection away from `tinker.tinker-inkling-2-small` and any `tinker://` checkpoint slot. Then comment or remove the Tinker provider/credential/healthcheck tables, all Tinker model tables and the capability tables of `tinker://` profiles, and their `[tinker.<model>]` rows, and restart MASC. Removing only `[providers.tinker]` while leaving a selected model is not a clean disable. Detaching the add-on does not change these runtime rows, and removing the runtime rows does not stop a separately invoked host runner.

The host runner is a one-shot command, so stop invoking it rather than looking for an add-on worker to detach. Remove `TINKER_API_KEY` from the service environment only when no remaining Tinker consumer needs it. Local detachment and TOML edits do not delete remote training runs or `tinker://` checkpoints; manage those through Tinker separately.

---

## 6. Pricing & Model Selection Reference

Training & sampling prices in USD per million tokens, "as of October 19, 2026" on the [Tinker pricing page](https://thinkingmachines.ai/tinker/pricing/). Context, size and type come from [Models & Pricing](https://tinker-docs.thinkingmachines.ai/tinker/models/models_and_pricing/). Both were checked on 2026-11-07. Only `thinkingmachines/Inkling-2-Small` has an AGENT_CORE catalog row.

| Model ID | Total / active params | Type | Context | Prefill (cached) | Sample | Train |
| --- | --- | --- | --- | --- | --- | --- |
| `thinkingmachines/Inkling-2-Small` | 594B / 17B MoE | Hybrid + Vision | 64K | $0.30 ($0.03) | $1.00 | $1.50 |
| `thinkingmachines/Inkling-2-Small:peft:262144` | 594B / 17B MoE | Hybrid + Vision | 256K | $0.30 ($0.03) | $1.00 | $3.00 |
| `thinkingmachines/Inkling` | 975B / 41B MoE | Hybrid + Audio + Vision | 64K | $1.87 ($0.374) | $4.68 | $5.61 |
| `Qwen/Qwen3.8-27B` | 27B / 27B dense | Hybrid + Vision | 64K | $0.6975 ($0.1395) | $5.595 | $4.103 |
| `Qwen/Qwen3.8-27B:peft:262144` | 27B / 27B dense | Hybrid + Vision | 256K | $0.6975 ($0.1395) | $5.595 | $7.46 |
| `zai-org/GLM-5.3-Flash:peft:262144` | 320B / 18B MoE | Reasoning | 256K | $0.84 ($0.168) | $2.11 | $5.58 |

The Models & Pricing page does not say which models export LoRA weights. Check `save_weights_external` support for a model before relying on it (§3.4).
