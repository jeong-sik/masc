# Thinking Machines Tinker & Inkling Integration Guide (experimental)

This integration is **experimental**. The provider template and the `tinker-trainer` add-on at revision `0.1.0` are opt-in. Live inference and training depend on an external service, and `--mode train` creates remote training state and can incur charges. Offline tests and dry-runs do not establish live-service compatibility or checkpoint quality.

MASC integrates with **Thinking Machines Lab's Tinker API** (`https://tinker-docs.thinkingmachines.ai/tinker/`) and the **Inkling** model family (`thinkingmachines/Inkling-2-Small`, `thinkingmachines/Inkling`, `Qwen/Qwen3.8-27B`, `zai-org/GLM-5.3-Flash:peft:262144`) using **loose coupling**:

1. **Inference (`config/runtime.toml`)**: Uses MASC's existing `openai-compatible-http` provider protocol with zero OCaml core changes.
2. **Dataset Derivation & Checkpoint Gate (`addons/tinker-trainer/`)**: Runs as a network-isolated MASC Lane Add-on (`--network none`) that joins Keeper execution receipts, Task/Goal Verifier verdicts, and Board Karma into SFT/RLVR datasets and gates checkpoint promotion.
3. **Host-side Post-Training Runner (`scripts/tinker/tinker_runner.py`)**: Executes shifted-token `forward_backward`, `optim_step`, `save_weights_for_sampler`, and optional `save_state` calls on the host when `TINKER_API_KEY` is present, or runs in `--mode dry-run` offline.

---

## 1. Enabling Tinker & Inkling Inference in `runtime.toml`

`config/runtime.toml` includes a ready-to-uncomment template for `[providers.tinker]` and `[models.tinker-inkling-2-small]` (covered by `test_self_hosted_templates_resolve_when_enabled` in `test/test_runtime_config_validity.ml`).

### Step 1: Set `TINKER_API_KEY`

Set the key in the environment of the MASC server process, through its service manager or the shell that starts it. Exporting it in another terminal does not update an already running server. The TOML stores only the variable name; do not paste the key into configuration or commit it.

```bash
export TINKER_API_KEY="tml-..."
```

### Step 2: Enable `[providers.tinker]` and Inkling profiles in `<resolved-config-root>/runtime.toml`

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

# Default Keeper turn profile (reasoning_effort = "high" -> Inkling effort ~0.90)
[models.tinker-inkling-2-small]
api-name = "thinkingmachines/Inkling-2-Small"
max-context = 262144
tools-support = true
thinking-support = true
streaming = true
reasoning-effort = "high"

[models.tinker-inkling-2-small.capabilities]
supports-tool-choice = true
supports-named-tool-choice = true
supports-required-tool-choice = true
supports-parallel-tool-calls = true
thinking-control-format = "reasoning-effort"
accepted-reasoning-efforts = ["none", "minimal", "low", "medium", "high", "xhigh"]
reasoning-streaming-format = "delta:reasoning_content"
supports-response-format-json = true
supports-structured-output = true
supports-image-input = true
supports-audio-input = true
supports-multimodal-inputs = true
supports-system-prompt = true

[tinker.tinker-inkling-2-small]
max-concurrent = 4

# Fast non-thinking profile for exact-output gates (reasoning_effort = "none" -> effort 0.00)
[models.tinker-inkling-2-small-none]
api-name = "thinkingmachines/Inkling-2-Small"
max-context = 262144
tools-support = true
thinking-support = false
streaming = true
reasoning-effort = "none"

[models.tinker-inkling-2-small-none.capabilities]
supports-tool-choice = true
supports-named-tool-choice = true
supports-required-tool-choice = true
supports-parallel-tool-calls = true
thinking-control-format = "reasoning-effort"
accepted-reasoning-efforts = ["none", "minimal", "low", "medium", "high", "xhigh"]
supports-response-format-json = true
supports-structured-output = true
supports-image-input = true
supports-audio-input = true
supports-multimodal-inputs = true
supports-system-prompt = true

[tinker.tinker-inkling-2-small-none]
max-concurrent = 8
```

### Step 3: Select the slot and restart MASC

The example creates the slot IDs `tinker.tinker-inkling-2-small` and `tinker.tinker-inkling-2-small-none`. Select only the intended slot in the target Keeper or lane configuration; adding the tables does not replace existing selections. The runtime catalog is loaded at process startup, so restart the MASC server after editing `runtime.toml`. A running server does not hot-reload the new provider, model or checkpoint row.

### Hot-Swapping a Fine-Tuned Checkpoint (`tinker://...`)

When `save_weights_for_sampler` produces a checkpoint URI, bind it as a new model row without deploying a separate inference server. Restart MASC to load that row as described above:

```toml
[models.tinker-inkling-masc-rlvr]
api-name = "tinker://89d55c89-5591-5f19-9f22-5e3451af980d:train:0/sampler_weights/000001"
max-context = 262144
tools-support = true
thinking-support = true
streaming = true
reasoning-effort = "high"
# (copy [models.tinker-inkling-2-small.capabilities] block)

[tinker.tinker-inkling-masc-rlvr]
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

First move every Keeper and lane selection away from `tinker.tinker-inkling-2-small`, `tinker.tinker-inkling-2-small-none` and any `tinker://` checkpoint slot. Then comment or remove the Tinker provider/credential/healthcheck tables, all Tinker model/capability tables—including `tinker://` profiles—and their `[tinker.<model>]` rows, and restart MASC. Removing only `[providers.tinker]` while leaving a selected model is not a clean disable. Detaching the add-on does not change these runtime rows, and removing the runtime rows does not stop a separately invoked host runner.

The host runner is a one-shot command, so stop invoking it rather than looking for an add-on worker to detach. Remove `TINKER_API_KEY` from the service environment only when no remaining Tinker consumer needs it. Local detachment and TOML edits do not delete remote training runs or `tinker://` checkpoints; manage those through Tinker separately.

---

## 6. Pricing & Model Selection Reference

| Model ID | Architecture | Context | Prefill (Cached) | Sample | Train | Exportable LoRA Weights |
| --- | --- | --- | --- | --- | --- | --- |
| `thinkingmachines/Inkling-2-Small` | 594B / 17B MoE | 262,144 | $0.30/M ($0.03/M) | $1.00/M | $1.50/M | Cloud-hosted (`tinker://...`) |
| `thinkingmachines/Inkling` | 1T / 32B MoE | 262,144 | $1.00/M | $3.00/M | $3.00/M | Cloud-hosted (`tinker://...`) |
| `Qwen/Qwen3.8-27B` | 27B Dense | 262,144 | $0.54/M | $1.36/M | $1.63/M | Yes (`save_weights_external`) |
| `zai-org/GLM-5.3-Flash:peft:262144` | 35B / 3.6B MoE | 262,144 | $0.22/M | $0.54/M | $0.65/M | Yes (`save_weights_external`) |
