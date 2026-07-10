# RFC-0329 — Excise the payload-blind Execute governance gate: typed Shell-IR risk with fail-closed de-escalation and a typed exemption acceptance bar

- Status: Draft — no active code exemption; the unsafe partial implementation from PR #23761 was removed on 2026-07-10
- Date: 2026-07-08
- Type: Governance structural change (security-sensitive; isolated from the incident fix on purpose)
- Scope: `lib/governance_pipeline_risk.ml`, `lib/governance_pipeline.ml`, `lib/keeper/keeper_guards.ml`, `lib/tool/tool_catalog.ml`, and the `MASC_SHELL_IR_APPROVAL_GATE_ENABLED` flag path.
- Companion: RFC-0328 owns the perseveration-engine fixes (memory grounding + purge, failover + stagnation) and is the incident fix. This RFC removes the operative gate structure. It is deliberately NOT bundled with RFC-0328: it loosens a safety wall and must land behind its own adversarial review and fail-closed default. It is not required to stop the `mad-improver` loop (the keeper never ran shell; `tool_calls=0`).
- Cross-references: RFC-0091, RFC-0126, RFC-0131, RFC-0160, RFC-0208, RFC-0254, RFC-0255, RFC-0304, RFC-0309, RFC-0312, RFC-0321, RFC-0001.

> **Implementation correction (2026-07-10).** Sections 3 and 4 are future
> design, not live behavior. The raw keeper-name environment exemption from
> PR #23761 was removed after audit found that it neither narrowed the bypass
> to a typed tool category nor emitted an exemption audit event. Reintroduction
> requires follow-up issue [#23906](https://github.com/jeong-sik/masc/issues/23906)
> and security review.

---

## 1. Problem — a granted capability that is unconditionally blocked

A keeper is granted the `tool_execute` tool in its `tool_access`. The governance gate then blocks every use of it, unconditionally, in a way HITL cannot resolve. The structure is:

1. `tool_execute` is force-marked destructive in the catalog (`static_destructive_tool_names` includes `"tool_execute"`, `tool_catalog.ml:183-184`, applied via `force_true_if_member` `:416`), so `classify_with_metadata "tool_execute"` returns `Some Critical`. Independently, `risk_of_keeper Execute -> Critical` (`governance_pipeline_risk.ml:141`) is unconditional. Either source alone makes the risk Critical, ignoring the command payload.
2. `keeper_guards.governance_approval_guard` (`keeper_guards.ml:944-963`) computes `hard_forbidden = auto_approval_hard_forbidden ~risk = (risk = Critical || runtime_auto_approval_blocked)` (`governance_pipeline.ml:104-105`). For Critical this is true, and the guard returns `Agent_sdk.Hooks.Block` with reason "hard_forbidden: unconditional block regardless of HITL mode" (`:958`) — before the tool handler runs.
3. There is no active exemption path. A prior attempt read keeper names from `MASC_CODE_EXEMPT_KEEPERS` and bypassed the generic `needs_approval` branch, but it was removed because the decision was not scoped to a typed code-tool category and was not audited. Critical Execute remains blocked before any future exemption point.

Net: no keeper can run any shell command — `git status` and `rm -rf /` alike — and no HITL approval can change that. A capability that is always blocked is not a capability. This is the "weird structure" the incident (RFC-0328) exposed; `mad-improver` correctly observed "Execute is blocked" and then confabulated a repo-mapping cause because the true structure is invisible to the keeper.

The already-built typed classifier that *can* tell `git status` from `rm -rf /` — `Masc_exec.Shell_ir_risk` (closed sum `R0_Read | R1_Reversible_mutation | R2_Irreversible | Destructive_protected`, `shell_ir_risk.mli:10-14`) plus the handler-level `Approval_policy`/`catastrophic_floor` (RFC-0254, Active) — lives *inside* the handler and is categorically unreachable for the governance decision (`rg 'Shell_ir|Approval_policy|R0_Read' lib/governance_pipeline*.ml` = 0 hits). The cruder gate runs first and shadows the typed one.

---

## 2. Design invariants (hard constraints)

1. **Remove, don't accrete.** The fix excises the payload-blind Critical sources for `tool_execute` and the hardcoded-`false` exemption. It does not bolt a read-only allowlist on top of the unconditional-Block structure. Adding an allowlist while leaving the blanket Critical standing is addition-not-removal (workaround checklist #4) and is rejected.
2. **No hidden hardcoding.** No read-only command string/prefix list, no per-binary exemption ladder, no hardcoded keeper allowlist. The read-only decision is derived from the parsed typed Shell-IR AST; the code-capable-keeper decision is read from typed configuration.
3. **Parse, don't validate.** The risk is decided over the parsed `Shell_ir.t`, never over substrings of the command string.
4. **Fail closed on Unknown.** Any command that does not parse to a fully typed, provably-read-only AST is Critical. De-escalation is the exception that must prove itself, not the default.
5. **Do not weaken the deterministic gate to accommodate a non-deterministic model.** The keeper being a weak model (RFC-0328's provider outage) is not a reason to relax governance; the relaxation is justified only by the payload being provably read-only (RFC-0001 det/non-det boundary intact).

---

## 3. Gap A — payload-aware Execute governance via the typed Shell-IR classifier

Route the keeper Execute governance risk through the existing typed Shell-IR classifier instead of the coarse tool-name Critical. In `Governance_pipeline_risk.assess_risk` / `baseline_risk`, special-case `tool_execute`: lower the command payload to `Shell_ir.t` using the RFC-0091 typed-argv producer the handler already uses (`Exec_policy.parse_string_to_ir` / `to_shell_ir`), then decide.

### 3.1 The de-escalation is fail-closed — `classify` alone is NOT sufficient

This is the correction that an adversarial pass forced, and it is the load-bearing part of the RFC. `Shell_ir_risk.classify`'s `risk_class` axis does **not** by itself mean "safe": it returns `R0_Read` for cases that must never be auto-run, verified in `lib/exec/shell_ir_risk.ml`:

- `Generic` escape hatch (`:1169`)
- non-literal argv where `literal_words_of_simple = None` (`Var`/`Concat`, floor-None `:1267-1270`)
- `Gh_unrecognized_action` / `Gh_verb.Other` (`:730`, `:1226`)
- `Docker` (`:1158`), `Awk` with `system()` (`:1165`)
- unknown/interpreter heads not otherwise typed (perl, ruby, php, osascript, deno, bun, Rscript, `tar --to-command`)

Mapping `R0_Read → Low` flatly would let `awk 'BEGIN{system("...")}'`, `perl -e`, an unknown binary, `$VAR`-bearing argv, or a compound `git status; rm -rf /` slip below the `hard_forbidden` Critical line. That is fail-open. The claim in an earlier draft that "these already fail closed to Critical inside classify" is false and is corrected here.

De-escalate below Critical **only when both** conditions hold:

```
governance_risk(tool_execute, cmd) =
  match Exec_policy.parse_string_to_ir cmd with
  | Error _ | Too_complex        -> Critical            (* ; && || $() subshell backgrounding *)
  | Ok ir ->
    if not (Shell_ir_risk.typed_hit_of_ir ir)          (* every Simple node lowered to a real typed constructor *)
    then Critical                                       (* Generic / non-literal argv / unknown head *)
    else match Shell_ir_risk.classify ir with
      | R0_Read              -> Low
      | R1_Reversible_mutation -> High                  (* see 3.2 — hits the approval floor, never auto-run *)
      | R2_Irreversible
      | Destructive_protected -> Critical
```

An explicit pre-filter maps parse failure, `Too_complex`, non-`typed_hit` nodes, and the `gh` capability escape hatches to Critical before `classify` is trusted. In addition, consume the capability axis the handler substrate already uses for unknowns — `Gh_capability_policy.disposition_of` (`Requires_approval` / deny for unrecognized `gh`) — or replicate its fail-closed disposition, so an unrecognized `gh` subcommand cannot ride `R0_Read` to Low.

This removes both payload-blind Critical sources for `tool_execute` (the `Tool_catalog` destructive override and `risk_of_keeper Execute`) and replaces them with a decision that is Critical by default and Low only for a provably typed read-only command.

### 3.2 `R1_Reversible_mutation` must hit an approval floor, not auto-run

At production, `keeper_confirm_threshold` is High, so a Medium risk returns `Continue` (auto-run) at the governance guard. A reversible mutation (`git commit`, `sed -i`, `curl`, `ssh`, `scp`, `rsync`, `git pull`) mapped to Medium would therefore auto-run ungated. Map `R1_Reversible_mutation → High` so it reaches the approval floor, OR prove the downstream handler `Approval_policy` gates R1 for keepers before relying on it. This RFC takes the former (High) as the fail-closed default; the latter is an open question to verify, not an assumption.

### 3.3 Flag audit — do not create a net loosening

Before removing the governance blanket-Critical, audit `MASC_SHELL_IR_APPROVAL_GATE_ENABLED` and the keeper trust-overlay state. If the handler-side typed gate can be disabled while governance stops blocking, then `R0`/`R1` Execute could silently auto-run at the handler once governance no longer blocks it — a net loosening. Landing Gap A is gated on that flag being enforced-on for keepers (or on the handler gate being unconditional for keeper Execute). If the flag can be off, this RFC does not land.

### 3.4 Boundary / dependency check (verified, no inversion)

`governance_pipeline_risk.ml` is in the `masc` library, which already depends on `masc.masc_exec` (`lib/dune:280`). `lib/exec/dune` has no governance dependency (`rg governance lib/exec/dune` = 0 hits), so `masc_exec` does not depend on governance — no cycle. The change is a wiring/unification reusing an already-built substrate, completing the RFC-0160 "single decision substrate" goal for the governance layer.

### 3.5 Why this is not a workaround

It removes two classifiers (the catalog destructive override and `risk_of_keeper Execute`) and delegates to a closed sum with an exhaustive match, so adding a new `risk_class` or command constructor forces a deliberate mapping at compile time. It adds no read-only prefix allowlist (signature #2), no per-binary exemption ladder (signature #3 / the accreting pattern RFC-0255 §2.2 documents), and no blanket exemption flip. The de-escalation is fail-closed by the `typed_hit` gate; the only commands that go below Critical are those the typed AST proves are read-only.

---

## 4. Gap B — no active exemption; typed reintroduction deferred

**Current production-safe state (verified 2026-07-10).**
`governance_approval_guard` has no keeper-name exemption. Critical decisions
take the `hard_forbidden` Block branch, and every remaining decision at or above
the keeper confirmation threshold returns `ApprovalRequired`.

**Removed unsafe attempt.** PR #23761 added `MASC_CODE_EXEMPT_KEEPERS` as a
space-split set of raw keeper-name strings. The generic approval branch checked
only membership in that set: it did not parse a typed keeper identity, did not
match a typed tool category or payload disposition, and did not emit an
exemption audit event. Consequently, a listed keeper could bypass unrelated
High-risk tools while the catalog's Critical classification still blocked the
actual Execute/Edit/Write code paths before the exemption check. That mechanism
was removed rather than patched with another string classifier.

### 4.1 Acceptance bar for a future implementation

A future exemption requires [#23906](https://github.com/jeong-sik/masc/issues/23906)
and security review. It must use a
typed keeper capability and a typed tool/effect category, fail closed on
missing or malformed configuration, remain unreachable for Critical decisions,
and emit a distinct auditable exemption decision. It must not reintroduce a raw
keeper allowlist, command substring test, or generic `needs_approval` bypass.

---

## 5. Proposed-design workaround-bar and no-hardcoding self-check

The checks below are acceptance criteria for a future implementation, not a
description of the live guard.

1. **makes-visible-only.** The proposed changes must alter control flow (risk mapping, exemption source), not only add visibility.
2. **string/substring classifier added.** Not tripped. Read-only is a typed shell-AST predicate (`R0_Read` + `typed_hit_of_ir`), never a command string list.
3. **N-of-M.** Gap A must remove both payload-blind Critical sources in one place; a future Gap B must introduce one typed config axis, not per-keeper edits.
4. **catch-all `_ ->` added.** Not tripped. Non-decidable arms map to Critical (fail-closed); the closed-sum mappings force a compile-time decision on new constructors.
5. **cap/cooldown/dedup/repair.** Not tripped.
6. **test backdoor.** Future tests must drive the classifier through real command inputs and the exemption through its real typed configuration.
7. **same fix N sites.** Not tripped. The read-only decision exists in exactly one substrate (`Shell_ir_risk`), consumed by both gates.

Hidden-hardcoding acceptance bar: Gap A may have no command string list (typed
AST), and a future Gap B may have no raw keeper-name list. The `R1 → High`
mapping and the `typed_hit` gate are structural, not magic numbers. Nothing may
regress to a hardcoded allowlist.

Override clause: this is a security-loosening change, not production-blocking; it lands only with the §3.3 flag audit satisfied and its own adversarial review, never bundled under an incident umbrella.

---

## 6. Verification plan

### 6.1 Read-only classifier through the governance path (Gap A)

Exercise `Governance_pipeline_risk.assess_risk ~tool_name:"tool_execute"` (the wiring), not only `Shell_ir_risk.classify` (the substrate):

- Below Critical (must NOT hard_forbidden): `git status`, `git log --oneline -5`, `git diff`, `ls`, `cat FILE`, `rg PATTERN`, `gh pr view 123`, `gh pr diff 123` → Low.
- Fail-closed to Critical (the actual risk surface — these are the tests the earlier draft omitted): `awk 'BEGIN{system("id")}'`, `perl -e '...'`, `ruby -e '...'`, `tar --to-command ...`, `docker run ...`, an unknown binary, `gh <unknown-subcommand>`, `$VAR`-bearing argv, and the compound `git status; rm -rf /` → each ≥ Critical.
- Known-destructive to Critical: `rm -rf /`, `git push --force`, `mkfs...`, `sed -i ...`, any `$( )` substitution, `curl ... | sh` → Critical.
- R1 floor: `git commit`, `curl https://...`, `ssh host` → High (reaches the approval floor), asserted to NOT auto-run at production `keeper_confirm_threshold`.

### 6.2 Exemption (Gap B)

- The retired `MASC_CODE_EXEMPT_KEEPERS` value has no effect: a High-risk non-code tool still returns `ApprovalRequired`.
- Critical Execute remains Block even when the retired environment variable names the current keeper.
- Any future typed exemption must prove that only its explicit typed code-tool category can continue and that exactly one exemption audit event is emitted.

### 6.3 Flag audit (Gap A gating)

A test/assertion that with `MASC_SHELL_IR_APPROVAL_GATE_ENABLED` off (if reachable), keeper `R0`/`R1` Execute does not silently auto-run once governance stops blocking — i.e. the handler gate is enforced-on for keepers, or Gap A does not land.

---

## 7. Cross-references

| RFC | Status | Relation |
|-----|--------|----------|
| RFC-0328 (companion) | Draft | The incident fix (memory + failover + stagnation). This RFC is the isolated governance-structure change; RFC-0328 does not depend on it. |
| RFC-0160 shell-ir-first-class | Implemented | Established Shell-IR as the single decision substrate in the exec runtime; Gap A completes that for the governance layer. |
| RFC-0208 shell-ir-compositional-risk-ast | Draft | Owns the compositional risk AST with `R0_Read`; Gap A consumes it. |
| RFC-0091 execute-typed-argv | Implemented | Provides the typed argv → `Shell_ir` lowering Gap A reuses; each argv token is literal by construction, which is why a typed classifier (not substring) is the correct basis and why non-literal argv must fail closed. |
| RFC-0254 shell-ir-approval-autonomous-policy | Active | The landed handler-level typed gate that already allows `git status` but runs downstream of and is shadowed by the governance Block. Gap A lifts its typed verdict up into the PreToolUse risk assessment. |
| RFC-0255 shell-ir-path-typed-scope-and-floor-narrow | Draft | Documents the per-binary string-exemption ladder as the N-of-M fail-open pattern to avoid (§2.2). |
| RFC-0131 shell command gate facade | referenced | The handler-side gate facade, structurally separate from `governance_approval_guard`; confirms the two-gate split Gap A unifies. |
| RFC-0321 hard-forbidden-typed-error | Draft/impl | Made `hard_forbidden` a typed `Block`; its open-question #3 (dual risk evaluation) is exactly the governance-vs-ShellIR shadowing Gap A fixes. |
| RFC-0304 hitl-critical-bounded-escalation | Draft | Its Defer/escalation applies to the ApprovalRequired path, which Critical Execute never reaches (it Blocks first). After Gap A, R1/High Execute reaches that path. |
| RFC-0309 typed-gh-capability-gating | Draft | The `gh` capability axis Gap A §3.1 consumes for unrecognized subcommands (`Gh_capability_policy.disposition_of`). |
| RFC-0312 keeper-repo-mapping-advisory-scope | Accepted | Confirms repo mappings are advisory and non-gating; Gap A/B must not re-introduce a hidden cap 0312 removed. |
| RFC-0126 silent-fallback-discipline | Implemented | The fail-closed discipline Gap A honors (Unknown → Critical, never a permissive default). |
| RFC-0001 det-nondet-boundary-harness | — | The boundary Gap A must keep intact: the deterministic governance gate is relaxed only for provably-read-only payloads, not to accommodate a weak non-deterministic model. |

---

## 8. Open questions

- `R1_Reversible_mutation` governance mapping: High (this RFC's fail-closed default) vs proving the handler `Approval_policy` gates R1 for keepers and mapping to Medium. Verify the handler path before choosing Medium.
- Scope of the first landing: keeper `tool_execute` only, or also operator/agent `tool_execute` governance risk through Shell-IR.
- `typed_hit_of_ir` exact semantics for multi-node pipelines and redirections (RFC-0198): confirm a pipeline is `typed_hit` only if every node is typed-and-read-only.
- Follow-up issue [#23906](https://github.com/jeong-sik/masc/issues/23906) must define the typed code-capability schema, default, tool/effect scope, and audit event before any exemption is reintroduced; there is no active `Env_config_core` exemption schema.
- The `MASC_SHELL_IR_APPROVAL_GATE_ENABLED` enforcement state for keepers — the §3.3 gating precondition.
