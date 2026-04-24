# RFC-0007: Pragmatic `keeper_shell op=gh` Hardening

- **Status**: Draft (rev.2)
- **Author**: vincent (with Claude)
- **Created**: 2026-04-24
- **Revised**: 2026-04-24 — replaced Samchon 4-layer big-bang with a claude-code-inspired 3-PR phasing (rev.1 sketch preserved in §8 Appendix)
- **Related**: RFC-0005 (typed capability substrate), RFC-0006 (surface + symmetric sandbox), RFC-0008 (CredentialProvider — same review cycle), #8773, #6814
- **Drives**: reduce LLM-facing tool error rate without rewriting the gh surface; keep every change landable in a single PR

## 1. Problem

Two concrete failures observed on 2026-04-24 (evidence record `memory/procedural-memory/2026-04-24-keeper-docker-github-provider-evidence-record.md` on the `me` repo, decision id `keeper-docker-gh-provider-audit-2026-04-24`):

1. **Tool error shape is a single string.** `lib/gh_command_validation.ml:215-251` returns `Error "<message>"`. An LLM can read the message but cannot programmatically distinguish *transient* input errors (typo, wrong flag type) from *policy* errors (R2 irreversible, out-of-org repo). No retry contract exists.
2. **Non-interactive defaults are not enforced in every caller.** `lib/keeper/keeper_shell_docker.ml` sets `GIT_ASKPASS=''` and `GIT_TERMINAL_PROMPT=0` inline; the same constants are scattered across other callers. A new callsite that forgets one of these hangs the container on a credential prompt — silent timeout.

Both are fixable without the Samchon 4-layer rewrite proposed in rev.1. Splitting the rewrite into 3 PRs keeps every step reviewable and reversible.

## 2. Design principles (directly borrowed from `~/me/workspace/yousleepwhen/claude-code`)

| # | Principle | claude-code source | masc-mcp analog |
|---|-----------|--------------------|-----------------|
| P1 | **Permission → Sandbox → Exec, strictly serial.** Any gate must be in front of subprocess spawn. | `src/tools/BashTool/BashTool.tsx:540, 881` — `checkPermissions() → runShellCommand(shouldUseSandbox(), subprocessEnv())` | `validate_gh_command → effective_sandbox_profile → run_docker_shell_command_with_status`. Preserve. |
| P2 | **Scrub vs pass-through is decided by token scoping.** Long-lived host secrets are scrubbed; job-scoped tokens pass through. | `src/utils/subprocessEnv.ts:15-53` — `GHA_SUBPROCESS_SCRUB` list; `GH_TOKEN` explicitly NOT scrubbed | Curate `KEEPER_ENV_SCRUB` and `KEEPER_ENV_PASS` as a single file. |
| P3 | **Non-interactive defaults are a constant, not an opinion.** | `src/utils/worktree.ts:199-202` — `GIT_NO_PROMPT_ENV = { GIT_TERMINAL_PROMPT:'0', GIT_ASKPASS:'' }` | Introduce `lib/env_git_noninteractive.ml` with the same record. All docker/exec callsites read from it. |
| P4 | **Errors have shape.** Structured result ≠ scripting nightmare; `{stdout, stderr, exit_code, interpretation?}` is enough to drive LLM retry. | `src/tools/BashTool/BashTool.tsx:280` — `outputSchema` Zod with `returnCodeInterpretation` | `type gh_result = { stdout; stderr; exit_code; class_; interpretation : string option; reversibility }`. Interpretation is a lookup on `(exit_code × class)`, not a parser. |
| P5 | **Do not reinvent parsers or sandbox runtimes.** claude-code wraps tree-sitter and `@anthropic-ai/sandbox-runtime`; it does **not** write its own. | `src/utils/bash/bashParser.ts` (tree-sitter wrapper), `src/utils/sandbox/sandbox-adapter.ts` (external runtime wrapper) | Keep `extract_gh_command_pair` and the docker CLI exactly as is; no lenient parser, no custom daemon. |

These principles are the whole RFC. Everything below is mechanical execution.

## 3. Three-PR phasing

### PR-1 — `env_git_noninteractive` + scrub list (≈80 lines + tests)

- **What**: new `lib/env_git_noninteractive.mli` exposing a single value `val env : (string * string) list`. Callers in `keeper_shell_docker.ml`, `keeper_exec_shell.ml` (op=gh / op=git_clone branches) replace their local inline `("GIT_ASKPASS","")` pairs with `@ Env_git_noninteractive.env`.
- **Also**: `lib/env_keeper_scrub.ml` with two lists `scrub : string list` (Anthropic keys, AWS creds, OIDC tokens — copy from claude-code) and `pass : string list` (`GH_TOKEN`, `GITHUB_TOKEN`, `SSH_AUTH_SOCK`, `GIT_*`). docker run argv construction uses both.
- **Why safe**: additive; any missed callsite is caught by `test_env_git_noninteractive.ml` that greps for forgotten `GIT_ASKPASS` literals under `lib/`.
- **Observability**: metric `keeper_shell_docker.git_prompt_env_missing_total` (should be 0 after PR).

### PR-2 — structured `gh_result.t` (≈120 lines)

- **What**: new type in `lib/gh_command_validation.ml` (or a sibling for clarity):
  ```ocaml
  type gh_exit_class =
    | Ok_0
    | Policy_blocked       (* 1xxN internal — matches R1/R2 blocks *)
    | Type_mismatch        (* argparse failure shape *)
    | Auth_failed          (* gh auth error surface *)
    | Network              (* curl/tls *)
    | Unknown
  type gh_result = {
    stdout         : string;
    stderr         : string;
    exit_code      : int;
    class_         : gh_exit_class;
    reversibility  : gh_reversibility;  (* already exists *)
    interpretation : string option;     (* ready-to-show hint *)
  }
  ```
  Exit-class classifier is a lookup on `(exit_code, stderr-pattern)` stored in `config/tool_policy.toml` — **no regex over stdout**, just a small table.
- **Why safe**: wraps existing call paths; a backward-compat alias `Error string` stays one release cycle, derived from the new record.
- **Observability**: metric `keeper_shell_gh_result_class_total{class=Policy_blocked|Type_mismatch|…}` gives the rollup we don't currently have.
- **Unlocks**: the keeper prompt can say "retry only when class=Type_mismatch" without extra context.

### PR-3 — typed `Api_get` / `Api_graphql_query` only (≈200 lines)

- **What**: introduce `gh_request.t` with **two** constructors (not the full sum type from rev.1):
  ```ocaml
  type gh_request =
    | Api_get           of { path : string; jq : string option }
    | Api_graphql_query of { query_name : string; variables : (string * string) list }
    | Raw_string        of string    (* everything else keeps flowing through as before *)
  ```
  Parsing a raw string into the typed variants happens in `gh_request_parse.ml` with **no lenient recovery** — if the input is not an exact match for the typed shape, it falls through to `Raw_string` and the current string validator runs.
- **Why `gh api` first**: highest-leverage call for LLM retry (jq path, variables), the most likely to benefit from type-directed retry later.
- **Why safe**: `Raw_string` is literally a compile-time constant that means "behave like 2026-04-24". Zero behavior change for R1/R2 mutations.
- **Observability**: metrics `keeper_shell_gh_request_typed_total` / `keeper_shell_gh_request_raw_total` tell us whether callers are migrating.

All three PRs rebase onto `main`, gate on the Keeper Sandbox Integration Test + existing CI matrix, and are independently revertable.

## 4. Hard non-goals (this RFC will not do these)

1. **Full `gh_request.t` sum type with every subcommand** — deferred indefinitely until PR-3 metrics justify it. Without concrete retry-loop data, typing `pr view` / `pr list` / `issue ...` gives low marginal value over string + validator.
2. **Lenient JSON-aware parser** — explicitly disallowed in this RFC's timeline. A leniency layer that strips markdown fences and unwinds double-stringified bodies is attractive but is new attack surface. Samchon's lenient parser protects *correctness*, not *safety*; masc-mcp needs safety first.
3. **Retry contract embedded in keeper prompt** — deferred to the PR after PR-2 lands. The retry contract has teeth only when `class_` is populated; adding the prompt text earlier is cargo-cult.
4. **Self-written shell parser** (tree-sitter, OCaml Menhir, regex-based) — forbidden. If we ever need quoted-string / heredoc awareness, the path is to call `bash -n` or `tree-sitter-bash` via FFI in a dedicated RFC.
5. **Touching `op=git_clone`** — separate audit. Only PR-1 (env constant) crosses that boundary.

## 5. Risks and open questions

1. **PR-2's exit-class table drift.** If GitHub or the `gh` CLI changes exit-code semantics, the table goes stale. Mitigation: the table lives in `config/tool_policy.toml` (non-code), unknown codes bucket to `Unknown` rather than misclassify.
2. **PR-3 being worthless.** If no keeper actually calls `gh api` today, PR-3 has zero telemetry value and should be deprioritized. Sanity check before merging PR-3: grep `keeper_shell op=gh cmd="api ` in the last 7 days of logs.
3. **Scrub list false positives.** If the operator depends on a scrubbed env var reaching the sandbox (unlikely for keepers, more likely for experimental tooling), they must explicitly add it to `pass`. Documented in `config/tool_policy.toml` commentary.

## 6. Cross-link to RFC-0008 (CredentialProvider)

`keeper_shell_docker.ml`'s env composition in PR-1 becomes consumable by `CredentialProvider.binding.env` once RFC-0008 lands. Merge order:

1. This RFC's PR-1 (env constants) — does **not** depend on RFC-0008.
2. RFC-0008 PR-1 (`Credential_provider` module + `Host_config_provider`) — reads `Env_git_noninteractive.env` from this RFC's PR-1.
3. This RFC's PR-2 and PR-3 can land independently once PR-1 is in.

No circular dependency; both RFCs can be reviewed in parallel and merged in the above order.

## 7. Migration cost

| Item                           | Lines changed (est.) | Test added (est.) | Risk                          |
|--------------------------------|---------------------:|------------------:|-------------------------------|
| PR-1 env constants             |                   80 |                60 | low                           |
| PR-2 structured result         |                  120 |               100 | medium (alias maintained)     |
| PR-3 typed `Api_*`             |                  200 |               150 | medium (new module)           |
| **Total**                      |              **400** |           **310** | —                             |

Compare to rev.1's estimated 1200+ lines in a single cycle; 3-PR split is ~a third of the surface and reversible per step.

## 8. Appendix — original aspirational sketch (rev.1, retained for discussion)

The rev.1 Samchon 4-layer design (typed `gh_request.t` with full subcommand coverage, lenient JSON-aware parser, structured error with `{code, path, expected, received, hint}`, retry contract in keeper prompt) is kept in commit `aa8cab475` on this branch and in the PR discussion thread. It remains the aspirational target *if* PR-2/PR-3 telemetry shows LLM retry failures justify further typing work. Until then, this RFC supersedes it.

## Appendix B — evidence

- PoC artifacts: `~/me/.tmp/keeper-docker-gh/` — Option A (RO mount) and Option B (`gh auth login --with-token`) both passed end-to-end.
- Evidence record: `~/me/memory/procedural-memory/2026-04-24-keeper-docker-github-provider-evidence-record.md`.
- masc-mcp commit audited: `0e408ffc1d5b34badb0cc1b9f3704a9e725fb8c6`.
- claude-code reference points (read-only observation):
  - `src/tools/BashTool/BashTool.tsx:540, 881` — execute pipeline order.
  - `src/tools/BashTool/shouldUseSandbox.ts:18-20, 130-153` — "sandbox permission is the actual security control" (contrast: our docker-is-primary).
  - `src/utils/subprocessEnv.ts:15-53` — scrub/pass lists.
  - `src/utils/worktree.ts:199-202` — `GIT_NO_PROMPT_ENV` record.
