# RFC-0284: Keeper Guidance Visibility-Leg Drift Guard

**Status**: Draft
**Date**: 2026-06-23
**Builds on**: [RFC-0254](./RFC-0254-shell-ir-approval-autonomous-policy.md) (autonomous lane has no `Ask` resolver — a blocked operation must return an actionable verdict, not a dead end)
**Related**: [RFC-0239](./RFC-0239-keeper-no-progress-loop-detector.md) (no-progress loop detector that this drift silently defeats); Tool Orchestration Lane design note (`docs/design/tool-orchestration-lane.md` §1, tracking issue #21517 — schema↔dispatch↔visibility drift guard as the first slice); [RFC-0042](./RFC-0042-keeper-terminal-code-closed-sum.md) (no-string-classifier lineage)
**Tracking**: tool-constraint adversarial audit (2026-06-23)

## 1. Summary

A keeper that needs a repository cloned receives a recovery message instructing it to "First clone a repo with the visible clone tool" (`keeper_tool_execute_command_semantics.ml:283-287`). No such tool exists in any keeper surface — `clone` is only the internal `repo_manager/repo_git.ml:63` function, never exposed as a schema entry, and `keeper_hooks_oas.ml:196` confirms all keepers receive the full tool set unconditionally (there is no per-role gating). The contract names a capability the keeper cannot dispatch, so the model fills the gap by inventing a phantom tool call and escalating into the room.

This is one instance of a broader class: **guidance/error/recovery text emitted in a schema-allowed context references a tool that does not resolve to a dispatchable surface.** The SSOT for schema-allowed name rendering already exists (`Keeper_tool_visibility_projection`, with `render_reference` / `blocker_guidance` that convert an unbound reference into a blocker-report), and its `.mli` claims "the consumer migration is complete." That claim is false: the producer above does not route through the module (zero references), so the projection cannot intercept the phantom. No test, lint, or boot check asserts the invariant, so the phantom ships uncaught — and a forward-assertion test (`test_keeper_sandbox_docker_route.ml:1452`) pins the broken string as expected, contractually locking the lie in place.

This RFC defines the invariant and lands the first enforcement slice: fix the confirmed live phantom and add a regression seam at its producer, so re-introducing a phantom recovery string at this site fails a test rather than reaching a keeper.

## 2. Context & evidence

### 2.1 The named incident (albini)

A PM keeper (`albini`, `active_goal_ids=[goal-pm-flow]`, `current_task_id=null`) needed `jeong-sik/masc` cloned. Its live trajectory (`<base-path>/.masc/trajectories/albini/trace-1781224572742-00000.jsonl`) hit the recovery string repeatedly (`"no sandbox git clones"` ×13, `"clone a repo with the vis…"` ×21, `"visible clone tool"` ×6) and responded with `clone` ×98 and `@operator` ×29. The keeper itself used the word `phantom` ×42, recognising it was inventing calls. It also confabulated a cause — "I'm a PM, I don't have tools to provision" — which is wrong: the clone capability is absent for every keeper, not gated by role. The missing capability forced a fleet-wide workaround (publishing source over the board so each keeper recreates files in its own sandbox), a real operational cost beyond one keeper's thrash.

### 2.2 The defect

`resolve_sandbox_root_git_cwd` builds two recovery messages:

- `many` branch (`keeper_tool_execute_command_semantics.ml:296-303`): names a real, dispatchable affordance — `Execute { "executable": "git", "argv": ["status"], "cwd": … }`. This is the correct pattern.
- `[]` branch (`:283-287`): names "the visible clone tool", which is not a tool. This is the phantom.

`test_sandbox_root_git_clone_allowed_from_root` (`test_keeper_sandbox_docker_route.ml:1456-1464`) proves the honest affordance is real: `git clone <url> repos/<repo>` from the sandbox root via the Execute tool returns no routing error. The `[]` branch could have pointed at exactly this, plus the operator-provisioning resolver the keeper actually reached for.

### 2.3 Why the existing machinery did not catch it

`Keeper_tool_visibility_projection` is the SSOT and provides `render_reference ~context:Schema_allowed` (unbound/unknown names expand into a blocker-report) and `blocker_guidance`. Its surviving consumers are `mcp_server_eio_execute` and `keeper_run_tools_setup`; the producer at `keeper_tool_execute_command_semantics.ml` is not one of them. Enforcement is voluntary — nothing asserts that other modules route their schema-allowed guidance through the projection. The previous no-op `tool_registration_check.ml` placeholder has been removed; the real boot invariant (`unified_tool_registry.enforce_visible_tag_coverage`) checks only schema↔dispatch-tag presence, never the visibility leg.

## 3. Invariant

> For any string emitted in a `Schema_allowed` context, every tool the string instructs the keeper to call must resolve to a dispatchable surface on the current turn. A capability with no dispatchable tool must be rendered as a blocker-report (state the blocker and the real resolver), never as an imperative to call a non-existent tool.

Corollary for the `[]` branch: when no repo is cloned and no clone tool exists, the recovery message must (a) state that no clone tool is available, (b) name the real affordance (`git clone` via the Execute tool, egress permitting), and (c) name the real resolver (operator provisioning) so the keeper reports the blocker instead of inventing a call.

## 4. Scope

### 4.1 This PR (enforcement slice 1)

1. Rewrite the `[]`-branch recovery message to satisfy §3: remove the phantom "visible clone tool"; name the Execute affordance and the operator-provisioning resolver. Keep the existing true substrings (`no sandbox git clones`, `cwd="repos/<repo>"`).
2. Replace the pinned forward-assertion (`test_keeper_sandbox_docker_route.ml:1451-1452`) so it asserts the honest properties instead of the phantom.
3. Add a regression-seam test over the zero-repo (`[]`) recovery message: assert it names the real `Execute` affordance, and that every "… tool" noun it contains is `Execute` — a closed invariant over the tool noun, not a blocklist of known-bad phrasings (keeps the seam consistent with the RFC-0042 no-string-classifier lineage). Re-introducing a phantom `<X> tool` at this producer then fails the test. The `many` branch never contained a phantom and is not exercised by this seam; the string seam also cannot catch a phantom phrased without the word "tool" — full cross-producer enforcement is the §4.2 `render_reference` routing.

### 4.2 Follow-up (out of scope here)

- A cross-module guard that scans every schema-allowed guidance producer for unresolved tool references, or routes them through `render_reference`. The general form requires either a curated registry of guidance producers or a lint over guidance-emitting functions; deferred to keep this slice provable.
- The handler-coverage leg (E4): assert every visible schema name resolves to a non-`None` dispatch site, replacing the `keeper_tool_surface` string-match (`_ -> None` catch-all) with an exhaustive closed sum mirroring the keeper-internal descriptor path. Tracked separately under the Tool Orchestration Lane drift-guard work (#21517).
- A provisioning resolver / typed `Network_blocked` deterministic reason for the sandbox-clone dead end (audit findings C1/C2), gated by RFC-0254 + RFC-0219; separate RFC.

### 4.3 Superseded — zero-repo routing constraint removed (RFC-0219 extension, PR #22126)

§4.1 landed an honest-blocker recovery message for the zero-repo `[]` branch. PR #22126 supersedes that slice by removing the zero-repo routing constraint itself, so the recovery message is no longer emitted. Both address the §2.1 albini phantom; #22126 removes it by deleting the constraint and the prompt rather than rewriting the prompt.

**Decision.** The zero/single/many repo-count routing in `resolve_sandbox_root_git_cwd` is an unnecessary constraint plus an unnecessary prompt. Inside the keeper sandbox mount, git/gh run from the root and fail or succeed naturally. The only remaining preflight is validation of explicit `-C` paths (missing targets still surface before `docker exec`).

**Recovery path (no guidance string).** When a keeper runs `git status` from the sandbox root with no repo cloned, git itself returns "not a git repository". The keeper recovers via the RFC-0198 typed `cwd` Execute affordance: `Execute { "executable": "git", "argv": ["clone", <url>, "repos/<repo>"] }`, then retries with `cwd="repos/<repo>"`. The dispatchable affordance exists, so no model-facing recovery string is needed.

**albini reinterpreted.** §2.1's thrash was caused by the phantom "visible clone tool" (a non-existent tool the message named), not by the absence of guidance. #22121 replaced the phantom with the real Execute affordance; #22126 removes the message entirely. Either resolves the phantom, but #22126 is more fundamental — it deletes the constraint that forced the prompt in the first place.

**RFC-0219 scope extension.** RFC-0219 removed `validate_cwd_ready` / `validate_path_args_ready` repo-patrol gates because they deadlocked keepers that need Execute to self-heal. The zero/single/many routing branch is the same class — a pre-emptive gate ahead of git/gh execution. #22126 completes that removal.

**Monitoring, not precondition.** The raw-error → Execute-clone recovery pattern is observable via RFC-0239 (no-progress loop detector). If thrash recurs, the §4.2 provisioning resolver (typed `Network_blocked`) is the fallback — it is not a blocking precondition for removing the constraint. Removing the prompt is the SSOT; the resolver remains a follow-up.

**Reconciles** the 13-minute landing collision: #22121 (03:51Z, §4.1 honest message) and #22126 (constraint removal) touched the same `[]` branch of `resolve_sandbox_root_git_cwd`. This section records #22126 as the surviving policy and retires §4.1's "keep the message" instruction.

## 5. Verification

- `test_sandbox_root_git_cwd_zero_repo_blocks_before_exec` updated and green: message contains `no sandbox git clones`, `cwd="repos/<repo>"`, names the Execute tool, and does not contain `visible clone tool`.
- New regression-seam test green: the zero-repo recovery message names `Execute` and every "… tool" noun it contains is `Execute`.
- `test_sandbox_root_git_clone_allowed_from_root` remains green (the honest affordance the new message points at is still permitted).
- `dune build` for the affected libraries and the focused test executable.

## 6. Risks & trade-offs

- The slice is narrow: it fixes the one confirmed live phantom and a regression seam at its producer, not every possible guidance string. This is deliberate — a generic cross-module guard is the §4.2 follow-up. The risk is that another producer introduces a phantom that this seam does not cover; mitigated by the seam being reusable per-producer and by the invariant being stated for the follow-up to enforce broadly.
- Editing the recovery wording changes a model-facing string. The accompanying test update is required so the change does not break the pinned assertion; this is intended (the pin encoded the defect).
- No behavioural change to dispatch or sandbox routing — only the recovery text and its tests change.
