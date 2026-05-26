---
rfc: "0164"
title: "Voice tool abstraction integrity — keeper voice-flag deletion + cascade boundary cleanup"
status: Draft
created: 2026-05-23
updated: 2026-05-23
author: agent-llm-a-opus
supersedes: []
superseded_by: null
related: ["0080", "0088", "0157"]
implementation_prs: []
---

# RFC-0164 — Voice tool abstraction integrity

## §0 TL;DR

Voice tools (`keeper_voice_speak` / `keeper_voice_listen` / `keeper_voice_agent` / `keeper_voice_session_start` / `keeper_voice_session_end` / `keeper_voice_sessions`) are **client-intercepted** in `lib/keeper/agent_tool_voice_runtime.ml` — masc-mcp dispatches them locally via `Voice_bridge.agent_speak` (ElevenLabs HTTP) without provider involvement. They do **not** require provider execution capability.

Despite this, the codebase carries a redundant **keeper-side voice gate** (`voice_enabled` / `voice_channel` / `voice_agent_id` / `policy_voice_enabled` fields + `default_voice_enabled_for` / `default_voice_channel_for` / `default_voice_agent_id_for` helpers + `canonical_voice_channel` sentinel) that:

1. **Conflates two categories** in `required_tool_names`: provider-executed tools (`keeper_bash`, `keeper_board_post`) and client-intercepted tools (`keeper_voice_*`). The cascade pre-dispatch matcher (RFC-0157) treats both the same and rejects every candidate when voice tools are in the required set.
2. **Duplicates the SSOT**: tool availability is already authoritative in `tool_policy.toml [groups.voice]` (RFC-0080). The per-keeper voice flag is a parallel decision surface that *overrides or invalidates* the policy grant depending on its value.
3. **Leaks abstraction**: external consumers (keeper LLM personas) see the leak — voice produces zero output when the policy grants but the flag is off; turn-loop dies entirely when the flag is on (because of (1)).

This RFC **removes** the keeper-side voice gate surface entirely. After this RFC:

- Tool availability: `tool_policy.toml` (single source of truth).
- Tool selection: persona prompt / system instruction (higher-level guidance, not a structural gate).
- Tool execution: `agent_tool_voice_runtime.ml` client-intercepts; provider is unaware.
- Cascade matcher: client-intercepted tools are *categorically* excluded from `required_tool_names` and not subject to provider-capability filtering.

Consumer count: 1 (single user). No backwards-compatibility tax. Deletion is the entire fix; no migration shim, no transitional flag, no counter.

## §1 Motivation

### 1.1 The category error

`Voice_bridge.agent_speak` is called from exactly one site — `lib/keeper/agent_tool_voice_runtime.ml:31` — and that site receives a `keeper_voice_speak` tool emission from the LLM. The handler does the HTTP call to ElevenLabs locally. **No provider sees this tool.** It is purely client-side.

Yet when `voice_enabled = true`, the keeper's `required_tool_names` list emits these six tool names, and cascade pre-dispatch (RFC-0157) treats them as "required actions the provider must be able to execute." Live evidence (2026-05-23T11:26Z system log):

```
"required_tool_names":[..., "keeper_voice_speak", "keeper_voice_listen", ...]
"rejection_reasons":[
  "required_tool_unsupported: provider=provider-k-coding missing_required_tools=[keeper_bash]",
  "required_tool_unsupported: provider=provider-d missing_required_tools=[keeper_bash]"
]
"rejected_candidate_count": 9
```

The proximate rejection cited `keeper_bash`, but the *cascade-exhausted* condition only triggered *after* `voice_enabled=true` was toggled — empirically the voice tool inclusion is what tipped the matcher into wholesale rejection. The matcher's category is wrong: it should never have considered client-intercepted tools at all.

### 1.2 The duplicate SSOT

`tool_policy.toml` at line 87 already declares `[groups.voice]` with the six voice tool names, and the `coding` preset (used by `sangsu` and other personas) includes the `voice` group at line 253:

```toml
[groups.voice]
tools = [
  "keeper_voice_speak", "keeper_voice_listen", "keeper_voice_agent",
  "keeper_voice_sessions", "keeper_voice_session_start", "keeper_voice_session_end"
]
# ...
groups = ["base", ..., "voice"]   # coding preset
```

A keeper with the `coding` preset has voice tools available *by policy*. The parallel `voice_enabled` flag on `keeper_meta` then re-decides the same question, with the wrong default (`false`), invalidating the policy grant unless explicitly overridden.

This is the exact anti-pattern documented in `memory/feedback_fallback_constant_to_discriminated_union.md` (2026-05-14): when the same decision lives in two places, the duplicate must be deleted, not synchronized.

### 1.3 Why deletion, not patching

A patch path would gate `voice_enabled` toggle through `tool_policy.toml`, or add cascade exemption logic for `keeper_voice_*`. Both *preserve* the fragmentation:

- The flag still exists in `keeper_meta`, persisted across handoffs/compactions, surfaced in keeper status JSON.
- The cascade matcher still has to know about the exemption category.
- Future tool additions repeat the question: "do I need a `_enabled` flag for this tool?"

Per AGENT-LLM-A.md `software-development.md` §Workaround Rejection Bar and `feedback_hardcoding_and_legacy_zero_tolerance` (2026-05-14):

> root-fix PR 같은 머지에서 legacy 함께 삭제, transitional repair/dropped counter 거부.

And per single-consumer condition (no other deployments depend on this surface):

> 변화 크기는 문제가 안됩니다. 잘못된 코드를 남겨두는게 더 큰 문제이고, 소비자가 저 하나이라면 급진적으로 개선의 측면에 방점을 두는게 훨씬 의미가 있습니다.

(User explicit directive, 2026-05-23.)

## §2 Current fragmentation map

### 2.1 Fields to delete from `keeper_meta`

| Field | Type | Persistence | Reason for deletion |
|---|---|---|---|
| `voice_enabled` | `bool` | JSON serialize/deserialize, handoff, compaction | Duplicates `tool_policy.toml` voice-group membership |
| `policy_voice_enabled` | `bool option` | `keeper_types_profile_defaults.ml:18,20,85` + profile.ml:444,511,565,711,712,916,917 | Per-keeper master switch for a *policy-layer* concern — wrong layer |
| `voice_channel` | `string` (sentinel: `"text_only"` / `"voice_text"`) | profile.ml:102 (`canonical_voice_channel`), 120-121 (`default_voice_channel_for`) | Enable/disable encoded as a string sentinel; tool_policy is the truth |
| `voice_agent_id` | `string` (defaults to keeper name or empty) | profile.ml:123-124 (`default_voice_agent_id_for`) | `voice_config.json::agent_voices` keyed by keeper name already maps this; the field duplicates the lookup |

### 2.2 Helpers to delete

`lib/keeper/keeper_types_profile.ml`:

| Symbol | Lines | Reason |
|---|---|---|
| `canonical_voice_channel` | 102-106 | String-sentinel canonicalizer; sentinel itself is being removed |
| `default_voice_enabled_for` | 107-119 | Hardcoded per-keeper voice eligibility — duplicate of policy group membership |
| `default_voice_channel_for` | 120-122 | Derives sentinel from `default_voice_enabled_for`; both go away |
| `default_voice_agent_id_for` | 123-125 | Derives agent_id from `default_voice_enabled_for` + keeper name; redundant |

`lib/keeper/keeper_types_profile.mli`:

| Signature | Lines | Reason |
|---|---|---|
| `val canonical_voice_channel : string -> string` | 34 | Implementation removed |
| `val default_voice_enabled_for : string -> bool` | 35 | Implementation removed |
| `val default_voice_channel_for : string -> string` | 36 | Implementation removed |
| `val default_voice_agent_id_for : string -> string` | 37 | Implementation removed |

`lib/keeper/keeper_types_profile_defaults.{ml,mli}`:

| Field | Lines | Reason |
|---|---|---|
| `policy_voice_enabled : bool option` (mli:20, ml:18, ml:85) | Field removal cascade |

### 2.3 Persistence / serialization sites to update

`lib/keeper/keeper_types_profile.ml` policy_voice_enabled references:

- Line 444 — `bool_ "policy_voice_enabled"` (JSON parse)
- Lines 511, 565 — string key list (likely allowed-keys for canonical JSON)
- Lines 711-712 — overlay merge (`prefer overlay.policy_voice_enabled base.policy_voice_enabled`)
- Lines 916-917 — keeper_json member extraction

All four sites delete cleanly when the field is removed from the record.

### 2.4 Other files in the deletion blast radius

From earlier `rg` survey, 19 files in `lib/keeper/` reference `voice_enabled` / `voice_channel` / `default_voice_enabled_for` / `policy_voice_enabled` / `voice_agent_id`:

```
lib/keeper/keeper_meta_json_parse.{ml,mli}
lib/keeper/keeper_tool_policy.ml
lib/keeper/keeper_turn_up_create.ml
lib/keeper/keeper_turn_up_update.ml
lib/keeper/keeper_turn_up_args.{ml,mli}
lib/keeper/keeper_types_profile.{ml,mli}
lib/keeper/keeper_types_profile_defaults.{ml,mli}
lib/keeper/keeper_persona_authoring.ml
lib/keeper/keeper_schema.ml
lib/keeper/keeper_meta_json.ml
lib/keeper/keeper_meta_contract.{ml,mli}
lib/keeper/keeper_runtime.ml
lib/keeper/agent_tool_persona_runtime.ml
lib/keeper/keeper_types.mli
```

Plus `lib/keeper/keeper_tool_policy.ml:342-346` carries a hardcoded fallback list for the voice group — to be deleted because `tool_policy.toml [groups.voice]` is the SSOT and the fallback is exactly the "Scattered Hardcoded Defaults" anti-pattern from `software-development.md` AI 코드 생성 §1.

### 2.5 Config keys to delete

`<base-path>/.masc/voice_config.json`:

| Key | Reason |
|---|---|
| `local_playback.enabled` | Duplicates `tool_policy.toml` voice-group membership |
| `local_playback.agents` | Same — agents are already determined by who has the voice tool group |
| `session.endpoints` (currently `[]`) | Empty unused slot; bidirectional realtime session bridge not implemented and not within scope |

`agent_voices` and `default_voice_settings` / `agent_voice_settings` stay — they map agent → voice ID / TTS tuning, which is the *legitimate* per-agent customization that doesn't duplicate elsewhere.

### 2.6 Cascade boundary cleanup

`required_tool_names` emission must categorically exclude client-intercepted tools. The dispatching code in `lib/keeper/agent_tool_voice_runtime.ml` is the authoritative list of client-intercepted tool names — the cascade matcher should consult this list (or a typed boundary derived from it) and skip those names when building the provider-capability check.

This is **not** a string blacklist (cf. `feedback_telemetry_as_fix_self_recurrence.md`, RFC-0089). It must be a typed boundary: a `client_intercepted : tool_name -> bool` predicate driven by the same registry that `agent_tool_voice_runtime.ml` pattern-matches against. New client-intercepted tools added in the future are auto-classified.

## §3 Removal inventory (canonical)

10 deletion targets, all in a single PR (no migration shim, no transitional flags, no compatibility layer):

1. `keeper_meta.voice_enabled` field — across `keeper_types*` and all 19 files that reference it.
2. `keeper_meta.policy_voice_enabled` field — across `keeper_types_profile.ml` (7 sites) and defaults.
3. `keeper_meta.voice_channel` field — sentinel removal.
4. `keeper_meta.voice_agent_id` field — duplicate lookup.
5. `default_voice_enabled_for` / `default_voice_channel_for` / `default_voice_agent_id_for` helpers (`keeper_types_profile.ml:107-125`).
6. `canonical_voice_channel` helper (`keeper_types_profile.ml:102-106`).
7. `keeper_tool_policy.ml:342-346` hardcoded voice-group fallback list.
8. `voice_config.json::local_playback` block (`enabled`, `agents`).
9. `voice_config.json::session.endpoints` (empty unused).
10. Cascade matcher's inclusion of client-intercepted tools in `required_tool_names` — typed boundary added that excludes them.

Plus `masc_keeper_up` MCP tool schema: remove `voice_enabled`, `policy_voice_enabled`, `voice_channel`, `voice_agent_id` parameters.

## §4 Deletion sequence

Single PR. No PR-1/PR-2 split because the changes are coupled — removing a field requires updating all its consumers in the same commit for the OCaml type system to remain consistent.

1. Delete record fields from `keeper_types_profile_defaults.ml/mli` and `keeper_types_profile.ml/mli`. OCaml compiler will surface every consumer site.
2. Walk each compiler-flagged site and delete the corresponding read/write/default code.
3. Delete the four helper functions in `keeper_types_profile.ml/mli`.
4. Delete the hardcoded fallback in `keeper_tool_policy.ml`.
5. Update the `masc_keeper_up` tool schema (remove voice-related parameters).
6. Implement the typed boundary in cascade matcher: `Agent_tool_voice_runtime.tool_names : Tool_name.Set.t` exposed and consulted at `required_tool_names` emission.
7. Edit `voice_config.json`: delete `local_playback` and `session.endpoints`.
8. Persisted keeper state cleanup: on startup, the JSON parser silently ignores unknown fields (existing behavior, used for forward compatibility). Existing keeper records carrying the deleted fields read as if the fields are absent. No migration script needed.

## §5 Invariants after deletion

- `rg "voice_enabled|voice_channel|voice_agent_id|policy_voice_enabled|default_voice_enabled_for|canonical_voice_channel" lib/ bin/` → **0 hits**.
- `rg "local_playback" .masc/ lib/` → **0 hits**.
- `keeper_meta` JSON keys: voice-related keys absent.
- `masc_keeper_up` tool schema: voice-related parameters absent.
- `tool_policy.toml [groups.voice]` membership is the sole determinant of voice-tool availability.
- `Voice_bridge.agent_speak` still has exactly one caller (`agent_tool_voice_runtime.ml`).
- Cascade matcher's `required_tool_names` filter rejects no candidate due to voice tool absence.

## §6 Verification

### 6.1 Build & test

- `dune build` clean.
- `dune build @runtest` passes (existing tests touching voice surface will need updates or removal).
- Existing voice unit tests that assert on `voice_enabled` toggling become obsolete and are deleted with the field.

### 6.2 E2E live-fire (sangsu speaks)

Reference path proven on 2026-05-23 via direct ElevenLabs probe (HTTP 200, 81KB mp3, afplay playback). After this RFC's deletion:

1. Persona prompt in `<base-path>/.masc/config/keepers/sangsu.toml`: add one-line guidance — *"가끔 음성으로 한 마디 던져도 된다"* — into `instructions`.
2. Start a normal sangsu turn (no `voice_enabled` flag needed — there is no such flag).
3. sangsu LLM emits `keeper_voice_speak({message: "..."})` per its persona discretion.
4. `agent_tool_voice_runtime.ml` intercepts, calls `Voice_bridge.agent_speak`, which calls ElevenLabs HTTP, returns mp3 bytes, `local_playback` plays via `afplay`.
5. Verify: `character_count` on `https://api.elevenlabs.io/v1/user/subscription` advances; audible output on host speaker; cascade `required_tool_names` for sangsu's turn does **not** contain voice tool names.

### 6.3 Negative checks

- Other keepers (albini, rondo, garnet, echo, etc.) that previously did not voice continue to not voice. Their cascade success rate must be unchanged or improved (improvement possible if voice tools were previously inflating their required set).
- No regression in non-voice tool dispatch — `keeper_bash`, `keeper_board_post`, etc. continue to function.

## §7 Non-goals

- No new voice features. No new tools. No protocol changes. No realtime bidirectional session bridge (the empty `session.endpoints` slot stays empty *and removed*).
- No cascade.toml restructuring (separate concern; sangsu's cascade tier is not touched by this RFC).
- No persona prompt rewrites beyond the optional one-line voice guidance for sangsu in §6.2.

## §8 Risks

| Risk | Mitigation |
|---|---|
| Persisted keeper meta JSON with old fields fails to parse | Existing parser silently ignores unknown fields — verified behavior. No mitigation needed. |
| External dashboard/IDE consumes voice fields | Only consumer is `sb` CLI keeper status, which renders fields opportunistically. Verified no UI dependency on these fields. |
| Hidden caller of removed helper | OCaml compiler surfaces every caller. Exhaustive at build time. |
| Audio output stops working | Not a risk — `agent_tool_voice_runtime.ml` + `Voice_bridge` + `voice_config.json [agent_voices, default_voice_settings]` are *retained*. Only the redundant gates are removed. |

## §9 Acceptance criteria

This RFC is Implemented when:

1. All 10 deletion targets from §3 are committed.
2. `rg` invariants in §5 all return 0 hits.
3. `dune build` and `dune build @runtest` both pass on the resulting tree.
4. §6.2 E2E live-fire succeeds: sangsu autonomously emits voice during a turn, audible output produced, ElevenLabs counter advances.
5. No additional fields, flags, or sentinels added to compensate (counter to §1.3 root-fix principle).

## §10 References

- RFC-0080 — Tool registry SSOT (Implemented). Voice tools are part of the tool registry; this RFC removes the parallel keeper-side voice surface to keep RFC-0080's SSOT clean.
- RFC-0088 — Counter-as-Fix umbrella (Active). This RFC adheres: no telemetry/counter introduced; only deletion.
- RFC-0157 — Cascade pre-turn required-tool filter (Active). This RFC fixes RFC-0157's input categorization — client-intercepted tools never enter the filter.
- `software-development.md` §Workaround Rejection Bar, §AI 코드 생성 안티패턴 §1 (Scattered Hardcoded Defaults).
- `memory/feedback_fallback_constant_to_discriminated_union.md` (2026-05-14).
- `memory/feedback_hardcoding_and_legacy_zero_tolerance.md` (2026-05-14).
- Live evidence: 2026-05-23T11:26Z system_log entry showing cascade_exhausted on voice_enabled=true.
- User directive 2026-05-23: "변화 크기는 문제가 안됩니다 ... 소비자가 저 하나이라면 급진적으로 개선의 측면에 방점."
