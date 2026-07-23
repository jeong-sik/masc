---
rfc: "0292"
title: "Complete lib/auth de-duplication — remove drifted Masc.Auth* test copies"
status: Draft
created: 2026-06-24
updated: 2026-06-24
author: jeong-sik (vincent)
supersedes: []
superseded_by: null
related: ["0099"]
implementation_prs: []
---

# RFC-0292 — Complete `lib/auth` de-duplication

Status: Draft
Author: jeong-sik (vincent)
Date: 2026-06-24
Scope: the bearer-token auth modules that exist twice — once under `lib/` (parent
`masc` library, exposed as `Masc.Auth*`) and once under `lib/auth/` (sublibrary
`masc_auth`, `wrapped false`, exposed as bare `Auth*`).
Out of scope: the auth *behavior* (token compare, collision handling, gate
semantics). This RFC only removes the duplicate module copies; it changes no
auth logic.

## 1. Problem — two copies of the auth modules, one already drifted

`lib/dune` uses `(include_subdirs unqualified)`, so every `lib/<x>.ml` is a module
of the wrapped `masc` library (`Masc.<X>`). `lib/auth/` carries its own dune
stanza (`masc_auth`, `wrapped false`), so it is a separate sublibrary whose
modules are the bare `Auth*` identifiers used by the production server.

On `origin/main` the following auth modules exist in **both** places:

| basename | `lib/` (→ `Masc.<X>`, masc) | `lib/auth/` (→ bare, masc_auth) | state |
|---|---|---|---|
| `auth.ml` | yes | yes | **drifted** |
| `auth_credential_base.ml` | yes | yes | **drifted** |
| `auth_login.ml` | yes | yes | byte-identical |
| `auth_error_kind.ml` | yes | yes | byte-identical |
| `auth_credential_token.ml` | removed | yes | **already de-duplicated** |

`auth_credential_token.ml`'s `lib/` copy was already deleted on main — that is the
precedent this RFC generalizes.

The drift is not byte-noise; it is per-library namespace adaptation. Example in
`auth.ml`:

```ocaml
(* lib/auth.ml  (Masc.Auth, test-only) *)
Otel_metric_store.inc_counter Otel_metric_store.metric_auth_strict_unknown_tool_denials
(* lib/auth/auth.ml  (production) *)
Auth_metric_store.inc_counter  Auth_metric_store.metric_auth_strict_unknown_tool_denials
```

Because the two copies live in different module environments, every change must be
hand-ported across the namespace boundary. This is the N-of-M anti-pattern
(`CLAUDE.md` §워크어라운드): the compiler cannot force a change applied to one copy
onto the other, so they drift. Recent evidence: PR #22178 (token hash collision)
edited both `auth_credential_token.ml` copies in lockstep before main's deletion of
the `lib/` copy made one edit obsolete; #9786 (ambiguous lookup) similarly.

## 2. Why the copies exist (root cause)

Measured on `origin/main`:

- `lib/` (non-test) references to `Masc.Auth*`: **0**.
- `test/` references to `Masc.Auth*`: **68** (e.g. `test_auth_ambiguous_lookup_9786.ml`
  uses `Masc.Auth.find_credential_by_token`).

So the `lib/` copies exist **only** to give test code a `Masc.Auth*` handle.
Production code already depends on `masc_auth` (bare `Auth`). The duplicate is a
test-access convenience, and the tests now validate a **drifted, test-only copy**
rather than the production `masc_auth` implementation. For an auth module this is a
harness gap: the auth test suite does not exercise the code that runs in production.

## 3. Dependency direction (no cycle)

`lib/auth/dune` (`masc_auth`) depends on `masc.masc_core`, `masc.masc_types`,
`masc.config`, … — leaf sublibraries, **not** the top-level `masc` library.
Therefore a test (or a `masc` consumer) may depend on `masc.auth` without creating a
cycle. The 0 non-test `Masc.Auth*` references confirm no `masc` runtime module needs
the copies.

## 4. Proposal

1. **Single source of truth = `lib/auth/` (`masc_auth`).**
2. Repoint the 68 test references from `Masc.Auth*` to the production modules — add
   `masc.auth` to the relevant `test/dune` targets and use the bare `Auth*`
   identifiers (`Auth.find_credential_by_token`, `Auth_credential_base.*`, …).
   - **First resolve the `.mli` surface delta — step 2 is not a pure rename.**
     `lib/auth.ml` (`Masc.Auth`) ships no `.mli`, so it exposes every binding;
     `lib/auth/auth.ml` (`masc.auth`) restricts its surface through a curated
     338-line `auth.mli`. Any test that reaches a `Masc.Auth*.*` symbol absent from
     `lib/auth/auth.mli` (a private helper) fails to compile after the move. Before
     repointing, compute `{ test Masc.Auth*.* symbols } \ { lib/auth/*.mli vals }`
     and resolve that delta first — by rewriting the test against the public
     surface, not by widening the `.mli` (widening the public auth surface is a
     non-goal, cf. §5). The common helpers (`generate_token`, `sha256_hash`,
     `verify_token`, `load_auth_config`) are already exposed, so most refs are
     safe; the delta isolates the few that are not.
3. Delete the `lib/` copies: `auth.ml`, `auth_credential_base.ml`, `auth_login.ml`,
   `auth_error_kind.ml` (and any further `lib/auth_*.ml` whose twin lives in
   `lib/auth/`).
4. Add a CI guard (§6) so the pattern cannot reappear.

This is incremental: each module can move independently (token already did). Order
by least-coupled first (`auth_error_kind`, `auth_login` — byte-identical, lowest
risk) then `auth_credential_base`, `auth`.

## 5. Trade-offs

- Pro: one definition; the auth suite exercises production code; no namespace-port
  drift; the compiler again owns "one module, one source".
- Con: mechanical migration of 68 test references; each test target gains a
  `masc.auth` dependency.
- Risk: a bare `Auth*` identifier from a `wrapped false` sublibrary occupies the
  global module namespace; before deleting a copy, confirm no unrelated bare module
  of the same name exists (none today for `Auth*`).
- Non-goal: this RFC must not alter any auth logic. If a copy has drifted in a way
  that is behaviorally meaningful (not just metric-store namespace), that delta is
  surfaced and reconciled **toward the production `lib/auth/` copy** before the
  `lib/` copy is deleted — production is the source, the test copy is discarded.

## 6. Enforcement — prevent recurrence

`scripts/ci/check-auth-no-dual-copy.sh`:

```sh
# Fail if any lib/auth/<x>.ml also exists as lib/<x>.ml (basename collision).
dup=$(comm -12 \
  <(ls lib/auth/*.ml | xargs -n1 basename | sort) \
  <(ls lib/auth_*.ml lib/auth.ml 2>/dev/null | xargs -n1 basename | sort))
[ -z "$dup" ] || { echo "dual-copy auth modules: $dup"; exit 1; }
```

Wired into the Meta Guards job alongside the other bug-class gates. This is the
structural backstop the compiler cannot provide.

## 7. Verification

- `rg 'Masc\.Auth' lib/` → ∅ (already true), and `rg 'Masc\.Auth' test/` → ∅ after
  migration.
- For each deleted copy: at deletion time `diff lib/<x>.ml lib/auth/<x>.ml` is either
  empty or only namespace-adaptation lines reconciled toward `lib/auth/`.
- `dune build` + the auth test suite (`test_auth_credential_hash_collision`,
  `test_auth_ambiguous_lookup_9786`, `test_auth_credential_index_cache`) green.
- `scripts/ci/check-auth-no-dual-copy.sh` exits 0.

## 8. Relation to the credential/auth security PRs

Bearer-token credential auth has **no prior governing RFC**: RFC-0008
(credential-provider, *Retired* 2026-06-02) and RFC-0019 (credential-unification,
*Withdrawn* 2026-06-02) both cover GitHub **repository identity** and explicitly
state that "auth credentials remain a separate bearer-token/admin-token storage
concern … not part of this design". This RFC is the first to govern the
bearer-token auth module layout.

- #22178 (token hash collision): its net branch tree no longer carries the `lib/`
  token copy, so it does not re-introduce the dual-copy; it is unblocked by this RFC,
  not gated by it.
- `lib/auth.ml` is now a thin facade over the `lib/auth/` leaf, and the retired
  root `lib/auth_credential_base.ml` implementation has been removed. The leaf
  is the sole authentication implementation.
