# Diagnostic: issue_king resolves to qwen3.6:27b despite cascade declaration

- Date: 2026-04-29
- Author: Vincent (vincent.dev@kidsnote.com)
- Status: Investigation — fix deferred to separate PR after root path is confirmed
- Related memory: `feedback_oas_execution_uncancellable_mid_turn`,
  `feedback_persona_prompt_fix_validated_post_restart`,
  `feedback_codex_cli_internal_5model_rotation`

## Symptom

System log (`/Users/dancer/me/.masc/logs/system_log_2026-04-29.jsonl`)
shows the `issue_king` keeper executing turns on
`ollama:qwen3.6:27b-coding-nvfp4`:

```
[2026-04-29 10:17:16] [INFO] [Keeper] keeper:issue_king
  turn=43 total_turns=244
  model=qwen3.6:27b-coding-nvfp4
  tokens=66976 wall_tok_s=0.2 latency_ms=1761002
```

Wall-clock turn duration is ~1761 s (≈ 29 min 22 s). Turn `total_turns=244`
indicates this is sustained behaviour, not a one-off.

The same `_comment_keeper_unified` block in `cascade.json` already documents
that 27 B usage was intentionally removed from shared lanes
("turn 214x slower"). Yet `issue_king` is still reaching it.

## Declared cascade

`~/me/.masc/config/keepers/issue_king.toml`:

```toml
cascade_name = "local_with_kimi_coding_with_glm"
```

`~/me/.masc/config/cascade.json` —
`local_with_kimi_coding_with_glm_models`:

```json
[
  { "model": "codex_cli:gpt-5.3-codex-spark", "weight": 110 },
  { "model": "glm-coding:auto", "weight": 25 },
  { "model": "kimi_cli:kimi-for-coding", "weight": 30 }
]
```

`ollama:qwen3.6:27b-coding-nvfp4` is **not** in this list.

The only cascades that declare 27 B are:

| Cascade key | Models |
|---|---|
| `local_only_models` | `ollama:qwen3.6:27b-coding-nvfp4` |
| `local_recovery_models` | `ollama:qwen3.6:27b-coding-nvfp4` |
| `local_qwen3_27b_only_models` | `ollama:qwen3.6:27b-coding-nvfp4` |

These are intended for the `ollama-local` keeper alone (per the
`_comment_local_qwen3_27b_only` block).

## Suspect path

`lib/cascade/cascade_runtime.ml:43,48`:

```ocaml
| [] -> [ Provider_adapter.default_local_fallback_label () ]
```

`lib/provider_adapter.ml:718-725`:

```ocaml
let default_local_fallback_label () =
  match
    List.find_opt
      (fun (adapter : adapter) -> adapter.runtime_kind = Local)
      direct_adapters
  with
  | Some adapter -> adapter.canonical_name ^ ":auto"
  | None -> "auto"
```

When the materialised cascade for `local_with_kimi_coding_with_glm`
collapses to an empty list at runtime — for example because all three
declared providers are rejected by the bound-actor filter or the
required-tool-use gate (see `_comment_keeper_unified` in
`cascade.json`) — the runtime substitutes the first `runtime_kind = Local`
adapter's `:auto` alias. On this host that resolves to ollama, and
ollama's auto routing returns the only loaded local model with a
matching capability tag.

`lib/keeper/keeper_context_core.ml:1172` applies the same fallback
when no preferred-model label is provided.

## What was NOT confirmed

- The exact bound-actor / tool-use gate event that empties the
  candidate list for `issue_king`. The earlier
  `_comment_keeper_unified` block documents this happening for the
  `keeper_unified` cascade, but not specifically for
  `local_with_kimi_coding_with_glm`.
- Whether `ollama:auto` deterministically resolves to
  `qwen3.6:27b-coding-nvfp4`, or whether it picks the "largest loaded"
  model.
- Whether the `local_with_kimi_coding_with_glm` cascade has a
  declared `fallback_cascade` field that points at one of the
  27 B cascades. (`grep` did not surface one, but `cascade_config.ml`
  has a `fallback_cascade` resolver that may apply.)

## Why no fix in this PR

Memory `feedback_evidence_first_before_speculation_pr` and
`feedback_no-string-matching-classification` apply: the fix path is
ambiguous (cascade gate event vs. provider-adapter default vs.
ollama auto-routing) and patching one without confirming root cause
risks layering a band-aid (memory:
`feedback_no-timeout-as-bandaid-for-root-cause`,
`feedback_helper-default-field-with-caller-override`).

Concrete next steps — pick one, do not parallelise:

1. **Reproduce in test.** Stand up an empty `local_*` cascade in a
   test fixture and assert
   `Cascade_runtime.resolve_models cascade_name = []` does **not**
   leak into a Local-adapter `:auto` label without operator opt-in.
2. **Add audit log.** Emit a structured event whenever
   `default_local_fallback_label ()` is the path taken — including
   the cascade name and the upstream rejection reason. Today this
   substitution is silent, which matches the user-reported "Silent
   Failure" framing.
3. **Tighten the contract.** Treat empty resolved cascade as
   `Error _` in the call site, surface the error to the keeper
   loop, and require an explicit
   `allow_default_local_fallback = true` flag per cascade.

Option (2) is the lowest-risk first step; it converts the silent
fallback into an actionable signal without changing routing
behaviour. Option (3) is the durable fix.

## Operator workaround (no code change)

For the immediate user complaint (`issue_king` taking 30-minute
turns on 27 B), the persona override is the smallest change:

`.masc/config/keepers/issue_king.toml`:

```toml
# Before (current):
cascade_name = "local_with_kimi_coding_with_glm"
# After (workaround until fallback path is fixed):
cascade_name = "big_three"   # or another known-cloud cascade
```

Restart the masc-server. Verify with one keeper turn that the new
log line shows a cloud model.

This workaround does not need this diagnostic PR — it is a config
change in `~/me/.masc`, separate from the masc-mcp source tree.
