# RFC-0019: Keeper Credential Unification

- **Status**: Draft
- **Author**: vincent (with Claude Opus 4.7 1M, exploratory session)
- **Created**: 2026-04-30
- **Supersedes context for**: `~/me/planning/claude-plans/fancy-prancing-thompson.md` (2026-04-30, retired — built without awareness of #12304)
- **Related**: RFC-0008 (Credential Provider trait), PR #10660 (RFC-0008 PR-1 merged 2026-04-26), PR #12304 (multi-repo architecture merged 2026-04-30 12:37)
- **Drives**: Reconcile two parallel credential architectures shipped 4 days apart with zero integration; restore F-1 invariant; close end-to-end provisioning flow; install a process safeguard so this class of split-brain cannot recur silently
- **Evidence record**: `~/me/knowledge/research/2026-04-30-keeper-credential-architecture-state.md`

## 1. Problem (field-verified 2026-04-30)

The user observed a concrete symptom: `gh search prs --owner yousleepwhen --author anyang-keepers` returns zero results across 8 days. Investigation revealed not the expected single-cause failure but **two completely isolated credential subsystems** living in the same codebase:

- **Architecture A** (RFC-0008 PR-1, #10660, 2026-04-26) — keeper-centric, filesystem-bundle SSOT.
- **Architecture B** (#12304, 2026-04-30 12:37) — credential-record-centric, TOML SSOT.

Architectures A and B share **zero code paths** (verified by exhaustive `rg` cross-references). They have **two different storage SSOTs** (`<base>/.masc/github-identities/<id>/gh/` filesystem vs. `<base>/.masc/config/credentials.toml`). They expose **two different operator UX surfaces** (operator-control plane action handlers vs. dashboard HTTP API). They have **two different conceptual models** of what a "keeper credential" means.

End-to-end check (research synthesis §5) shows **all five user-facing acceptance criteria FAIL** post-#12304: the merge added repository-level RBAC scaffolding without touching the path that actually fails for the user.

Worse: §7 of the synthesis shows the combined main has **regressed F-1 and F-4** posture relative to RFC-0008 alone, because B introduces `gh_config_dir` HTTP exposure (B-R1), unsanitized path POSTs (B-R2), and a second source of truth that A does not know about (B-R5).

## 2. Why two ships in 4 days (process root cause)

Both PRs were committed by jeong-sik (Vincent). RFC-0008 PR-1 was *human-authored* with full RFC discipline (`docs/rfc/RFC-0008-credential-provider.md` + pre-RFC evidence record). #12304 was *agent-co-authored* (`Co-Authored-By: Claude Sonnet 4.6` across 5 commits, ~4,600 LOC) with **zero references** to RFC-0008, `Credential_provider`, `keeper_gh_env`, or `Host_config_provider` in any commit message or any of the changed files.

The workflow rule (`~/me/instructions/workflow.md:21-31`):

> 연구가 아무리 좋아도 RFC 없이 코드에 반영하지 않는다.

is a Korean-language markdown instruction. It is **not** a hook, **not** a CI check, **not** a PR template requirement. There is no operationalized enforcement layer that would have flagged "this is touching the keeper credential subsystem; RFC-0008 already exists here". This RFC ships a fix for that gap as well as the architecture (§7).

## 3. Design principles

### 3.1 Inherited from RFC-0008 (preserved)

| # | Principle | Why |
|---|---|---|
| P1 | **The credential boundary IS the token.** Two identities with the same token share capabilities, regardless of labels. | F-1 invariant. Any "identity separation" weaker than per-token enforcement is cosmetic. |
| P2 | **Provider owns lifecycle.** `resolve → finalize → tear_down` is the complete cycle. | F-4 invariant. Rotation must be one transactional unit. |
| P3 | **Ship Option A first, gate Option B.** Host-mounted bundle works today. In-container login waits for fine-grained PATs. | Coupling two unrelated risks delays both. |
| P4 | **Reuse `keeper_binding`.** Wrap, do not replace. | The resolver is the right abstraction; the *registry* is what changes. |

### 3.2 New (introduced by this RFC)

| # | Principle | Why |
|---|---|---|
| P5 | **Single SSOT for credential records.** Exactly one writable source of truth. Filesystem layout is a *materialization*, not a registry. | A and B both claim ownership today — irreconcilable. |
| P6 | **Identity binding is `f(keeper, repo) → credential_id`, not `f(keeper) → credential_id`.** A keeper may legitimately use credential X for repo Y and credential Z for repo W. | A's "one keeper = one identity" model is strictly narrower than reality. B encodes this correctly via `keeper_repo_mapping`. |
| P7 | **Materialization is a registry side effect, not a separate operator ritual.** `Credential_store.add` MUST invoke a materializer hook that creates the filesystem bundle (or marks the credential as `unmaterialized` until operator completes OAuth). | Today, dashboard "credential add" succeeds while the filesystem bundle never exists. False positive. |
| P8 | **Operator UX completeness is a CI gate, not a docs request.** End-to-end test "operator runs UX flow → keeper successfully creates a PR" is required for any change to the credential subsystem. | The synthesis showed the dashboard ships a "complete" toast while the keeper still fails-closed. This is a class of failure that only e2e testing catches. |
| P9 | **No agent PR in this subsystem without prior RFC reference.** Agent-delegated PRs touching `lib/keeper/`, `lib/repo_manager/`, `lib/operator/`, or `dashboard/src/components/credential-settings.ts` MUST cite an RFC in the PR body or be rejected by a pre-merge hook. | Process root cause §2. The agent had no signal to discover RFC-0008 and produced parallel work. Future-proofing. |

## 4. Unified architecture

### 4.1 Layered model

```
┌─────────────────────────────────────────────────────────────────┐
│  Operator UX                                                    │
│   • Dashboard: credential-settings.ts, keeper-repo-mapping.ts   │
│   • CLI: scripts/keeper-credential.sh                           │
│   • MCP tool: masc_keeper_github_identity_login_prepare         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Operator-control plane (lib/operator/operator_control.ml)      │
│   • Risk gate (Operator_approval)                               │
│   • Audit emission (server_routes_http_routes_activity)         │
│   • Confirms via dashboard (Operator_pending_confirm)           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Credential registry — SINGLE SSOT (lib/repo_manager/)          │
│   • credential_store.ml: TOML add/get/remove                    │
│   • keeper_repo_mapping.ml: binds (keeper, repo) → credential   │
│   • + materializer hook (NEW): on add, ensure gh_config_dir     │
│     bundle exists on disk; emit unmaterialized status if not    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Credential provider — TRAIT (lib/keeper/credential_provider)   │
│   • Host_config_provider: reads from Credential_store now       │
│     (was: read from filesystem only)                            │
│   • In_container_login_provider: gated by F-1 SHA check         │
│   • binding type unchanged (P4)                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Keeper consumption (lib/keeper/keeper_shell_*.ml)              │
│   • keeper_shell_docker.ml: unchanged at call site              │
│   • keeper_shell_gh_context.ml: routes per-repo via mapping     │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Materialization (filesystem; derived, not authoritative)       │
│   <base>/.masc/github-identities/<credential.id>/gh/            │
│   ↑ created by materializer hook in §4.4                        │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 Unified data model

`Credential_store` becomes the single registry. Its existing record is augmented with two fields:

```ocaml
(* lib/repo_manager/repo_manager_types.mli — proposed *)

type credential_state =
  | Unmaterialized   (* registered but no bundle on disk; gh will fail *)
  | Materialized of { last_verified_at : float (* unix ts *) }
  | Stale of { reason : string }

type credential = {
  id            : string;
  cred_type     : credential_type;     (* Github | Gitlab | Local *)
  username      : string;
  gh_config_dir : string option;
  ssh_key_path  : string option;
  gpg_key_id    : string option;
  state         : credential_state;    (* NEW *)
  token_sha256_prefix : string option; (* NEW — for F-1 gate, never the full token *)
}
```

`Credential_provider.binding` (RFC-0008 trait) is unchanged in shape (P4). What changes is the *resolver* — `Host_config_provider.resolve` now reads from `Credential_store` first:

```ocaml
(* lib/keeper/host_config_provider.ml — proposed change *)

let resolve ~config ~identity:keeper_name =
  (* NEW: ask Credential_store via keeper_repo_mapping *)
  match Keeper_repo_mapping.credentials_for_keeper config ~keeper_name with
  | [credential] ->
      (* simple case: 1 keeper, 1 credential *)
      bind_from_credential ~config ~keeper_name credential
  | [] ->
      (* fallback: legacy keeper_types_profile.github_identity path *)
      legacy_bind ~config ~keeper_name
  | many ->
      (* multi-credential keepers need per-repo resolution; the caller
         supplies repo context separately via resolve_for_repo *)
      Error (No_default_credential { candidates = List.map (fun c -> c.id) many })

val resolve_for_repo
  : config:Coord.config
 -> keeper_name:string
 -> repo_id:string
 -> (binding, error) result
```

Backward-compat (Acceptance criterion #6): keepers with `profile.github_identity` set keep working through `legacy_bind`. The legacy path emits a deprecation metric so we can ramp-down.

### 4.3 Identity binding is `f(keeper, repo)`, not `f(keeper)` (P6)

This RFC makes explicit what #12304 implied: a keeper may map to N repositories, and each repository may carry a different credential. The keeper's `op=gh pr create` must therefore know **which repo** it is operating on to select the right credential.

Today the seam is at `keeper_shell_gh_context.ml:resolve_repo_context_for_gh` — it already determines repo context from active task / worktree. RFC-0019 extends this resolver to ALSO return the credential id, then passes it to `resolve_for_repo` instead of the keeper-only `resolve`.

### 4.4 Materializer hook (P7)

`Credential_store.add` becomes:

```ocaml
let add ~config ~base_path (cred : credential) =
  let* () = path_safe cred.gh_config_dir in        (* B-R2 mitigation *)
  let* materialized_state = Materializer.ensure ~config cred in
  let cred = { cred with state = materialized_state } in
  let* () = save_all ~base_path (cred :: existing) in
  Audit_events.emit `credential_connect cred ;     (* unified audit, P5/P8 *)
  Ok cred
```

`Materializer.ensure` decides the new credential's lifecycle status:

| Operator input | Materializer action | Resulting state |
|---|---|---|
| `gh_config_dir = Some path AND path is non-empty bundle` | verify `gh auth status`, hash token, populate `token_sha256_prefix` | `Materialized` |
| `gh_config_dir = Some path AND path is empty/missing` | mkdir, return `Unmaterialized` with operator instructions | `Unmaterialized` |
| `gh_config_dir = None AND request body has `oauth_method: "device_flow"` | spawn `gh auth login --hostname github.com --git-protocol https --device` in `<base>/.masc/github-identities/<id>/gh/`, capture the device code, return it in HTTP response for operator to type | `Unmaterialized` until operator completes; transitions to `Materialized` on next `verify` |
| `gh_config_dir = None AND request body has `oauth_method: "with_token"` AND request body has `token: ...` (stdin / multipart only)` | run `gh auth login --hostname github.com --with-token` against the bundle path; *do not log the token anywhere* (only its sha256_prefix) | `Materialized` |

Existing dashboard form (`credential-settings.ts:250-309`) is extended with a **method selector** ("Web OAuth" / "Token paste") and a **device-flow code display panel**. Per user choice (2026-04-30 plan-mode session): both methods supported, web OAuth default.

### 4.5 F-1 gate (permissive + audit, ramp to strict)

When `Materializer.ensure` populates `token_sha256_prefix`, it also reads the operator's ambient `gh auth token` (best-effort), hashes that, and compares prefixes. On match:

- Emit `keeper_credential_provider_gate_warned_total{credential_id, scope=root|keeper}` Prometheus counter.
- Tag `credential.state = Stale { reason = "token_shared_with_operator" }` if the operator explicitly chose strict mode.
- Default mode: permissive — record warning, allow operation.
- Strict mode: refuse to materialize.

Strict mode is **disabled by default in PR-A and PR-B**. It activates after a 2-week soak window (P3 — RFC-0008 phasing) when the gate-warned ratio reaches 0%.

## 5. Phasing

This RFC lays out 4 PRs. Each is independently shippable, each ramps acceptance-criterion compliance, none requires the next to be *correct*.

### PR-A — Bridge resolver (1-2 days; SAFE; non-functional bridge)

**Goal**: make A read B's registry; backward compatible.

- `lib/keeper/host_config_provider.ml`: add `Keeper_repo_mapping.credentials_for_keeper` lookup at top of `resolve`; fall back to legacy `keeper_types_profile.github_identity` when mapping is empty.
- `lib/repo_manager/keeper_repo_mapping.ml`: expose `credentials_for_keeper` helper.
- `lib/repo_manager/repo_manager_types.{ml,mli}`: add `state : credential_state` and `token_sha256_prefix : string option` fields with conservative defaults (`Unmaterialized`, `None`) so existing TOML files load. Preserve `to_yojson`/`of_yojson` symmetry (per memory `feedback_json-serializer-parser-key-symmetry`).
- `test/test_credential_provider_bridge.ml` (new): keeper with mapping → reads from `Credential_store`. Keeper without mapping → reads legacy. Both succeed.

**Acceptance**: legacy keepers unchanged. New keepers with mapping route through `Credential_store`. F-1 still untouched.

### PR-B — Materializer + dashboard provisioning (3-5 days; observable; closes user's symptom)

**Goal**: end-to-end "operator clicks → keeper makes PR".

- `lib/repo_manager/credential_materializer.ml` (new): the §4.4 logic. `ensure`, `verify`, `mark_stale`.
- `lib/repo_manager/credential_store.ml`: invoke materializer in `add`/`update`. Emit unified audit events.
- `lib/server/server_routes_http_routes_credentials.ml`: extend POST handler with `oauth_method` field; route `device_flow` and `with_token`. **Token never logged**.
- `dashboard/src/components/credential-settings.ts`: add method selector, device-code display, token-paste field (password input, value never persisted to client state).
- `dashboard/src/components/credential-settings.ts`: visualize `state` (Materialized / Unmaterialized / Stale) per record.
- `lib/server/server_routes_http_routes_activity.ml`: emit `credential_connect`, `credential_rotate`, `credential_disconnect` events.
- `lib/operator_approval.ml`: route `credential_connect` through high-risk gate (operator confirmation required).
- `test/test_credential_materializer.ml` (new): all 4 rows of the §4.4 table; token never appears in stdout/log/metric/audit.
- `test/test_keeper_credential_e2e.ml` (new): operator HTTP POST → server-side materialize via `device_flow` mock → keeper successfully resolves binding (P8 gate).

**Acceptance**: §5 of the synthesis turns from "all FAIL" to "all PASS". User's `anyang-keepers PR 0건` symptom closes (subject to L2/L3 from initial diagnosis being addressed separately).

### PR-C — F-1 gate active + lifecycle parity (3-5 days; security)

**Goal**: P1 + P2 enforced.

- `lib/repo_manager/credential_materializer.ml`: enable F-1 gate (permissive + metric).
- `lib/keeper/credential_provider.ml`: `Credential_store.remove` now invokes `Credential_provider.tear_down` (orphan-safe).
- `lib/keeper/host_config_provider.ml`: implement `finalize` for hosts.yml relabel (RFC-0008 PR-2 kicker; previously deferred).
- `lib/repo_manager/credential_store.ml`: 2-phase commit on add/remove (TOML write ↔ filesystem mutation atomicity).
- `scripts/audit-keeper-credential-soak.sh` (new): daily report on gate-warned ratio.
- `test/test_credential_lifecycle.ml` (new): finalize/tear_down idempotence; rotation does not orphan filesystem; F-1 gate fires on shared token.

**Acceptance**: F-1, F-2, F-4 all "Solved by combined main" (synthesis §7 row 1-3 turn green).

### PR-D — Process safeguards + manual unification (2-3 days; lessons)

**Goal**: prevent the next #12304-style split-brain.

- `~/me/.claude/hooks/pr-creation.sh` (new): on `gh pr create`, scan `docs/rfc/` and `docs/design/` for keyword overlap with the changed files (e.g. files matching `lib/keeper/`, `lib/repo_manager/`, `*credential*` → check for prior RFCs). Emit `[WARN] this PR touches subsystems with prior RFCs: …` and require either an RFC link in body or `--skip-rfc-check` flag with explicit reason.
- `~/me/instructions/workflow-pr.md`: add clause "PR touching credential / keeper / repo_manager / operator subsystems MUST cite an RFC in body or include `RFC-WAIVED: <reason>` line".
- `~/me/CLAUDE.md` `<agent_delegation>`: codify the agent gate from §3.2 P9.
- `docs/KEEPER-USER-MANUAL.md`: rewrite the "github_identity" section to teach the unified `Credential_store` model. Old `github_identity` field documented as legacy with deprecation date.
- `docs/rfc/RFC-0008-credential-provider.md`: add "Status: Superseded by RFC-0019" header; keep file for history.

**Acceptance**: future agent-delegated PRs in this subsystem either cite RFC-0019 or are rejected by hook before reaching review.

## 6. Migration plan

**No data migration needed for legacy keepers** (`profile.github_identity` set, no `keeper_repo_mapping`). PR-A's `legacy_bind` keeps them on the old path indefinitely. Deprecation date is left to a follow-up RFC; this RFC does not mandate a sunset.

**For keepers with both** (`profile.github_identity` AND `keeper_repo_mapping`): PR-A's resolver prefers the mapping. PR-D's manual update teaches operators to delete the obsolete `github_identity` field. A linter rule (`scripts/audit-keeper-credential-drift.sh` extended) flags the conflict.

**For new keepers** (no `profile.github_identity`): use `Credential_store` + `keeper_repo_mapping` exclusively from PR-A onward.

## 7. Process safeguards (the part that prevents this from recurring)

The technical fix in §4-§5 closes the user-facing problem. The process fix in PR-D closes the organizational problem.

### 7.1 Pre-PR RFC-discovery hook (PR-D)

A bash hook fires on `gh pr create` (or git push for PR-bound branches). It:

1. Diffs the working tree against `origin/main`.
2. Maps changed files to subsystem keywords (`lib/keeper/` → `keeper`; `lib/repo_manager/` → `repo_manager`, `credential`; …).
3. Greps `docs/rfc/*.md` for those keywords in titles and abstracts.
4. If any RFC matches AND the PR body does not cite that RFC's number, prints:
   ```
   ⚠️  This PR touches subsystems with active RFCs:
       - RFC-0008 (Credential Provider) ← matches lib/keeper/credential_provider.{mli,ml}
       - RFC-0019 (Credential Unification) ← matches lib/repo_manager/credential_store.ml
   PR body must cite at least one RFC number, or include "RFC-WAIVED: <reason>" line.
   Override with --skip-rfc-check (logged to audit-events).
   ```
5. Exits non-zero unless body cites or override flag is present.

### 7.2 Agent delegation gate (PR-D, CLAUDE.md)

```xml
<agent_delegation>
  Autonomous coding agents (Claude Sonnet, Codex, autocoder) MUST NOT
  produce PRs in the following subsystems without a prior human-reviewed RFC:
    - lib/keeper/credential_*
    - lib/repo_manager/
    - lib/keeper/keeper_gh_*
    - lib/operator/operator_control.ml (credential action handlers)
    - dashboard/src/components/credential-settings.ts
    - dashboard/src/components/keeper-repo-mapping.ts
  Enforcement (one of):
    (a) Pre-task review: human posts "RFC review LGTM, agent-delegate authorized for <RFC#>" before the agent starts.
    (b) Hook: if an agent commit author contains "Co-Authored-By: Claude|Codex|Autocoder" AND files touch the above paths AND PR body lacks RFC citation, hook blocks merge.
</agent_delegation>
```

### 7.3 e2e CI gate (PR-B / PR-D)

`test_keeper_credential_e2e.ml` (added in PR-B) becomes a *required check* on PRs that touch any file under §7.2's path list. The test simulates the operator → server → keeper → PR flow end-to-end, against a mock GitHub. A green test means the user's symptom (anyang-keepers PR 0건) is closed by the changes.

## 8. Risks and mitigations

| # | Risk | Mitigation |
|---|---|---|
| R1 | Legacy keepers break when `Credential_store` lookup fails | PR-A `legacy_bind` fallback + integration test |
| R2 | Token-paste path leaks token via error message / log | PR-B test grep stdin/log/metric/audit for `gh[op]_[A-Za-z0-9_]{36+}` regex; assert 0 hits |
| R3 | Materializer races with operator's manual `gh auth login` outside dashboard | PR-C 2-phase commit + filesystem lock during materialize |
| R4 | F-1 gate false positive (multi-operator host shares same PAT) | PR-C audit metric distinguishes single- vs multi-operator detection by hash count uniqueness |
| R5 | RFC-discovery hook creates friction for legitimate small PRs | Default warn-only for first 2 weeks; ramp to block; allow `--skip-rfc-check` with logged reason |
| R6 | This RFC itself is the next #12304 (designed without coordinating with another in-flight RFC) | RFC-0019 explicitly references RFC-0008; PR-A diff is auto-checked against `docs/rfc/` for any RFC published after 2026-04-30 by this RFC's CI step |
| R7 | The `state` field added to `credential` breaks existing TOML parsing | PR-A `of_toml` accepts missing field as `Unmaterialized`; preserve symmetry with `to_toml` (per `feedback_json-serializer-parser-key-symmetry`) |
| R8 | F-2 hosts.yml relabel requires Option B (in-container login), still gated | PR-C ships filesystem-side relabel only; full Option B deferred per RFC-0008 P3 ordering |

## 9. Open questions / decisions needed before PR-A starts

- **Q1** *(load-bearing)*: When `Credential_store.add` is called with `gh_config_dir = None AND oauth_method = "device_flow"`, who hosts the device-flow subprocess? (a) MASC server fiber, (b) standalone CLI helper, (c) operator's terminal. **Default proposal**: (a) — server fiber spawns short-lived `gh auth login --device`, captures output for HTTP response. Operator types device code in their browser. Trade-off: server now talks to GitHub OAuth. Acceptable since server already proxies many GH calls.
- **Q2**: Should `state = Unmaterialized` block keeper from `op=gh` or just warn? **Default proposal**: block — return `Error (Unmaterialized_credential ...)` with actionable message. Alternative: serve an idempotent retry that triggers materialization on demand.
- **Q3**: Manual deprecation cadence for `profile.github_identity` legacy field. **Default proposal**: deprecation warning in PR-D; remove in 6 months (RFC-0023 territory).
- **Q4**: How does Q5 from research synthesis (§11) — multi-credential keepers — interact with `keeper_alias` git author? **Default proposal**: `git_author_name` / `git_author_email` come from the *resolved credential's* `username` field, not the keeper alias, when `git_identity_mode = "github_identity"`. Existing `keeper_alias` mode is unchanged.
- **Q5**: F-1 strictness ramp gate value. **Default proposal**: enable strict mode when `keeper_credential_provider_gate_warned_total / keeper_credential_provider_resolve_total < 0.001` over 14 days, AND no operator-reported false positives, AND fine-grained PAT issuance script exists (RFC-0008 PR-2 prereq).

## 10. Verification

**PR-A**:
```bash
dune build
dune runtest
dune exec test/test_credential_provider_bridge.exe
# legacy keepers
keeper_name="anyang-keepers" \
  dune exec scripts/integration/legacy_keeper_smoke.exe
# new keepers
KEEPER_REPO_MAPPING=on \
  dune exec scripts/integration/mapped_keeper_smoke.exe
```

**PR-B (smoke; operator runs interactively)**:
```bash
# Start server with materializer enabled
MASC_CRED_MATERIALIZER=on dune exec masc-mcp -- serve

# In dashboard, operator clicks: Credentials → Add → Web OAuth →
# server returns device code → operator visits github.com/login/device →
# server completes materialization → toast: "Materialized: credential <id>"

# Now keeper smoke
keeper_name="anyang-keepers" \
  dune exec scripts/integration/keeper_pr_create_smoke.exe
# Expected: PR created, attributed to <username> from credential record.
```

**PR-C**:
```bash
# F-1 gate active
GH_TOKEN_OPERATOR=$(gh auth token) \
  dune exec test/test_f1_gate.exe
# Expected: gate_warned_total counter increments; permissive allows; strict refuses.

# Soak
./scripts/audit-keeper-credential-soak.sh --since=2w
```

**PR-D**:
```bash
# Hook test
git checkout -b test/credential-touch
echo "// test" >> lib/keeper/credential_provider.ml
git commit -am "test"
gh pr create --title "test" --body "no RFC cited"
# Expected: hook blocks with "RFC-0008 / RFC-0019 references missing".
gh pr create --title "test" --body "Refs RFC-0019"
# Expected: hook allows.
```

**End-to-end (the user's original symptom)**:
After PR-B is merged + operator completes web OAuth for `anyang-keepers` credential → wait for keeper turn → `gh search prs --owner yousleepwhen --author anyang-keepers --state all` returns ≥1 PR within one keeper-turn.

## 11. Decisions deferred to future RFCs

- **RFC-0020** (proposed): `In_container_login_provider` (Option B per RFC-0008). Requires fine-grained PAT issuance policy + 2-week soak from RFC-0019 PR-C. Out of scope here.
- **RFC-0021** (proposed): per-keeper SSH key management (current `ssh_key_path` field is RBAC-only). Out of scope.
- **RFC-0022** (proposed): GitLab and Local credential types parity with GitHub. RFC-0019 design accommodates the variant but does not test the non-Github paths.
- **RFC-0023** (proposed): sunset `profile.github_identity` legacy field after 6-month deprecation.

## 12. Citations

This RFC's research foundation: `~/me/knowledge/research/2026-04-30-keeper-credential-architecture-state.md` §1-§12.

Direct code citations are listed there in §12 of the synthesis. Every claim in this RFC about the current state of the codebase is grounded in a file:line citation in the synthesis document.
