# RFC-0007: `keeper_shell op=gh` Harness Audit (Samchon 4-layer)

- **Status**: Draft
- **Author**: vincent (with Claude)
- **Created**: 2026-04-24
- **Related**: RFC-0005 (typed capability substrate), RFC-0006 (surface + symmetric sandbox), #8773, #6814
- **Drives**: tighter keeper GitHub surface so LLM errors become repairable (not silent), plus clarifies identity boundary vs. label

## 1. Problem

Two observations from a 2026-04-24 audit of the keeper × docker × GitHub path (evidence record: `memory/procedural-memory/2026-04-24-keeper-docker-github-provider-evidence-record.md` on the `me` repo) reframe what is currently shipped.

| # | Symptom | Mechanism |
|---|---------|-----------|
| A | The "keeper-scoped" identity `anyang-keepers` holds the same token as the operator host. SHA-256 prefixes match (`406d098bd41b`). | `scripts/rotate-keeper-gh-token.sh` targets legacy `~/.masc/gh-auth`, which no longer exists; the running code reads `~/.masc/github-identities/<identity>/gh`; operators manually seed the bundle by copying the operator PAT. |
| B | LLM calls of `keeper_shell op=gh` have no compile-time shape; a malformed `cmd` string reaches `validate_gh_command` which returns a single-line `Error string` that does not point to a specific flag or token. | `lib/gh_command_validation.ml:215-251` accepts a raw `string` and splits by whitespace (`extract_gh_command_pair`, line 184-213). Validate layer is strong on allowlist; Type/Parse/Feedback layers are thin. |

Framed in the harness vocabulary from Samchon's 2025 function-calling study (dev.to/samchon/qwen-meetup-function-calling-harness, 6.75% → 100% via a 4-layer harness):

| Layer | masc-mcp today | Gap |
|-------|----------------|-----|
| Type | `cmd: string` | No per-subcommand record; LLM emits free-form strings. |
| Parse | whitespace split → `(command, subcommand)` | No shell-quote / JSON-body / heredoc support. No markdown/backtick strip. |
| Validate | `forbidden_shell_chars` + top-level allowlist + `(command, subcommand)` blocklist + `allowed_orgs`; R0/R1/R2 taxonomy. | No flag-value type coercion (`--limit` int, `--state` enum); no flag-combination rules (`--jq` only on `gh api`). |
| Feedback | Single `Error <printf string>`; some include Good/Bad examples. | No structured `{code, path, expected, received, hint}` object; no retry contract in keeper prompt. |

Both observations share one root: **the harness collapses several concerns (identity, command shape, retry) into opaque strings.** Below, the RFC separates them.

## 2. Goals / Non-Goals

**Goals**
- G1. Typed `gh_request.t` variant that every caller emits; a string façade is kept for one migration window.
- G2. Lenient JSON-aware parser that accepts markdown-fenced, trailing-comma, and double-stringified bodies, and unwinds them to typed fields.
- G3. Flag-value coercion (integer limits, enum states) and flag-combination rules as a compile-time check on the typed variant.
- G4. Structured `gh_error.t` returned to the caller so the keeper prompt can implement a bounded retry loop (capped like Samchon's 10 iterations).
- G5. Document `CredentialProvider.bootstrap_finalize` as the hook responsible for `hosts.yml:user` rewrite after `gh auth login --with-token` (Option B path).

**Non-Goals**
- Introduce a `CredentialProvider` trait in OCaml — scoped to a follow-up RFC-0008 that carves Option A/B into one module. This RFC only links the requirement.
- Replace `gh_command_validation.ml`'s R0/R1/R2 taxonomy — it is kept verbatim; Validate layer is strengthened additively.
- Touch `op=git_clone`; a parallel audit belongs in its own RFC.
- Extend coverage to kepeer actions beyond `keeper_shell op=gh`.

## 3. Design

### 3.1 Type layer — `gh_request.t`

```ocaml
(* lib/gh_request.mli *)
type pr_state = Open | Closed | Merged | All
type gh_request =
  | Pr_list  of { repo : string option; limit : int option; state : pr_state option; json_fields : string list }
  | Pr_view  of { repo : string option; pr_number : int;  json_fields : string list }
  | Issue_list of { repo : string option; state : pr_state option; json_fields : string list }
  | Issue_view of { repo : string option; issue_number : int; json_fields : string list }
  | Api_get  of { path : string; jq : string option }
  | Api_graphql_query of { query_name : string; variables : (string * string) list }
  (* extend as allowlist grows *)
```

- Each constructor corresponds to a `(command, subcommand)` pair already in `gh_allowed_commands` / `gh_blocked_operations`.
- Free-form R1 mutations keep arriving through a **`Mutation_raw` variant** until we typed-gate them in RFC-0007-follow-up; this preserves hot-path availability without weakening Validate.

### 3.2 Parse layer — `gh_cmd_parse.ml`

- Accept three input shapes: typed JSON (preferred), quoted shell string (legacy), markdown-fenced code block (lenient).
- Strip triple-backtick fences (`gh` language tag or no tag) before parsing.
- Handle double-quoted segments and `--flag='{"x":1}'` bodies so JSON body values survive.
- Unwind double-stringified union values (`"{\"type\":\"...\"}"`) once.
- Output: `(gh_request, parse_warnings list)`; never throw.

### 3.3 Validate layer — additive checks on top of R0/R1/R2

- Int parsing for `limit`, `pr_number`, `issue_number` with range (1…1000 for limit, 1…2^31-1 for numbers).
- Enum membership for `state`.
- `json_fields` intersected against a per-resource allowlist (curated at boot from a small TOML in `config/tool_policy.toml`; RFC's non-goal to hit GitHub for schema discovery).
- Flag combination rules (e.g., `Api_get.jq` requires `path` starting with `/`).
- Reuse of existing `allowed_orgs`, `gh_blocked_operations`, `gh_graphql_r2_mutations` verbatim.

### 3.4 Feedback layer — `gh_error.t`

```ocaml
type gh_error = {
  code     : string;  (* FORBIDDEN_CHARS | BLOCKED_OP | TYPE_MISMATCH | UNKNOWN_FLAG | OUT_OF_ORG *)
  path     : string;  (* "$input.flags.limit" *)
  expected : string;  (* "integer in [1, 1000]" *)
  received : string;  (* "one thousand" *)
  hint     : string;  (* ready-to-paste replacement *)
}
```

Serialized as JSON to the keeper. Human-readable string (`code: path – expected, got received (hint)`) is computed once at the edge for backwards compatibility.

### 3.5 Retry contract (keeper prompt section)

Add to `config/prompts/keeper.capabilities.md`:

- On `gh_error.code ∈ {TYPE_MISMATCH, UNKNOWN_FLAG, PARSE_WARNING}`: emit a corrected `gh_request` up to 3 times (hard cap).
- On `gh_error.code ∈ {BLOCKED_OP, FORBIDDEN_CHARS, OUT_OF_ORG}`: **do not retry.** These are policy.
- `R2_Irreversible` commands are *never* auto-retried regardless of error code.

### 3.6 Identity boundary (cross-link to CredentialProvider RFC-0008)

- Findings F-1 and F-2 (evidence record) show identity separation is cosmetic today. Fix belongs in the provider, not the harness.
- This RFC only specifies the hook name (`bootstrap_finalize`) and obligation ("after `gh auth login --with-token`, rewrite `hosts.yml:user`") so future RFC-0008 can land against a stable contract.

## 4. Migration plan

| Step | PR size | Observability |
|------|---------|---------------|
| 1. Add `gh_request.ml` + façade `validate_gh_command_of_string` | small | no behavior change |
| 2. Typed-build `Api_get`/`Api_graphql_query` (highest-leverage for LLM retry) | small | metric: retry count per `op=gh` invocation |
| 3. Migrate `Pr_list`/`Pr_view`/`Issue_list`/`Issue_view` | medium | same |
| 4. Keeper prompt updates (retry contract) | small | metric: `unexpected tool names` should stay at 0 (RFC-0006 goal) |
| 5. Remove string façade after two keeper generations without legacy callers | small | deprecation warning first |

Each step is a separate Draft PR that rebases onto main, gated by CI + Keeper Sandbox Integration Test.

## 5. Risks

- **Typed JSON increases prompt tokens** marginally. Mitigation: keeper prompt caches the tool schema block via Anthropic prompt caching.
- **Legacy callers** in scripts (if any) that build raw `gh pr list --limit X` strings. Addressed by string façade retaining behavior until step 5.
- **Parse leniency is security risk surface.** Mitigation: lenient → typed pipeline; strict schema check runs *after* recovery; never route raw string to docker exec.

## 6. Open questions

- Q1. Does a `JSON_fields` curated allowlist drift with GitHub API changes? How often do we refresh it?
- Q2. Do we generate `gh_request` JSON schema and inject it into the keeper system prompt, or only into tool description? Prompt-cache interaction differs.
- Q3. Should `R1_Reversible` commands be typed in this RFC's scope, or deferred? Current sketch keeps `Mutation_raw` to cap blast radius.

## Appendix — audit trail

- PoC shim: `/Users/dancer/me/.tmp/keeper-docker-gh/provider-shim.sh` (Option A vs Option B traversing identical `main(provider, …)` signature).
- Evidence record: `memory/procedural-memory/2026-04-24-keeper-docker-github-provider-evidence-record.md` (on the `me` repo), decision ID `keeper-docker-gh-provider-audit-2026-04-24`.
- masc-mcp commit used for static audit: `0e408ffc1d5b34badb0cc1b9f3704a9e725fb8c6`.
