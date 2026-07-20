# RFC-0345 — Streaming idle-timeout fail-safe floor (#25128)

- Status: Draft
- Author: vincent
- Related: masc#25128 (bug), `lib/keeper/keeper_agent_run.ml` (stream_idle_timeout_s wiring), `lib/config/env_config_keeper.ml` (MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC), RFC-0000 §1.2 (Four Laws / liveness)

## 0. Summary

A hung provider stream (bytes stop arriving mid-response, connection never closes) freezes a keeper's chat lane indefinitely. masc already threads an inter-line idle timeout (`stream_idle_timeout_s`) to OAS, but it defaults to `None` by explicit design ("neither MASC nor OAS may infer a provider/model default"), so an operator who does not set `MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC` gets no bound at all. Measured freeze: 30+ minutes (#25128).

This RFC separates two conflated concepts — a **tuned per-provider timeout** (which the current principle rightly forbids inferring) versus a **liveness fail-safe floor** (a single generous absolute ceiling that only fires on genuine hangs). It proposes adding the latter without violating the former.

## 1. Problem (evidence)

- `keeper_agent_run.ml:498-509`: comment states OAS `stream_idle_timeout_s` "bounds inter-line idle on HTTP streams", and "`[None]` is carried unchanged: neither MASC nor OAS may infer a provider/model default." The value is `Keeper_runtime_resolved.stream_idle_timeout_sec () : float option` (`:503-504`), passed at `:597` as `?stream_idle_timeout_s`.
- `env_config_keeper.ml:559-570`: `stream_idle_timeout_sec ()` reads `MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC`; absent → `None`.
- Consequence: with the env var unset (the default deployment posture), a provider stream that stalls after emitting partial output is never cancelled. The keeper's turn fiber blocks on the stream read; the chat lane makes no further progress until an external restart. `body_timeout_s` (`body_timeout_override_sec`) is likewise opt-in and does not bound *inter-chunk* idle.
- #25128 (created 2026-07-18, label `triage-required`) records the 30+ minute freeze. The team treats it as a bug, not intended behavior.

The tension: the "no inferred default" rule exists so masc/OAS never silently truncate a **slow-but-alive** stream (a provider legitimately pausing between tokens) by guessing a provider-tuned value. That rationale is sound. But it currently also permits the **degenerate** case (never-progressing stream) to hang forever.

## 2. Non-goals

- Per-provider or per-model tuned idle values (that is the thing the "no inferred default" rule forbids, and this RFC preserves that).
- Changing OAS enforcement semantics. OAS already enforces whatever `stream_idle_timeout_s` it receives; this RFC only changes what masc *resolves* when the operator supplies nothing.
- Bounding total response latency (that is `body_timeout_s`, a separate knob).
- Retry/failover policy after a timeout fires (existing keeper error handling owns that).

## 3. Design

### 3.1 Key distinction — floor vs tuned default

- A **tuned default** answers "what inter-line gap is normal for provider X?" — model-dependent, easy to get wrong, forbidden to infer.
- A **fail-safe floor** answers "what inter-line gap is, for ANY provider, unambiguously a hang?" — a single conservative constant far above any legitimate token gap. Choosing a floor is a policy decision made once, explicitly, in masc — not an inference of a provider's tuned value. The "no inferred default" rule is not violated because masc is not guessing a per-provider value; it is declaring a universal liveness ceiling.

### 3.2 Options

**Option A — fail-safe floor (recommended).**
`Keeper_runtime_resolved.stream_idle_timeout_sec ()` resolves `None → Some FLOOR` where `FLOOR` is a named constant (proposed `600.0` s = 10 min, justified below). An explicit `MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC` still overrides. The resolved value flows through the existing `?stream_idle_timeout_s` wiring unchanged — OAS enforcement is untouched.
- Pro: closes the indefinite-freeze hole for the default deployment posture; the value is a liveness floor, not a tuned default, so the principle holds; bounded code change at one resolution site + a constant.
- Con: a provider that legitimately idles >10 min mid-stream would be cut. This is judged non-existent in practice (no known provider pauses 10 min between bytes of a single response); if one exists, the operator sets the env var higher (explicit override path already exists).

**Option B — per-provider default table.**
A table mapping provider → idle default.
- Pro: most precise.
- Con: this is exactly the "inferred provider default" the current principle forbids; a maintained table drifts as providers/models change; higher complexity. Rejected as violating the non-goal.

**Option C — keep opt-in, add observability only.**
Leave the default `None`; emit a loud WARN when unset and document the knob.
- Pro: preserves current behavior byte-for-byte; zero risk of cutting a slow stream.
- Con: the bug (#25128) remains for every deployment that has not set the env var — i.e. the reported failure mode is unfixed; relies on every operator reading docs.

### 3.3 Recommendation

**Option A + the observability half of C.** Resolve `None → Some 600.0` (fail-safe floor), keep explicit override, and additionally log once at keeper boot which value is in effect and whether it came from the env var or the floor (so operators can see the floor is active and tune it if their provider needs it). This fixes the freeze in the default posture while preserving the explicit-override escape hatch and honoring "no *tuned* inference."

### 3.4 FLOOR value justification

`600.0` s (10 min): an order of magnitude above any observed inter-token gap for streaming chat completions (typically sub-second to low-seconds). It targets only true hangs. The constant is named (e.g. `stream_idle_failsafe_floor_sec`) with a comment citing this RFC, per CLAUDE.md magic-number rule. The value is revisitable; it is a floor, not a tuning.

## 4. Acceptance

- A stream that emits no bytes for `FLOOR` seconds (simulated hang) is cancelled and surfaces a typed timeout to keeper error handling — verified by a test that drives the resolution + a fake clock, asserting cancellation at the floor when the env var is unset.
- A stream that emits a byte every `< FLOOR` seconds runs to completion uncut (no regression for slow-but-alive streams).
- An explicit `MASC_KEEPER_STREAM_IDLE_TIMEOUT_SEC` still takes precedence over the floor (override preserved).
- Boot log states the effective idle timeout and its source (env vs floor).

## 5. Blast radius

- Single resolution site (`Keeper_runtime_resolved.stream_idle_timeout_sec`) changes `None → Some FLOOR`; every consumer already handles `Some`. OAS enforcement path unchanged (it already received `float option` and acted on `Some`).
- Behavioral change: deployments that previously ran with no idle bound now get a 10-min ceiling. This is the intended fix; call it out in CHANGELOG.
- No schema change, no wire-format change, no cross-repo coordination (masc-local resolution).

## 6. Workaround-rejection self-check (CLAUDE.md)

- Not telemetry-as-fix: the floor actually cancels the hang, not merely counts it (the C-only observability half is additive, not the fix).
- Not a string/substring classifier, not N-of-M, not a catch-all: it is a single typed resolution (`None → Some floor`).
- Not cap/cooldown/dedup symptom suppression: it addresses the root liveness gap (unbounded idle) with a bound, at the boundary where the value is resolved.
- The "no inferred default" principle is preserved by construction: the floor is a declared universal liveness ceiling, not a per-provider tuned inference (§3.1). This RFC exists precisely so that distinction is reviewed and signed off before code lands.

## 7. Implementation note (post-approval)

Bounded: (a) name the floor constant + resolve `None → Some floor` in `Keeper_runtime_resolved`; (b) add the boot log line with source attribution; (c) test the hang-cancels / slow-survives / env-overrides matrix with a fake clock. No OAS change. Sequenced after this RFC is accepted.
