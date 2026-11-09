# Thinking Machines Tinker & Inkling Integration Guide (experimental)

This integration is **experimental**. The provider template is opt-in. Live inference and training depend on an external service, and training creates remote training state and is billed. Offline tests and dry-runs do not establish live-service compatibility or checkpoint quality.

MASC integrates with **Thinking Machines Lab's Tinker API** (`https://tinker-docs.thinkingmachines.ai/tinker/`) and the **Inkling** model family (`thinkingmachines/Inkling-2-Small`, `thinkingmachines/Inkling`, `Qwen/Qwen3.8-27B`, `zai-org/GLM-5.3-Flash:peft:262144`) using **loose coupling**:

1. **Inference (`packages/agent_core/models.toml` + `config/runtime.toml`)**: The AGENT_CORE catalog has the `tinker` provider row and the `thinkingmachines/Inkling-2-Small` model row. `runtime.toml` binds them over the existing `openai-compatible-http` protocol. No OCaml code changes.
2. **Admission training (`scripts/tinker/librarian/`)**: Host-side scripts that generate labelled synthetic keeper-librarian admission requests, measure models on fixed evaluation sets against fixed gates, and train LoRA branches on audited teacher answers (§2). MASC never calls them.

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

An exact-output slot binds to a catalog provider row, and to the model's catalog row or, for a model the catalog has no row for, the capabilities its binding declares. `tinker.tinker-inkling-2-small` binds to its row. A `tinker://` checkpoint is a slot only when its runtime.toml states the five capabilities an exact slot needs: `max-context`, and `accepted-reasoning-efforts`, `supports-response-format-json`, `supports-structured-output` and `max-output-tokens` in its capabilities block (next section). The provider preset does not stand in for any of these five; the rest of what an exact request reads describes the provider's API and follows the preset unless stated. A checkpoint that leaves one of the five out is left out as `Target_not_in_catalog`, and the boot log names the keys to write. Every exact-output lane MASC ships asks for JSON syntax: the schema travels in the prompt, and MASC parses and validates the reply before accepting it. The missing structured output does not keep the row off these lanes.

Append `"tinker.tinker-inkling-2-small"` to the lane's `slots` list, such as `[runtime.exact_output_lanes.<lane>]` or `[runtime.addon_exact_lanes.<addon>.<output>]`, and restart. An exact lane sends the binding's `reasoning-effort`. In the 2026-11-07 replays at `low`, 17 of 17 librarian replies were valid both with `json_schema` on the request and with the schema carried in the prompt, which is what MASC sends to this row. Reasoning counts against the output budget: the largest of those replies used 3,172 output tokens. A lane without `max_output_tokens` sends no `max_tokens`, so the binding `max-tokens` never reaches an exact request and Tinker applies its own default of 4,096 (seen in a live 400 on 2026-11-08). The 3,172-token reply fits under that default too. Board agreement stayed below its pass line at every effort tried.

### Hot-Swapping a Fine-Tuned Checkpoint (`tinker://...`)

When `save_weights_for_sampler` produces a checkpoint URI, bind it as a new model row without deploying a separate inference server. A `tinker://` URI has no catalog row, so only the `openai_chat` preset of the `tinker` provider row answers for it, and that preset claims structured output and no reasoning. The model table's `max-context`, `tools-support`, `streaming` and `thinking-support` and every key of its capabilities block override the preset; an unwritten `tools-support` or `streaming` still overrides it, as `false` and `true`. An unstated capabilities key keeps the preset's value, except media input, which stays off.

The checkpoint is an exact-output slot only when runtime.toml states five keys. `max-context` may sit on the model, the binding or the provider table. A provider's `max-context` is the operator's value too: it counts, answers for every model of that provider, and is read before the model table's. The capabilities block states the other four: `accepted-reasoning-efforts`, `supports-response-format-json`, `supports-structured-output` and `max-output-tokens`. The rest of what an exact request reads describes the provider's API and follows the `openai_chat` preset unless stated. Of those, `thinking-support` on the model table and `thinking-control-format` and `supports-system-prompt` in the block have keys; the schema dialect, document input and the endpoint's behaviour without a reasoning control have none ([RFC-0514](../rfc/RFC-0514-a-model-the-catalog-lacks-becomes-an-exact-slot-when-its-binding-declares-capabilities.md) §2.2).

The example below states all five and copies what the `thinkingmachines/Inkling-2-Small` row declares. That row declares no output ceiling; the example's 32,768 is the `max_tokens` the checkpoint's evaluation requests send. An exact request's `max_tokens` comes from the lane's `max_output_tokens`, and the declared `max-output-tokens` is used only to cut that value down. A lane without `max_output_tokens` sends no `max_tokens`, as above, so the example's Librarian lane states 32,768 as well. The lane's budget goes to every slot it lists, and the window counts it together with the prompt. A checkpoint's own behaviour was not measured. Declare the window of the base the run trained on: 65,536 for `thinkingmachines/Inkling-2-Small`, 262,144 for `thinkingmachines/Inkling-2-Small:peft:262144`. Restart MASC to load the row:

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
max-output-tokens = 32768

[tinker.tinker-inkling-ckpt]
max-concurrent = 4

[runtime.exact_output_lanes.librarian_exact]
slots = ["tinker.tinker-inkling-ckpt"]  # with the lane's other slots
max_output_tokens = 32768
```

A `tinker://` model still uses `[providers.tinker]`, its credential and an account with access to that checkpoint.

### Activation requirements and failure symptoms

- Inference requires the complete provider, credential, model and `[tinker.<model>]` tables, a selected slot, a restarted server, network access and a non-empty valid key in the server environment. `[providers.tinker.healthcheck] path = "/models"` is retained for install/setup probes; server startup does **not** call it for admission.
- An unset or blank `TINKER_API_KEY` is refused before request dispatch with `Required provider credential is unavailable`. A rejected key or an account without model/checkpoint access fails on the actual inference call, or on an explicitly run `/models` setup probe, with the upstream authentication response (normally HTTP 401 or 403). Do not interpret successful TOML loading or server startup as live authentication proof.

---

## 2. Training an Admission Checkpoint (`scripts/tinker/librarian/`)

The scripts in `scripts/tinker/librarian/` train a LoRA of `thinkingmachines/Inkling-2-Small:peft:262144` for the keeper-librarian add-on's `admission` output, and decide with fixed pass lines whether the checkpoint may answer that output first. They run on the operator's host with `uv run` and read `TINKER_API_KEY` from the environment. MASC never calls them. `scripts/tinker/librarian/README.md` lists the files, the request shape, the order and the commands.

- The evaluation is fixed before training. `pass_lines.json` pins the request shape, the E-real records by digest, the audited E-synth requests by sha256, the gates and the bytes of the harness modules. `eval_admission.py` refuses to run when a pinned file changed, and `train_sft.py` refuses to train unless `pass_lines.json` has the sha256 it names.
- The scripts read the exact-request store in place. No store content is copied into the repository; committed evidence holds numbers, IDs and verdicts.
- Every script that calls Tinker takes `--budget`. The sampling scripts stop before a call whose worst-case price would pass it, and `train_sft.py` stops before training when its estimate does. `train_sft.py --dry-run` prints the estimate and trains nothing.
- `train_sft.py` saves the weights with `save_weights_for_sampler`. Bind the returned `tinker://` path as in the checkpoint section of §1, with the 262,144 window of the base the run trained on.

---

## 3. Disabling or Removing the Integration

### Stop inference and training

First move every Keeper and lane selection away from `tinker.tinker-inkling-2-small` and any `tinker://` checkpoint slot. Then comment or remove the Tinker provider/credential/healthcheck tables, all Tinker model tables and the capability tables of `tinker://` profiles, and their `[tinker.<model>]` rows, and restart MASC. Removing only `[providers.tinker]` while leaving a selected model is not a clean disable. Removing the runtime rows does not stop a training or evaluation script already running on the host.

The scripts in `scripts/tinker/librarian/` are one-shot commands; stop invoking them. Remove `TINKER_API_KEY` from the service environment only when no remaining Tinker consumer needs it. TOML edits do not delete remote training runs or `tinker://` checkpoints; manage those through Tinker separately.

---

## 4. Pricing & Model Selection Reference

Training & sampling prices in USD per million tokens, "as of October 19, 2026" on the [Tinker pricing page](https://thinkingmachines.ai/tinker/pricing/). Context, size and type come from [Models & Pricing](https://tinker-docs.thinkingmachines.ai/tinker/models/models_and_pricing/). Both were checked on 2026-11-07. Only `thinkingmachines/Inkling-2-Small` has an AGENT_CORE catalog row.

| Model ID | Total / active params | Type | Context | Prefill (cached) | Sample | Train |
| --- | --- | --- | --- | --- | --- | --- |
| `thinkingmachines/Inkling-2-Small` | 594B / 17B MoE | Hybrid + Vision | 64K | $0.30 ($0.03) | $1.00 | $1.50 |
| `thinkingmachines/Inkling-2-Small:peft:262144` | 594B / 17B MoE | Hybrid + Vision | 256K | $0.30 ($0.03) | $1.00 | $3.00 |
| `thinkingmachines/Inkling` | 975B / 41B MoE | Hybrid + Audio + Vision | 64K | $1.87 ($0.374) | $4.68 | $5.61 |
| `Qwen/Qwen3.8-27B` | 27B / 27B dense | Hybrid + Vision | 64K | $0.6975 ($0.1395) | $5.595 | $4.103 |
| `Qwen/Qwen3.8-27B:peft:262144` | 27B / 27B dense | Hybrid + Vision | 256K | $0.6975 ($0.1395) | $5.595 | $7.46 |
| `zai-org/GLM-5.3-Flash:peft:262144` | 320B / 18B MoE | Reasoning | 256K | $0.84 ($0.168) | $2.11 | $5.58 |

The Models & Pricing page does not say which models export LoRA weights. Check `save_weights_external` support for a model before relying on it.
