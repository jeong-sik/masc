# Thinking Machines Tinker & Inkling Integration Guide

MASC integrates with **Thinking Machines Lab's Tinker API** (`https://tinker-docs.thinkingmachines.ai/tinker/`) and the **Inkling** model family (`thinkingmachines/Inkling-2-Small`, `thinkingmachines/Inkling`, `Qwen/Qwen3.8-27B`, `zai-org/GLM-5.3-Flash:peft:262144`) using **loose coupling**:

1. **Inference (`config/runtime.toml`)**: Uses MASC's existing `openai-compatible-http` provider protocol with zero OCaml core changes.
2. **Dataset Derivation & Checkpoint Gate (`addons/tinker-trainer/`)**: Runs as a network-isolated MASC Lane Add-on (`--network none`) that joins Keeper execution receipts, Task/Goal Verifier verdicts, and Board Karma into SFT/RLVR datasets and gates checkpoint promotion.
3. **Host-side Post-Training Runner (`scripts/tinker/tinker_runner.py`)**: Executes shifted-token `forward_backward`, `optim_step`, `save_weights_for_sampler`, and optional `save_state` calls on the host when `TINKER_API_KEY` is present, or runs in `--mode dry-run` offline.

---

## 1. Enabling Tinker & Inkling Inference in `runtime.toml`

`config/runtime.toml` includes a ready-to-uncomment template for `[providers.tinker]` and `[models.tinker-inkling-2-small]` (tested on every CI run by `test_self_hosted_templates_resolve_when_enabled` in `test/test_runtime_config_validity.ml`).

### Step 1: Set `TINKER_API_KEY`

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

### Hot-Swapping a Fine-Tuned Checkpoint (`tinker://...`)

When `save_weights_for_sampler` produces a checkpoint URI, bind it as a new model row without redeploying any server:

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

---

## 2. Installing the `tinker-trainer` Lane Add-on

1. Build the worker container image from the repository root:
   ```bash
   docker build -f addons/tinker-trainer/Dockerfile -t masc-lane-tinker-trainer:0.1.0 addons
   ```
2. Copy the example declaration `docs/examples/lane-addons/tinker-trainer.toml` into `<resolved-config-root>/lane-addons/tinker-trainer.toml`.
3. In TUI (`/addons`) or the Dashboard, inspect the projected lanes:
   - `tinker/datasets`: Observed corpus and prepared SFT (`cross_entropy`) / RLVR (`cispo`, `ppo`, `importance_sampling`, `dro`, `gspo`, `stable_reinforce`) bundles.
   - `tinker/runs`: Step-by-step training loss, optimizer (`adamw` | `dimuon`), and status (`dry_run`, `running`, `completed`, `failed`).
   - `tinker/checkpoints`: Saved `tinker://.../sampler_weights/<step>` URIs and evaluation scores.
   - `tinker/readiness`: Promotion gate comparing `eval_pass_rate - baseline_pass_rate` against `binding.min_eval_gain`.

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

## 5. Pricing & Model Selection Reference

| Model ID | Architecture | Context | Prefill (Cached) | Sample | Train | Exportable LoRA Weights |
| --- | --- | --- | --- | --- | --- | --- |
| `thinkingmachines/Inkling-2-Small` | 594B / 17B MoE | 262,144 | $0.30/M ($0.03/M) | $1.00/M | $1.50/M | Cloud-hosted (`tinker://...`) |
| `thinkingmachines/Inkling` | 1T / 32B MoE | 262,144 | $1.00/M | $3.00/M | $3.00/M | Cloud-hosted (`tinker://...`) |
| `Qwen/Qwen3.8-27B` | 27B Dense | 262,144 | $0.54/M | $1.36/M | $1.63/M | Yes (`save_weights_external`) |
| `zai-org/GLM-5.3-Flash:peft:262144` | 35B / 3.6B MoE | 262,144 | $0.22/M | $0.54/M | $0.65/M | Yes (`save_weights_external`) |
