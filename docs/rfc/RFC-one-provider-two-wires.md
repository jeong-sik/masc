---
rfc: "one-provider-two-wires"
title: "One provider, two wires"
status: Implemented
created: 2026-08-27
updated: 2026-08-27
author: vincent
supersedes: []
superseded_by: null
related: []
---

# One provider, two wires

## 1. Problem

`ollama_cloud` is one provider id that is reached over two different wires.
The catalog says so out loud:

```toml
# packages/agent_core/models.toml:2436-2444
id = "ollama_cloud"
kind = "ollama"
identity_kinds = ["ollama", "openai_compat"]
request_path = "/api/chat"
capabilities_base = "ollama_cloud"
```

`identity_kinds` admits two wires. `capabilities_base` names one preset. There
is no third field that says which wire that preset describes, and
`Model_catalog.lookup_for_provider` (`model_catalog.ml:892-910`) keys on
`(provider_name, id_prefix)` only. So the wire dimension exists in the provider
row and disappears before capabilities are resolved.

Everything below follows from that.

### 1.1 What it costs today

A capability that depends on the wire — the thinking control — has to be
written per model row, and the row author has to pick a wire by hand with no
way to record which one they picked. All 37 `provider_name = "ollama_cloud"`
rows in `models.toml` declare `thinking_control_format` themselves; zero
inherit it from the base preset. The preset is unreachable for this field.

They do not agree with each other. As of 2026-08-27, 17 of the reasoning-capable
rows say `ollama_think` (the native `/api/chat` toggle) and 7 say `none`. Both
groups are served over `/v1` in this deployment, where `ollama_think` encodes
nothing and `none` claims a control does not exist when one does.

The catalog contradicts itself in writing. `models.toml:519-526` says of a row
whose provider entry declares `/api/chat`:

> this row declared Ollama's native /api/chat think toggle even though it is
> served through ollama_cloud's OpenAI-compat /v1/chat/completions, which
> cannot encode it … Closes #28749

The provider row says native. Twenty model rows under it say `/v1`.

### 1.2 The repair loop

The same one-line declaration has been edited five times in five weeks:
2026-07-20 (four overlay rows), 2026-08-04 (a tagged row), 2026-08-15 (base
catalog `deepseek-v4-flash`, #28748/#28749), 2026-08-17 (back to
`ollama_think`), 2026-08-27 (to `reasoning_effort`, plus three more bindings).

Each edit was correct for the row it touched and left the class open. That is
the signature of a missing dimension, not of careless authors.

### 1.3 How it reaches an operator

A Keeper turn on a `/v1`-served binding that asks for thinking is refused
before dispatch:

```
Invalid request (attempt_rejected): model "deepseek-v4-flash:0731" declares
thinking control, but the resolved typed dialect cannot encode
enable_thinking=true on this OpenAI-compatible request path
```

A binding with no row at all fails the other way — `Enable_not_declared` —
because it falls back to `openai_compat_chat_capabilities`
(`capabilities.ml:436`).

And a binding that declares `none` does not fail at all. It sends no control,
and Ollama then turns reasoning on by itself: "Ollama auto-enables thinking for
capable models when no `reasoning_effort` is provided" (ollama#14820,
docs.ollama.com/api/openai-compatibility). Measured on this deployment: 54
turns on one lane returned zero text, 34 stopped at `max_tokens` and 20 ended
normally with the answer in the reasoning field.

## 2. What the wire actually offers

Measured against `https://ollama.com/v1` on 2026-08-27 with
`deepseek-v4-flash:0731`, `gemma4:31b`, `nemotron-3-ultra` and `kimi-k3`:

| `reasoning_effort` | result |
| --- | --- |
| `none` | accepted; reasoning length 0 |
| `low` / `medium` / `high` / `max` | accepted; content and reasoning both returned |
| `minimal` / `xhigh` | refused, and the endpoint names the legal set itself |

The refusal text is the authority for the ladder:

```
invalid reasoning value: 'minimal' (must be "high", "medium", "low", "max", or "none")
```

Same five values the official documentation lists. The native `think` boolean
is not accepted on this path, which is the half the existing rows got right.

## 3. Why the obvious fixes are wrong

**Fix the base preset.** Measured: changing `ollama_cloud_capabilities`
(`capabilities.ml:557`) reaches zero live bindings, because all 37 rows
override the field. It does break
`test_provider_registry.ml:342`, and correctly — that pin holds the provider
row's `kind`/`request_path` and its `capabilities_base` together, and a
`/v1` dialect on a `/api/chat` entry makes the entry self-contradictory.

**Key capabilities on `Provider_kind` instead of the provider label.**
`runtime_adapter.ml:443-452` already records why not: the label must win over
the wire kind, or every OpenAI-compatible endpoint collapses onto the
`"openai_compat"` label, "a label no catalog row holds, and the 2026-07-15
boot-gate wipe was exactly that". `Provider_kind` has seven values; all `/v1`
endpoints share one. Moving the key there unresolves all 37 rows.

The key is not wrong. It is incomplete: capabilities need
label **and** wire, and today they get label only.

## 4. Implemented design

Give the wire a place to be declared, so no model row has to encode it.

**4.1** `[[providers]]` gains a per-wire capability base:

```toml
id = "ollama_cloud"
identity_kinds = ["ollama", "openai_compat"]
capabilities_base = "ollama_cloud"                  # the wire in `kind`
capabilities_base_by_identity_kind = { openai_compat = "ollama_cloud_v1" }
```

A provider that admits one wire is unchanged and needs no new key.

**4.2** A new `ollama_cloud_v1` preset states the `/v1` truth once:
`thinking_control_format = Reasoning_effort`, `accepted_reasoning_efforts =
[None_; Low; Medium; High; Max]`, structured output still fail-closed.

**4.3** Capability resolution takes the wire it is resolving for. The wire is
already known at that point — `runtime_adapter.ml:244-248` computes it, mapping
a registry `kind = Ollama` with a chat-completions protocol to
`OpenAI_compat`. The value exists; it is simply not passed on.

**4.4** With the wire declared, the `thinking_control_format` line comes out of
every `ollama_cloud` row that only had it to name a wire. Rows keep the fields
that are genuinely per model: context, tools, whether the model reasons at all.

## 5. What this does not change

- Provider label stays the capability catalog key (§3).
- `supports_reasoning = false` rows keep their own declaration; a model that
  does not reason has no control regardless of wire.
- Native `ollama` deployments resolve exactly as today.

## 6. Verification

1. `test_provider_registry.ml:342` extends to assert each `identity_kind`
   resolves to a preset whose dialect that wire can encode. It fails today for
   `openai_compat`.
2. A test that walks every `provider_name = "ollama_cloud"` row and asserts
   none declares `thinking_control_format`. That is the ratchet against the
   repair loop returning.
3. The four models in §2 answer a live turn with `reasoning_effort` on the
   wire and non-empty text.
4. Native-path pins (`test_ollama_cloud_glm_uses_native_think_not_zai_thinking`
   and the rest of `test_thinking_control_dialects`) stay green unchanged.

## 7. Cost and the alternative considered

The alternative is to split the label: give this deployment a provider id that
is not `ollama_cloud`. It needs no agent_core change, but it renames every
`ollama_cloud.*` id in `runtime.toml` — lanes, panels, assignments, targets —
and the runtime id recorded in Keeper meta. It also leaves the upstream catalog
contradicting itself for the next deployment.

The proposal here is a change to agent_core, which is the larger blast radius
of the two in code and the smaller one in configuration. It is preferred
because the contradiction is in the catalog, and that is where it should be
resolved.

## 8. Deployment cleanup

Older deployments declare the `/v1` truth per binding in
`agent-core-models-overlay.toml`. Once a binary containing this catalog is
deployed, those `thinking_control_format` overrides are redundant and should
be removed; the provider row and resolved wire are then the only authority.

## 9. Implementation summary

Landed in #30974 and the change alongside this closeout.

| Section | Where |
| --- | --- |
| §4.1 per-wire capability base | `models.toml:2415` — `capabilities_base_by_identity_kind = { openai_compat = "ollama_cloud_v1" }`; parsed by `model_provider_catalog.ml` |
| §4.2 `ollama_cloud_v1` preset | `capabilities.ml` — `Reasoning_effort` plus the measured ladder |
| §4.3 resolution takes the wire | `capabilities.ml` `provider_base_label ~catalog ~wire`, reached from `provider_config.ml` `capabilities_for_config_model` with `~wire:(Some config.kind)` |
| §4.4 rows stop naming a wire | 25 `ollama_cloud` rows dropped `thinking_control_format`; the 12 with `supports_reasoning = false` keep theirs, per §5 |

Verification, against §6:

1. Provider entries resolve per `identity_kind` — covered by the registry pin
   and by `test_capabilities` "ollama cloud /v1 wire resolves the effort
   control" / "ollama cloud native wire is unchanged". The second is the one
   that matters: the wire selects a base, it does not rewrite a row.
2. The ratchet — `test_model_catalog_default` "no Ollama Cloud row states a
   wire" walks every `provider_name = "ollama_cloud"` entry and fails on any
   reasoning-capable row that declares a thinking control. Checked by
   reintroducing one: it named `deepseek-v3.1:671b` and failed.
3. Live turn on the `/v1` wire — 2026-08-27, keeper `adm-race-cf-001` on
   `ollama_cloud.ollama-cloud-deepseek-v4-flash-0731`: `reasoning_effort=low`
   on the request, `thinking_blocks=0`, non-empty text, terminal reason
   `success`. The same lane had produced 54 zero-text turns before this.
4. Native-path pins unchanged — `test_thinking_control_dialects` green without
   edits, including the glm-5.2 native `think` body assertion.

The deployment cleanup in §8 is done for this deployment: the overlay no
longer declares a thinking control for any row.

One thing this does not close. The provider entry still declares
`kind = "ollama"` and `request_path = "/api/chat"` while carrying an
`openai_compat` identity kind, so the entry's own default wire and its second
wire are stated in different vocabularies. Nothing reads them inconsistently
today, and §3 explains why moving the catalog key is the wrong repair. It is
recorded here because the next person to read that row will notice it.
