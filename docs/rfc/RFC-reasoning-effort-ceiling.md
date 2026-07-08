# Reasoning-effort ceiling — bound over-thinking for reasoning-effort models (OAS wire contract)

- Status: Draft
- Author: Claude (Opus 4.8), on behalf of jeong-sik (vincent)
- Date: 2026-07-08
- Related: RFC-0271 (in-turn recovery + thinking-budget — the corrective/token-budget siblings), RFC-0206 (runtime concept / `Reasoning_effort` capability), RFC-0036 (OAS cognitive mapping), RFC-0042 (typed closure)
- Tracking: keeper `thinking_only` error 2026-07-08 (`ollama_cloud.deepseek-v4-flash`); the preventive arm RFC-0271 §4.2 explicitly scopes out for reasoning-effort models.

> Anchors marked **(verified)** were read against `origin/main` @ current HEAD and
> the pinned `agent_sdk` opam package.

## 1. Problem

Reasoning-effort models over-think without bound. On the fleet default
`ollama_cloud.deepseek-v4-flash`, keeper turns routinely emit 43k–86k characters
of reasoning **(verified: live trajectory thinking blocks, `content_length`
30k–86k)**, and some terminate as `thinking_only` (only a `Thinking` block,
`stop_reason=end_turn`, no deliverable) — rejected by the accept contract as
`no_usable_progress`.

RFC-0271 provides the **corrective** arms: `Retry_no_thinking` (a thinking-off
re-shape, landed) and reroute. But correction is per-occurrence and costly. The
**preventive** — bounding how much the model thinks in the first place — is
missing for this model class.

### 1.1 Root gap (verified)

- 27 runtime entries declare `thinking-control-format = "reasoning-effort"`
  **(verified: `config/runtime.toml`, 27 matches)**, and flash also declares
  `supports-reasoning-budget = true` / `supports-extended-thinking = true`.
- **No effort *level* is configured or sent.** There is a per-runtime
  `max_thinking_budget` (a token ceiling, parse-only per RFC-0271 §4.2) but **no
  per-runtime reasoning-effort value**, and no request-path consumer sends one for
  reasoning-effort models. So the provider applies its own default effort, which
  is unbounded from masc's side.
- RFC-0271 §4.2's token-budget wiring **does not apply here**: a
  `with_thinking_budget n` (token count) is the wrong control surface for a model
  whose thinking is gated by an effort level, not a token budget. flash also has
  no `max_thinking_budget` set, so even that lever is inert.

### 1.2 What the SDK already provides (verified)

- `Reasoning_effort.t = Minimal | Low | Medium | High | XHigh`
  (`agent_sdk/llm_provider/reasoning_effort.mli`).
- Capabilities carry `accepted_reasoning_efforts : Reasoning_effort.t list option`
  (the model/provider subset enforced before serialization) and
  `thinking_control_format` including `Reasoning_effort` and `Thinking_object`
  ("top-level thinking object plus **optional reasoning_effort**")
  (`agent_sdk/llm_provider/capabilities.mli:11,88,93`).

So the wire vocabulary for sending an effort exists in the SDK; masc simply never
selects one.

## 2. Phase 0 — confirm the request-injection seam (before wiring)

One thing must be confirmed against the SDK before wiring, because the design
forks on it:

> Where does the per-request `reasoning_effort` value enter the SDK request for a
> `Reasoning_effort` / `Thinking_object` model — a `Builder`/`turn_params` field
> masc sets, or a value the backend derives from `accepted_reasoning_efforts`?

- If masc can set it (a `turn_params`/`Builder` reasoning_effort field): §3 is a
  masc-side config + wiring change.
- If the SDK derives it internally with no masc-settable input: this RFC needs an
  SDK change first (out of masc's tree) — record and coordinate, do not fake it
  masc-side.

Phase 0 is a read of the SDK request path (`backend_openai_responses` /
`provider_config` / `turn_params`), not code.

## 3. Design (assuming a masc-settable effort)

- **Config**: add a per-runtime `reasoning-effort = "minimal|low|medium|high|xhigh"`
  parsed into `Runtime_schema` as `Reasoning_effort.t option`, next to
  `max_thinking_budget`. Typed via `Reasoning_effort.of_string` (unknown → parse
  error, fail closed — RFC-0042).
- **Enforcement**: for a `Reasoning_effort` / `Thinking_object` model, when the
  config value is `Some e`, send `e` as the request reasoning_effort; when `None`,
  behave exactly as today (send nothing — no silent default injection). The value
  is validated against `accepted_reasoning_efforts` before serialization (the SDK
  already enforces this subset; masc must not send an unaccepted effort).
- **Producer↔consumer in the same PR** (RFC-0082 §3.5 no partial-site): the
  `Runtime_schema` field and the request-path consumer land together, with the
  request fixture asserting the effort field directly.
- **Default policy**: this RFC does **not** hardcode a global effort. It makes the
  ceiling *expressible* per runtime. Choosing flash's value (e.g. `medium`) is a
  config decision measured against the over-thinking rate, not baked into code.

## 4. Why not the alternatives (tradeoffs)

- **Do nothing / rely only on Retry_no_thinking (#23648):** correction fires
  per-occurrence and costs an extra attempt every time; it does not reduce the 43k–86k
  char thinking that also inflates latency and token cost on *non-failing* turns.
- **Change the fleet default off flash:** the operational mitigation the user
  rejected — it dodges the root (the model over-thinks unbounded) rather than
  bounding it.
- **Token-budget wiring (RFC-0271 §4.2):** wrong control surface for
  reasoning-effort models (§1.1).
- **Hardcode a global effort:** ignores `accepted_reasoning_efforts` per-model
  differences and removes the per-runtime knob; a config value is the same effort
  with correct granularity.

## 5. Blast radius & rollback

- 27 reasoning-effort runtimes are *eligible*, but only runtimes with an explicit
  `reasoning-effort` config value change behavior; `None` preserves today's wire
  exactly. So rollout is per-runtime opt-in, and rollback is deleting the config
  line. No blanket wire change.

## 6. Verification

- **Request fixture**: a reasoning-effort runtime with `reasoning-effort = "low"`
  serializes the effort in the request; with no value, the request is byte-identical
  to today.
- **Rejection of unaccepted effort**: configuring an effort outside
  `accepted_reasoning_efforts` fails closed (parse or pre-serialization error), not
  a silent send.
- **Operational**: measure per-runtime reasoning `content_length` distribution and
  `thinking_only` rejection rate before/after setting flash's effort.

## 7. Relationship to RFC-0271

RFC-0271 owns the **corrective** path (recovery on `thinking_only`) and the
**token-budget** preventive. This RFC is the **reasoning-effort** preventive for
the model class RFC-0271 §4.2 explicitly excludes. Corrective (`Retry_no_thinking`,
landed) is the model-agnostic backstop; this ceiling reduces how often it must fire
on reasoning-effort models.
